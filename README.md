# Minutes

A meeting recorder for iPhone. Press Record, and when you stop it gives you:

- a transcript with **who said what** (Speaker 1, Speaker 2, … — tap a name to rename it)
- a **summary**: overview, key points, decisions, action items
- a plain **.txt export** through the share sheet: Save to Files › OneDrive, the OneDrive app, Mail, AirDrop

Everything runs **on the iPhone**. Audio and transcripts never leave the device unless you export them, or choose to re-process a meeting on your own PC (below).

## Requirements

- iPhone 15 Pro or newer, **iOS 26+**, with **Apple Intelligence turned on** (Settings › Apple Intelligence & Siri). Apple Intelligence writes the summary. Transcription and speaker detection work without it.
- On first launch, Minutes downloads the speech model for your language (from Apple) and the speaker models (~20 MB, from Hugging Face). After that it works offline.

## Build and run

```bash
xcodegen generate
open Minutes.xcodeproj
```

Pick your iPhone as the run destination and press Run. `project.yml` is the source of truth: `Minutes.xcodeproj` and `Minutes/Info.plist` are generated and gitignored. Signing uses team `56KRANZJ75`; change `DEVELOPMENT_TEAM` in `project.yml` if that's wrong.

The Simulator runs the app, but it has no on-device speech model, so recordings there fail with "On-device transcription isn't available on this device". Use a real iPhone, or run the pipeline on a Mac (see below).

## How it works

| Stage | What runs | Where |
|---|---|---|
| Record | `AVAudioEngine` → 16 kHz mono PCM file | [RecordingController.swift](Minutes/Recording/RecordingController.swift) |
| Live transcript | Apple `SpeechTranscriber` (iOS 26 SpeechAnalyzer), on device | [Transcription.swift](Packages/MinutesCore/Sources/MinutesCore/Transcription.swift) |
| Who spoke when | FluidAudio offline diarization: pyannote community-1 + WeSpeaker + VBx on Core ML | [SpeakerDiarizer.swift](Packages/MinutesCore/Sources/MinutesCore/SpeakerDiarizer.swift) |
| Words → speakers | per-word time overlap, island smoothing | [SpeakerAligner.swift](Packages/MinutesCore/Sources/MinutesCore/SpeakerAligner.swift) |
| Summary | Apple Foundation Models, chunked for long meetings | [Summarizer.swift](Packages/MinutesCore/Sources/MinutesCore/Summarizer.swift) |
| Export | UTF-8 text | [TranscriptExporter.swift](Packages/MinutesCore/Sources/MinutesCore/TranscriptExporter.swift) |

A few decisions worth knowing:

- **The recording file is the source of truth.** The live transcript is a preview. If it ran start to finish, its words become the transcript. If it didn't (model still downloading, an error), the file is transcribed after the meeting. Nothing the transcriber does can stop a recording.
- **Recording is uncompressed, then compressed afterwards.** If the app is killed mid-meeting, a PCM CAF is readable up to the last frame. An AAC file is not (tested: after a SIGKILL an .m4a won't open, and AAC-in-CAF reads as 0 frames). Once processed, the file is re-encoded to AAC: ~115 MB/hour → ~15 MB/hour. On the next launch, an interrupted recording shows up with a **Process Recording** button.
- **Speakers are identified after the meeting, not live.** Offline diarization is markedly more accurate than streaming. If it merges two similar voices, use **⋯ › Number of Speakers** to give the exact count. That re-runs only speaker identification, not the transcription.
- **Names and terms** (Settings) bias the transcriber toward your spellings of people, products and acronyms. That's the biggest lever for getting every word right.
- Recording continues with the screen locked (background audio). Processing needs the app open for a minute or two per hour of audio. If you leave, it picks up again on the next launch.

## Measured

Run on a Mac (M1 Pro) with `minutes-check` (below), same code as the app:

- **AMI meeting ES2004a** (17.5 min, 4 real speakers): found 4 speakers, **95.6% of words attributed to the right speaker** against the AMI reference. The whole pipeline (transcribe, speakers, two-part summary) took about a minute.
- **70-minute meeting** (that AMI file four times over): 8,581 words, live pass 53 s, speakers + six-part summary 3.5 min, peak memory 0.9 GB. It found 5 speakers rather than 4 (the extra cluster held 1% of the audio). Audio compressed 134 MB → 17 MB.
- **Synthetic 3-voice meeting** (macOS `say` voices): transcript nearly word-perfect, speaker turns at the right boundaries. Auto-detect merged the two female voices; with "3 speakers" set, 12 of 14 lines were attributed correctly.

The iPhone will be slower than the M1 Pro. Real-meeting accuracy on the phone's microphone hasn't been measured yet.

- **The same AMI meeting re-processed on the PC** (RTX 3070 Ti, WhisperX large-v3 + pyannote): **97.1%** of words to the right speaker (97.2% with 4 speakers set), 68 s of GPU time. Word error rate against AMI's transcript: 21.5% on device, 21.4% on the PC; the PC makes ~19% fewer wrong words, but both miss the same short "yeah"/"okay" interjections in crosstalk. Details: [server/README.md](server/README.md#measured).

## Maximum accuracy on a PC (optional)

For meetings where the last few percent of words matter, **⋯ › Re-process for Maximum Accuracy** sends that one recording to a server on a PC on the same network: WhisperX with Whisper large-v3, wav2vec2 word alignment and pyannote community-1 diarization, in Docker, on an NVIDIA GPU if there is one. It returns words and speaker turns in the same shapes the on-device models produce, so speaker matching, the summary (still Apple Intelligence on the iPhone) and export are unchanged. On-device stays the default; the menu item only appears once a PC is set up in Settings › Maximum accuracy (PC). Setup, deploy and API: [server/README.md](server/README.md).

## Running the pipeline on a Mac

```bash
cd Packages/MinutesCore
swift run minutes-check ~/Desktop/meeting.m4a --out ~/Desktop/meeting.txt
```

Flags: `--speakers N`, `--live` (feeds the file through the recorder's path instead), `--server 192.168.1.20` (re-processes on the PC server instead, token in `$MINUTES_SERVER_TOKEN`), `--no-summary`, `--locale en-GB`, `--vocab "Name,Acronym"`, `--json meeting.json`, `--turns`. `python3 server/eval/score_speakers.py meeting.json reference.rttm` scores speaker attribution against a reference RTTM. Needs macOS 26+ and, for summaries, Apple Intelligence on the Mac.

## Not done yet

- Processing can't yet continue in the background (iOS 26 `BGContinuedProcessingTask` would allow it).
