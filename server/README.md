# Minutes accuracy server

Optional. Minutes runs fully on the iPhone; this server is for meetings where the last few
percent of words matter. In the app, **⋯ › Re-process for Maximum Accuracy** uploads that one
recording to a PC on your network. The PC transcribes it again with **Whisper large-v3**, aligns
every word with wav2vec2, and identifies speakers with **pyannote community-1** (all through
[WhisperX](https://github.com/m-bain/whisperX)). The app then matches words to speakers,
writes the summary and exports exactly as it does on device.

- LAN only. Every request needs the shared token, the Windows firewall rule admits only the
  local subnet, and nothing calls out to the cloud except the one-time model downloads.
- Audio is deleted from the PC as soon as a job finishes; results are kept in memory for an hour.
- **Idle, it costs nothing.** The web server never touches the GPU; Whisper and pyannote run
  in a separate process that starts when a meeting arrives (~20–30 s to load) and exits
  `KEEP_LOADED_MINUTES` (default 2) after the last one, which returns all of its VRAM. While a
  meeting is being processed it does use the GPU fully, for a minute or two on an RTX-class
  card, so a game running at that moment will stutter. On a GPU it also uses only half the CPU
  cores. Docker Desktop's own VM has a small idle footprint; quit Docker Desktop to drop even
  that.

## What it needs

- Windows 10/11 with **Docker Desktop** (WSL 2 backend). An **NVIDIA GPU** is strongly
  recommended: Docker Desktop passes it through with no extra setup beyond a current driver.
- A **Hugging Face** account that has accepted the conditions of
  [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1),
  and a **Read** token from https://huggingface.co/settings/tokens.
- ~12 GB of disk for the image and ~4 GB for the models (downloaded on first start).

### How fast

| Hardware | 17.5-min meeting (AMI ES2004a) |
|---|---|
| RTX 3070 Ti (8 GB), large-v3 float16 | **68 s** on the GPU (speakers 40 s, transcription 17 s, alignment 11 s) + 6 s to load the models; peak 6.7 GB VRAM. About 2 min from the app, including upload and the on-device summary. |
| CPU only, large-v3 int8 | not measured; expect roughly 1–2× the meeting's length (a 1-hour meeting: 1–2 hours) |
| CPU only, large-v3-turbo int8 | not measured; about a third of that |

On a PC without an NVIDIA GPU set `COMPOSE_PROFILES=cpu` and, unless you can leave it running
for hours, `WHISPER_MODEL=large-v3-turbo`.

## Set up

### 1. SSH (so it can be managed from the Mac)

On the Mac, make a key: `ssh-keygen -t ed25519 -f ~/.ssh/minutes_pc -N ""`. On the PC, in
**PowerShell run as administrator**:

```powershell
.\windows\enable-ssh.ps1 -PublicKey "<contents of ~/.ssh/minutes_pc.pub>"
```

It installs Windows' OpenSSH Server, makes PowerShell the SSH shell, opens ports 22 and 8765
to the local subnet only, and installs the key.

> **The gotcha:** if your Windows account is an administrator, sshd **ignores**
> `C:\Users\<you>\.ssh\authorized_keys`. It reads only
> `C:\ProgramData\ssh\administrators_authorized_keys`, and only if that file's permissions
> are exactly Administrators + SYSTEM (`icacls … /inheritance:r /grant Administrators:F /grant SYSTEM:F`);
> anything looser and it is silently skipped. The script writes both files.

Installing OpenSSH Server comes from Windows Update and can sit at "Operation [Running]" for
several minutes. If it never finishes, install it from Settings › System › Optional features
› View features › OpenSSH Server, then run the script again.

In Docker Desktop, turn on Settings › General › **Start Docker Desktop when you sign in**:
`docker` over SSH talks to the Docker Desktop running in your signed-in session.

### 2. Copy this folder to the PC and configure it

From the repo on the Mac (`tar` over SSH rather than `scp`: Windows' OpenSSH 10.4 preview
drops SFTP sessions, and modern `scp` uses SFTP):

```bash
ssh -i ~/.ssh/minutes_pc numai@<pc> 'New-Item -ItemType Directory -Force minutes-server | Out-Null'
cd server && COPYFILE_DISABLE=1 tar cf - app.py shaping.py requirements.txt Dockerfile compose.yaml .env.example \
  | ssh -i ~/.ssh/minutes_pc numai@<pc> 'tar xf - -C minutes-server'
```

On the PC, `copy minutes-server\.env.example minutes-server\.env`, then `notepad minutes-server\.env`
and fill in:

- `MINUTES_TOKEN`: a random string (`openssl rand -hex 16` on the Mac). The same value goes into
  the app's Settings › Maximum accuracy › Token.
- `HF_TOKEN`: your Hugging Face read token.
- `COMPOSE_PROFILES`: `gpu` or `cpu`.

### 3. Start it

```powershell
cd ~\minutes-server
docker compose up -d --build
docker compose logs -f
```

The first build downloads PyTorch with CUDA (several GB); the first start downloads the models.
It's ready when the log says `models: ready`. It restarts with Docker Desktop.

> **Docker over SSH:** a key-based SSH login has no Windows logon session, so Docker Desktop's
> credential helper fails with "A specified logon session does not exist", even for public
> images. Give SSH sessions their own Docker config with no credential store. The placeholder
> login entry matters: with none, the CLI picks Windows' credential manager anyway.
>
> ```powershell
> New-Item -ItemType Directory -Force $HOME\.docker-ssh | Out-Null
> Set-Content $HOME\.docker-ssh\config.json '{"auths": {"minutes.invalid": {}}}'
> $env:DOCKER_CONFIG = "$HOME\.docker-ssh"   # before docker commands in an SSH session
> ```

### 4. Point the app at it

Minutes › Settings › Maximum accuracy (PC): the PC's address (e.g. `192.168.1.168`, port 8765 is
assumed), the token, then **Test Connection**. iOS asks once for Local Network access; allow it.
Give the PC a fixed address (a DHCP reservation on the router) so this keeps working.

## Measured

AMI meeting ES2004a (17.5 min, 4 speakers, the mixed-headset recording), against AMI's reference
speaker turns and reference transcript, with the same app code (`minutes-check`) both ways:

| | On device (iPhone pipeline on an M1 Pro) | PC (RTX 3070 Ti) |
|---|---|---|
| Words attributed to the right speaker | 95.6% (found 4 speakers) | **97.1%** (found 5); **97.2%** with Number of Speakers = 4 |
| Word error rate | 21.5% | 21.4% |
| …of which wrong words (substitutions) | 120 | **97** |
| …of which missed words (deletions) | 401 | 421 |

What that means: the PC's real gain is **speakers** and **fewer wrong words** (~19% fewer
substitutions; several of the rest are only British/American spellings). Both engines miss the
same ~400 reference words, mostly "yeah"/"okay" said over someone else, which a single mixed
microphone buries and which don't matter for minutes; the PC misses slightly more of those,
which cancels its gain in the overall WER. On this kind of recording, on device is already close.

Scored with `eval/score_speakers.py` (per word, the reference speaker with the most overlap,
best one-to-one speaker mapping; reproduces the on-device 95.6%) and `eval/word_error_rate.py`
(lowercased, punctuation and fillers removed, numbers spelled out, against the AMI transcript
from the `edinburghcstr/ami` dataset: its segmentation, not the full corpus transcript, so
don't compare these numbers with published AMI results).

## Troubleshooting

- **"CUDA driver error: device not ready"** in speaker identification: cuDNN's convolutions fail
  in pyannote's speaker-embedding network under Docker on WSL 2 (seen on an RTX 3070 Ti, driver
  610.88, cuDNN 9.10). `engine.py` turns cuDNN off for that step only; PyTorch's own kernels
  run it in about the same time.
- **"not in the authorized list"**: the Hugging Face account behind `HF_TOKEN` hasn't accepted
  the conditions on the model page (the form is near the bottom of the page on narrow windows).
- Logs: `docker compose logs -f`. Each job logs its audio length, time and speed.

## Check it from a Mac

`minutes-check` runs the same client code as the app:

```bash
cd Packages/MinutesCore
MINUTES_SERVER_TOKEN=<token> swift run minutes-check meeting.m4a --server 192.168.1.168 --json meeting.json
python3 ../../server/eval/score_speakers.py meeting.json reference.rttm
```

## API

All under `/v1`, all with `Authorization: Bearer <MINUTES_TOKEN>`:

- `POST /v1/jobs?language=en&speakers=4&vocabulary=Acme&vocabulary=…`, body = the audio file
  (anything ffmpeg reads) → `202 {"id": …}`
- `GET /v1/jobs/{id}` → `{state: queued|running|done|failed|cancelled, stage, progress, error?, result?}`;
  `result` is `{words: [{text, start, end, confidence}], turns: [{speaker, start, end}], language, engine, device, timings}`,
  the shapes of `TimedWord` and `SpeakerTurn` in `MinutesCore/Meeting.swift`. Each word's `text`
  carries its leading space, as on device.
- `DELETE /v1/jobs/{id}` cancels or forgets a job.
- `GET /v1/status` → `{state: loading|ready|error, message, device, model, jobs}`.

`python3 test_shaping.py` tests the WhisperX → MinutesCore conversion without WhisperX installed.
