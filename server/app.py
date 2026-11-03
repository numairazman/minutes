"""Minutes "maximum accuracy" server.

Re-processes a meeting recording with WhisperX (Whisper large-v3, wav2vec2 word alignment and
pyannote speaker diarization) and returns words and speaker turns in the shapes the app's
MinutesCore decodes, so its aligner, summarizer and exporter run on the result unchanged.

    POST   /v1/jobs?language=en&speakers=4&vocabulary=Acme   body: the audio file  → {id}
    GET    /v1/jobs/{id}    → {id, state, stage, progress, error?, result?}
    DELETE /v1/jobs/{id}
    GET    /v1/status       → what the app's "Test Connection" shows

A meeting takes minutes even on a GPU, far longer than an HTTP request should sit silent, so
the app uploads, then polls. Every /v1 route needs `Authorization: Bearer $MINUTES_TOKEN`.
Meant for a home network only; see README.md.

This process never touches the GPU. The models run in engine.py's child process, which is
started when a meeting arrives and ended KEEP_LOADED_MINUTES after the last one, so on a PC
that's also for games the VRAM is free whenever nothing is being processed.
"""
import logging
import multiprocessing
import os
import queue
import secrets
import tempfile
import threading
import time
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

import engine

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("minutes")

TOKEN = os.environ.get("MINUTES_TOKEN", "").strip()
if len(TOKEN) < 16:
    raise SystemExit("Set MINUTES_TOKEN in .env to a random string of at least 16 characters.")
KEEP_LOADED_SECONDS = float(os.environ.get("KEEP_LOADED_MINUTES", "").strip() or 2) * 60
MAX_UPLOAD_BYTES = int(os.environ.get("MAX_UPLOAD_MB", "").strip() or 2048) * 1024 * 1024
MAX_QUEUED = 10
KEEP_FINISHED_SECONDS = 3600
UPLOADS = Path(tempfile.gettempdir()) / "minutes-uploads"


class EngineStopped(Exception):
    pass


@dataclass
class Job:
    id: str
    path: Path
    language: Optional[str]
    speakers: Optional[int]
    vocabulary: list
    state: str = "queued"  # queued → running → done | failed | cancelled
    stage: str = "Waiting for the PC"
    progress: float = 0.0
    error: Optional[str] = None
    result: Optional[dict] = None
    cancelled: bool = False
    finished_at: Optional[float] = None
    created_at: float = field(default_factory=time.time)

    def view(self):
        body = {"id": self.id, "state": self.state, "stage": self.stage, "progress": round(self.progress, 3)}
        if self.error:
            body["error"] = self.error
        if self.result is not None:
            body["result"] = self.result
        return body


class Worker:
    """engine.serve in a child process. Exiting it is what gives the GPU its memory back."""

    def __init__(self):
        self.process = None
        self.conn = None
        self.device = None

    @property
    def running(self):
        return self.process is not None and self.process.is_alive()

    def start(self):
        self.kill()  # reap one that exited on its own, e.g. after a GPU error
        context = multiprocessing.get_context("spawn")
        self.conn, child = context.Pipe()
        self.process = context.Process(target=engine.serve, args=(child,), name="engine", daemon=True)
        self.process.start()
        child.close()
        log.info("engine starting")
        # No timeout: the very first start downloads several GB of models.
        kind, detail = self.receive()
        if kind != "ready":
            self.kill()
            raise RuntimeError(detail)
        self.device = detail
        log.info("engine ready on %s", detail)

    def receive(self, timeout=None):
        """The engine's next message, or None if none arrived within `timeout` seconds."""
        if self.conn.poll(timeout):
            try:
                return self.conn.recv()
            except EOFError:
                pass
        elif self.process.is_alive():
            return None
        self.kill()
        raise EngineStopped("The processing engine stopped unexpectedly, most often from running out of GPU memory.")

    def send(self, message):
        self.conn.send(message)

    def stop(self):
        """Asks the engine to exit, after the idle wait or once the startup check is done."""
        if self.running:
            try:
                self.conn.send(None)
            except OSError:
                pass
            self.process.join(15)
        self.kill()

    def kill(self):
        if self.process is None:
            return
        if self.process.is_alive():
            self.process.kill()
        self.process.join()
        self.conn.close()
        self.process, self.conn = None, None
        log.info("engine stopped; GPU memory released")


worker = Worker()
health = {
    "state": "loading",
    "message": "Checking the models. The first start downloads about 4 GB, which takes a few minutes.",
}
jobs = {}
jobs_lock = threading.Lock()
work = queue.Queue()


def start_engine():
    try:
        worker.start()
    except Exception as error:
        health.update(state="error", message=str(error))
        raise
    health.update(state="ready", message=None)


def run(job):
    job.state = "running"
    try:
        if not worker.running:
            job.stage = "Loading models"
            start_engine()
        worker.send({"path": str(job.path), "language": job.language, "speakers": job.speakers, "vocabulary": job.vocabulary})
        while job.state == "running":
            if job.cancelled:
                worker.kill()
                job.state = "cancelled"
                break
            message = worker.receive(timeout=0.5)
            if message is None:
                continue
            kind, detail = message
            if kind == "stage":
                job.stage, job.progress = detail, 0.0
            elif kind == "progress":
                job.progress = max(job.progress, detail)
            elif kind == "done":
                job.result = detail
                job.state, job.stage, job.progress = "done", "Done", 1.0
            elif kind == "failed":
                job.state, job.error = "failed", detail
    except Exception as error:
        log.exception("job %s failed", job.id)
        job.state, job.error = "failed", str(error) or type(error).__name__


def manager():
    # Start the engine once at boot: it downloads the models the first time and proves the
    # token and GPU work, so Test Connection can say so. Then it exits straight away.
    try:
        start_engine()
    except Exception:
        log.exception("startup check failed")
    worker.stop()
    while True:
        try:
            job = work.get(timeout=KEEP_LOADED_SECONDS if worker.running else None)
        except queue.Empty:
            worker.stop()
            continue
        if job.cancelled:
            job.state = "cancelled"
        else:
            run(job)
        job.finished_at = time.time()
        job.path.unlink(missing_ok=True)


def purge_finished():
    cutoff = time.time() - KEEP_FINISHED_SECONDS
    with jobs_lock:
        for job_id in [j.id for j in jobs.values() if j.finished_at and j.finished_at < cutoff]:
            del jobs[job_id]


@asynccontextmanager
async def lifespan(_app):
    UPLOADS.mkdir(parents=True, exist_ok=True)
    threading.Thread(target=manager, name="manager", daemon=True).start()
    yield


app = FastAPI(title="Minutes accuracy server", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
bearer = HTTPBearer(auto_error=False)


def authorize(credentials: Optional[HTTPAuthorizationCredentials] = Depends(bearer)):
    if credentials is None or not secrets.compare_digest(credentials.credentials.encode(), TOKEN.encode()):
        raise HTTPException(401, "Wrong or missing token.", headers={"WWW-Authenticate": "Bearer"})


@app.get("/health")
def alive():
    return {"ok": True}


@app.get("/v1/status", dependencies=[Depends(authorize)])
def status():
    with jobs_lock:
        waiting = sum(1 for j in jobs.values() if j.state in ("queued", "running"))
    return {
        "state": health["state"],
        "message": health["message"],
        "device": worker.device or "unknown until the first start",
        "model": f"Whisper {engine.WHISPER_MODEL}",
        "diarization": engine.DIARIZATION_MODEL,
        # Whether the models are in GPU memory right now; they're unloaded when idle.
        "loaded": worker.running,
        "jobs": waiting,
    }


@app.post("/v1/jobs", status_code=202, dependencies=[Depends(authorize)])
async def create_job(
    request: Request,
    language: Optional[str] = Query(None, max_length=35),
    speakers: Optional[int] = Query(None, ge=1, le=20),
    vocabulary: list[str] = Query(default=[]),
):
    purge_finished()
    with jobs_lock:
        if sum(1 for j in jobs.values() if j.state == "queued") >= MAX_QUEUED:
            raise HTTPException(429, "The PC already has a queue of meetings to process. Try again later.")
    job_id = uuid.uuid4().hex
    path = UPLOADS / job_id
    size = 0
    try:
        with open(path, "wb") as file:
            async for chunk in request.stream():
                size += len(chunk)
                if size > MAX_UPLOAD_BYTES:
                    raise HTTPException(413, f"The recording is larger than {MAX_UPLOAD_BYTES // 1024 // 1024} MB.")
                file.write(chunk)
        if size == 0:
            raise HTTPException(400, "The upload was empty.")
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    # "en-US" → "en": Whisper takes bare language codes.
    code = (language or "").replace("_", "-").split("-")[0].lower() or None
    terms = [t.strip() for t in vocabulary if t.strip()][:200]
    job = Job(id=job_id, path=path, language=code, speakers=speakers, vocabulary=terms)
    with jobs_lock:
        jobs[job_id] = job
    work.put(job)
    log.info("job %s: %.1f MB, language %s, speakers %s, %d terms", job_id, size / 1e6, code, speakers, len(terms))
    return {"id": job_id}


def find(job_id):
    with jobs_lock:
        job = jobs.get(job_id)
    if job is None:
        raise HTTPException(404, "No such job. The server may have restarted; try again.")
    return job


@app.get("/v1/jobs/{job_id}", dependencies=[Depends(authorize)])
def get_job(job_id: str):
    return find(job_id).view()


@app.delete("/v1/jobs/{job_id}", status_code=204, dependencies=[Depends(authorize)])
def delete_job(job_id: str):
    job = find(job_id)
    job.cancelled = True
    if job.finished_at:
        with jobs_lock:
            jobs.pop(job_id, None)
