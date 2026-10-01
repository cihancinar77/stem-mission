# Stem Splitter

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

All files are 44.1 kHz / 24-bit WAV.

## Modes

- **Best quality (RoFormer)**: a two-stage chain using [audio-separator](https://github.com/nomadkaraoke/python-audio-separator). Kim Mel-Band RoFormer splits vocals from the instrumental, then BS-RoFormer-SW splits the instrumental into drums, bass, guitar, piano and other. A 10-minute song takes about 15 minutes on an M3.
- **Fast (Demucs)**: `htdemucs_6s` on MPS. It takes about a minute per song, but the guitar and piano stems are weaker.

## Requirements

- macOS 14+, Apple Silicon
- `yt-dlp` and `ffmpeg` (Homebrew): `brew install yt-dlp ffmpeg`
- A Python venv at `~/Music/_sepvenv`:

```sh
python3.11 -m venv ~/Music/_sepvenv
~/Music/_sepvenv/bin/pip install torch demucs "audio-separator[cpu]" soundfile numpy
```

Models are cached in `~/Music/_sepvenv/models` and download automatically on the first run.

## Build

```sh
zsh build.sh   # builds and installs ~/Applications/StemSplitter.app
```

## How it works

The SwiftUI app (`Sources/StemSplitter/main.swift`) runs `Resources/worker.py` with the venv's Python. The worker talks to the app over a line protocol on stdout:

```
PROGRESS <0..1> <message>
DONE <output folder>
ERROR <message>
```
