# StemMission

A small macOS app that splits a song into stems. Paste a YouTube link or pick an audio file, choose an output folder, hit **Generate Stems**, and watch the progress bar. When it's done, a `<title> - Stems/` folder opens in Finder.

## Output

```
<title> - Stems/
  00 Original.wav
  01 Vocals.wav
  02 Drums.wav
  03 Bass.wav
  04 Guitar.wav
  05 Piano.wav
  06 Other.wav
  Backing - No Guitar.wav   (peak -1 dBTP)
  Backing - No Vocals.wav   (peak -1 dBTP)
```

All files are 24-bit WAV. Pick the sample rate in the app:

- **Auto**: matches the source (YouTube audio is usually 48 kHz)
- **44.1 kHz** / **48 kHz**: forced, e.g. to match your DAW project

Separation always runs at 44.1 kHz, because the models are trained at that rate. Stems are then resampled with soxr (VHQ) to the chosen rate. `00 Original` is decoded straight from the source at the chosen rate, so it is never resampled twice.

## Modes

- **Best quality (RoFormer)**: a two-stage chain using [audio-separator](https://github.com/nomadkaraoke/python-audio-separator). Kim Mel-Band RoFormer splits vocals from the instrumental, then BS-RoFormer-SW splits the instrumental into drums, bass, guitar, piano and other. A 10-minute song takes about 15 minutes on an M3.
- **Fast (Demucs)**: `htdemucs_6s` on MPS. It takes about a minute per song, but the guitar and piano stems are weaker.

## Install

You need an Apple Silicon Mac (M1 or newer) running macOS 14 or later. Nothing else needs to be installed first.

1. Download `StemMission.zip` from [Releases](../../releases/latest), unzip it, and move **StemMission.app** to Applications.
2. The app is not notarized, so macOS blocks it the first time. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. Click **Install**. This one-time setup downloads Python, the separation libraries and ffmpeg (about 2.3 GB) into `~/Library/Application Support/StemMission`. Nothing outside that folder is touched.
4. The first Best-quality run also downloads the AI models (about 1.6 GB).

To uninstall, delete the app and `~/Library/Application Support/StemMission`.

yt-dlp updates itself automatically if a YouTube download fails.

## Build from source

```sh
zsh build.sh   # builds and installs ~/Applications/StemMission.app
```

## How it works

The SwiftUI app (`Sources/StemMission/main.swift`) runs `Resources/setup.sh` once. That script uses [uv](https://github.com/astral-sh/uv) to install a standalone Python 3.11, the pinned separation stack, yt-dlp and an ffmpeg binary (from imageio-ffmpeg). After that, the app runs `Resources/worker.py` with that Python. The worker talks to the app over a line protocol on stdout:

```
PROGRESS <0..1> <message>
DONE <output folder>
ERROR <message>
```
