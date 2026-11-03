"""The GPU half of the server: WhisperX, in a child process that exists only while there's work.

app.py starts it when a meeting arrives and ends it a couple of minutes after the last one, so
the models' ~4 GB of VRAM is taken only while processing; the PC is also used for games. Torch
and WhisperX are imported only in here, inside the child, never by the web server.

Over the pipe to app.py: ("ready", device name) or ("failed", message) once at start; then for
each job, ("stage", name), ("progress", fraction) and finally ("done", result) or ("failed", message).
"""
import gc
import logging
import os
import time
from dataclasses import replace

import shaping

log = logging.getLogger("minutes.engine")

HF_TOKEN = os.environ.get("HF_TOKEN", "").strip() or None
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "").strip() or "large-v3"
DIARIZATION_MODEL = os.environ.get("DIARIZATION_MODEL", "").strip() or "pyannote/speaker-diarization-community-1"
LICENCE_URL = f"https://huggingface.co/{DIARIZATION_MODEL}"


def serve(conn):
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    try:
        engine = Engine()
    except Exception as error:
        log.exception("loading models failed")
        conn.send(("failed", str(error) or type(error).__name__))
        return
    conn.send(("ready", engine.device_name))
    while True:
        try:
            job = conn.recv()
        except EOFError:
            return
        if job is None:
            return
        try:
            conn.send(("done", engine.process(job, lambda *event: conn.send(event))))
        except Exception as error:
            log.exception("job failed")
            message = str(error) or type(error).__name__
            if "CUDA" not in message and "out of memory" not in message:
                conn.send(("failed", message))
                continue
            # A CUDA error can leave the context unusable, and the process would otherwise sit
            # on its GPU memory until the idle timeout. Exit; the next job starts afresh.
            conn.send(("failed", f"The PC's GPU failed, most often from running out of memory "
                                 f"(a game or another app using it?). Try again. ({message})"))
            return


class Engine:
    def __init__(self):
        import torch
        import whisperx
        from whisperx.diarize import DiarizationPipeline

        if not HF_TOKEN:
            raise RuntimeError(
                f"Speaker identification needs a Hugging Face token: accept the conditions at {LICENCE_URL}, "
                "then put HF_TOKEN=… in the server's .env and restart it."
            )
        cuda = (os.environ.get("DEVICE", "").strip() or ("cuda" if torch.cuda.is_available() else "cpu")) == "cuda"
        self.device = "cuda" if cuda else "cpu"
        cores = os.cpu_count() or 4
        # On a GPU the CPU only feeds it, so leave half the cores to whatever else is running.
        threads = int(os.environ.get("CPU_THREADS", "").strip() or (max(1, cores // 2) if cuda else cores))
        torch.set_num_threads(threads)
        # float16 is Whisper's reference precision; int8_float16 roughly halves VRAM on smaller cards.
        compute_type = os.environ.get("COMPUTE_TYPE", "").strip() or ("float16" if cuda else "int8")
        self.batch_size = int(os.environ.get("BATCH_SIZE", "").strip() or (8 if cuda else 4))
        self.device_name = torch.cuda.get_device_name(0) if cuda else f"CPU ({threads} threads)"

        started = time.monotonic()
        self.asr = whisperx.load_model(WHISPER_MODEL, self.device, compute_type=compute_type, threads=threads)
        try:
            self.diarizer = DiarizationPipeline(model_name=DIARIZATION_MODEL, token=HF_TOKEN, device=self.device)
        except Exception as error:
            raise RuntimeError(
                f"Couldn't load {DIARIZATION_MODEL}: {error}. Check that HF_TOKEN is valid and that its account "
                f"accepted the conditions at {LICENCE_URL}."
            ) from error
        # pyannote embeds 32 windows at a time by default; 16 keeps its peak well inside an 8 GB
        # card that's also driving the desktop, for a few seconds' cost.
        if cuda:
            self.diarizer.model.embedding_batch_size = 16
        self.aligners = {}
        log.info("loaded %s (%s, batch %d) and %s on %s in %.0fs",
                 WHISPER_MODEL, compute_type, self.batch_size, DIARIZATION_MODEL, self.device_name,
                 time.monotonic() - started)

    def release(self):
        """Hands PyTorch's cached GPU memory back between stages and after a job."""
        import torch

        gc.collect()
        if self.device == "cuda":
            torch.cuda.empty_cache()

    def aligner(self, language):
        if language not in self.aligners:
            import whisperx

            self.aligners[language] = whisperx.load_align_model(language_code=language, device=self.device)
        return self.aligners[language]

    def process(self, job, emit):
        import torch
        import whisperx

        def progress(percent):
            emit("progress", min(float(percent) / 100, 1.0))

        audio = whisperx.load_audio(job["path"])
        duration = len(audio) / 16_000
        timings = {}

        # Speakers first, while only Whisper's weights are on the GPU: on an 8 GB card, pyannote
        # running on top of the transcriber's and aligner's working memory ran it out.
        emit("stage", "Identifying speakers")
        started = time.monotonic()
        # cuDNN's convolutions fail in pyannote's speaker-embedding ResNet under Docker on WSL 2
        # ("CUDA driver error: device not ready" on an RTX 3070 Ti, driver 610.88, cuDNN 9.10),
        # every time and within seconds. PyTorch's own kernels work, at about the same speed.
        with torch.backends.cudnn.flags(enabled=False):
            diarization = self.diarizer(audio, num_speakers=job["speakers"], progress_callback=progress)
        turns = shaping.speaker_turns(zip(diarization["speaker"], diarization["start"], diarization["end"]))
        timings["diarize"] = time.monotonic() - started
        self.release()

        emit("stage", "Transcribing")
        started = time.monotonic()
        # Names and terms bias the decoder toward the user's spellings, as they do on device.
        self.asr.options = replace(self.asr.options, hotwords=", ".join(job["vocabulary"]) or None)
        transcript = self.asr.transcribe(
            audio, batch_size=self.batch_size, language=job["language"], progress_callback=progress
        )
        language = transcript["language"]
        timings["transcribe"] = time.monotonic() - started

        emit("stage", "Aligning words")
        started = time.monotonic()
        try:
            align_model, metadata = self.aligner(language)
            segments = whisperx.align(
                transcript["segments"], align_model, metadata, audio, self.device,
                return_char_alignments=False, progress_callback=progress,
            )["segments"]
        except Exception:
            # No alignment model for this language: keep the words, spread over their segments.
            log.exception("alignment failed for %s; using segment times", language)
            segments = transcript["segments"]
        words = shaping.timed_words(segments, language)
        timings["align"] = time.monotonic() - started
        self.release()

        total = sum(timings.values())
        log.info(
            "%.0fs of audio in %.0fs (%.1fx real time): %d words, %d turns, %d speakers; %s",
            duration, total, duration / max(total, 1e-6), len(words), len(turns),
            len({t["speaker"] for t in turns}), ", ".join(f"{k} {v:.0f}s" for k, v in timings.items()),
        )
        return {
            "words": words,
            "turns": turns,
            "language": language,
            "duration": round(duration, 3),
            "engine": f"WhisperX {WHISPER_MODEL} + {DIARIZATION_MODEL.split('/')[-1]}",
            "device": self.device_name,
            "timings": {k: round(v, 1) for k, v in timings.items()},
        }
