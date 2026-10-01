#!/bin/zsh
# StemMission first-run setup: installs everything into one folder, no Homebrew/Python needed.
#   uv (Astral) -> standalone Python 3.11 -> pinned separation stack + yt-dlp + ffmpeg binary
# Emits the same PROGRESS/DONE/ERROR protocol as worker.py.
set -e
setopt pipefail

HOME_DIR="${STEMMISSION_HOME:-$HOME/Library/Application Support/StemMission}"
ENV="$HOME_DIR/env"
UV="$HOME_DIR/bin/uv"
export UV_CACHE_DIR="$HOME_DIR/cache/uv"
export UV_PYTHON_INSTALL_DIR="$HOME_DIR/python"

p() { print -r -- "PROGRESS $1 $2" }
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/models"
exec 2>>"$HOME_DIR/setup.log"
trap 'print -r -- "ERROR Setup failed while ${STEP:-starting}. Log: $HOME_DIR/setup.log"' ERR

if [[ "$(uname -m)" != "arm64" ]]; then
  print -r -- "ERROR StemMission needs an Apple Silicon Mac (M1 or newer)."
  exit 1
fi

STEP="downloading uv"
if [[ ! -x "$UV" ]]; then
  p 0.02 "Downloading installer (uv)…"
  tmp=$(mktemp -d)
  curl -fsSL https://github.com/astral-sh/uv/releases/download/0.12.5/uv-aarch64-apple-darwin.tar.gz \
    | tar -xz -C "$tmp"
  mv "$tmp"/uv-aarch64-apple-darwin/uv "$UV"
  rm -rf "$tmp"
fi

STEP="installing Python"
p 0.08 "Installing Python 3.11…"
"$UV" python install 3.11 >&2
rm -rf "$ENV"
"$UV" venv --python 3.11 "$ENV" >&2

STEP="installing packages"
p 0.15 "Installing audio libraries (~2 GB, a few minutes)…"
"$UV" pip install --python "$ENV/bin/python" \
  torch==2.14.0 demucs==4.1.0 audio-separator==0.47.0 onnxruntime==1.30.0 \
  soundfile==0.14.0 numpy==2.4.6 soxr==1.1.0 imageio-ffmpeg yt-dlp >&2

STEP="linking ffmpeg"
p 0.85 "Setting up ffmpeg…"
ff=$("$ENV/bin/python" -c "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())")
ln -sf "$ff" "$ENV/bin/ffmpeg"

STEP="verifying"
p 0.92 "Checking installation…"
"$ENV/bin/python" -c "import torch, demucs, audio_separator, soundfile, soxr, yt_dlp; assert torch.backends.mps.is_available(), 'MPS not available'" >&2
"$ENV/bin/ffmpeg" -version >&2

rm -rf "$UV_CACHE_DIR"   # packages are already copied into env
print -r -- "1" > "$HOME_DIR/env/.stemmission-ready"
p 1 "Ready"
print -r -- "DONE $HOME_DIR"
