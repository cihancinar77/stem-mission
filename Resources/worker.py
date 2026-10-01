#!/usr/bin/env python3
"""StemMission worker: YouTube link / audio file -> stems folder.

Emits line-based protocol on stdout for the Swift UI:
  PROGRESS <0..1> <message>
  DONE <output folder>
  ERROR <message>
"""
import argparse, glob, os, re, shutil, signal, subprocess, sys
from pathlib import Path

# everything lives in the folder setup.sh created
HOME_DIR = Path(os.environ.get("STEMMISSION_HOME",
                               Path.home() / "Library/Application Support/StemMission"))
MODELS = HOME_DIR / "models"
BIN = HOME_DIR / "env" / "bin"
UV = HOME_DIR / "bin" / "uv"
YTDLP = str(BIN / "yt-dlp")
FFMPEG = str(BIN / "ffmpeg")
MODEL_SR = 44100  # both RoFormer and Demucs models run at 44.1 kHz

child = None


def emit(kind, *parts):
    print(kind, *parts, flush=True)


def progress(frac, msg):
    emit("PROGRESS", f"{max(0.0, min(1.0, frac)):.4f}", msg)


def on_term(*_):
    if child and child.poll() is None:
        child.terminate()
    sys.exit(130)


signal.signal(signal.SIGTERM, on_term)


def run(cmd, lo, hi, msg, parse):
    """Run a subprocess, mapping its progress output into [lo, hi]."""
    global child
    env = dict(os.environ, PATH=f"{BIN}:/usr/bin:/bin",
               AUDIO_SEPARATOR_MODEL_DIR=str(MODELS), PYTHONUNBUFFERED="1")
    child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    tail, buf = [], b""
    progress(lo, msg)
    while True:
        ch = child.stdout.read(1)
        if not ch:
            break
        if ch not in (b"\r", b"\n"):
            buf += ch
            continue
        line = buf.decode("utf-8", "replace").strip()
        buf = b""
        if not line:
            continue
        tail = (tail + [line])[-15:]
        r = parse(line)
        if r is not None:
            frac, sub = r
            progress(lo + (hi - lo) * frac, sub or msg)
    if child.wait() != 0:
        raise RuntimeError(f"{msg} failed:\n" + "\n".join(tail))
    progress(hi, msg)


def tqdm_parse(msg):
    def parse(line):
        m = re.search(r"(\d{1,3})%\|", line)
        if not m:
            return None
        if "B/s" in line or "iB" in line:  # model download bar, not inference
            return (0.0, "Downloading model (first run)… " + m.group(1) + "%")
        return (int(m.group(1)) / 100, f"{msg} {m.group(1)}%")
    return parse


def ytdlp_parse(line):
    m = re.search(r"\[download\]\s+([\d.]+)%", line)
    if m:
        return (float(m.group(1)) / 100, f"Downloading {float(m.group(1)):.0f}%")
    return None


def sample_rate_of(path):
    # ffmpeg -i prints stream info to stderr ("44100 Hz"); avoids needing ffprobe
    info = subprocess.run([FFMPEG, "-hide_banner", "-i", str(path)], capture_output=True, text=True).stderr
    m = re.search(r"Audio:.*?(\d{4,6}) Hz", info)
    return int(m.group(1)) if m else MODEL_SR


def video_title(url):
    cmd = [YTDLP, "--no-playlist", "--print", "title", url]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        # YouTube changes often; a fresh yt-dlp usually fixes it
        progress(0.0, "Updating yt-dlp…")
        subprocess.run([str(UV), "pip", "install", "--python", str(BIN / "python"), "-U", "yt-dlp"],
                       capture_output=True)
        r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("Could not read link:\n" + r.stderr[-800:])
    return r.stdout.strip().splitlines()[0]


def safe_name(s):
    s = re.sub(r'[\\/:*?"<>|]+', " ", s).strip()
    return re.sub(r"\s+", " ", s)[:120] or "Stems"


def unique_dir(p):
    if not p.exists():
        return p
    i = 2
    while Path(f"{p} ({i})").exists():
        i += 1
    return Path(f"{p} ({i})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--mode", choices=["best", "fast"], default="best")
    ap.add_argument("--sample-rate", default="auto", help="auto (match source), 44100 or 48000")
    a = ap.parse_args()

    src = a.input.strip().strip("'\"")
    outroot = Path(a.outdir).expanduser()
    outroot.mkdir(parents=True, exist_ok=True)
    is_url = re.match(r"https?://", src) is not None

    if is_url:
        title = video_title(src)
    else:
        p = Path(src).expanduser()
        if not p.is_file():
            raise RuntimeError(f"File not found: {p}")
        title = p.stem

    out = unique_dir(outroot / f"{safe_name(title)} - Stems")
    work = out / "_work"
    work.mkdir(parents=True)

    if is_url:
        run([YTDLP, "--no-playlist", "--newline", "-f", "bestaudio", "--ffmpeg-location", FFMPEG,
             "-o", str(work / "download.%(ext)s"), src], 0.0, 0.08, "Downloading", ytdlp_parse)
        raw = Path(glob.glob(str(work / "download.*"))[0])
    else:
        raw = Path(src).expanduser()

    src_sr = sample_rate_of(raw)
    out_sr = src_sr if a.sample_rate == "auto" else int(a.sample_rate)

    src_f32 = work / "src.wav"
    run([FFMPEG, "-y", "-v", "error", "-i", str(raw), "-ar", str(MODEL_SR), "-ac", "2",
         "-c:a", "pcm_f32le", str(src_f32)], 0.08, 0.10, "Preparing audio", lambda l: None)

    if a.mode == "best":
        sep = str(BIN / "audio-separator")
        common = ["--model_file_dir", str(MODELS), "--output_format", "WAV", "--use_soundfile"]
        run([sep, str(src_f32), "-m", "vocals_mel_band_roformer.ckpt",
             "--output_dir", str(work / "step1"), *common],
            0.10, 0.33, "1/2 Separating vocals", tqdm_parse("1/2 Separating vocals"))
        inst = glob.glob(str(work / "step1" / "*_(other)_*.wav"))[0]
        voc1 = glob.glob(str(work / "step1" / "*_(vocals)_*.wav"))[0]
        run([sep, inst, "-m", "BS-Roformer-SW.ckpt", "--output_dir", str(work / "step2"), *common],
            0.33, 0.93, "2/2 Separating instruments", tqdm_parse("2/2 Separating instruments"))
        g = lambda n: glob.glob(str(work / "step2" / f"*_({n})_*.wav"))[0]
        files = {"Vocals": [voc1, g("vocals")], "Drums": [g("drums")], "Bass": [g("bass")],
                 "Guitar": [g("guitar")], "Piano": [g("piano")], "Other": [g("other")]}
    else:
        run([str(BIN / "python"), "-m", "demucs", "-n", "htdemucs_6s", "-d", "mps", "--float32",
             "-o", str(work / "demucs"), str(src_f32)],
            0.10, 0.93, "Separating stems (fast)", tqdm_parse("Separating stems (fast)"))
        d = work / "demucs" / "htdemucs_6s" / "src"
        files = {n.capitalize(): [str(d / f"{n}.wav")]
                 for n in ("vocals", "drums", "bass", "guitar", "piano", "other")}

    progress(0.94, f"Writing files ({out_sr / 1000:g} kHz)")
    import numpy as np, soundfile as sf, soxr

    stems = {}
    for name, paths in files.items():
        x = None
        for p in paths:
            y, sr = sf.read(p, dtype="float32", always_2d=True)
            if x is None:
                x = y
            else:
                n = min(len(x), len(y))
                x = x[:n] + y[:n]
        stems[name] = x
    n = min(len(x) for x in stems.values())
    stems = {k: v[:n] for k, v in stems.items()}

    def write(name, x, peak_dbtp=None, sr=MODEL_SR):
        if sr != out_sr:
            x = soxr.resample(x, sr, out_sr, quality="VHQ")
        if peak_dbtp is not None:
            x = x * (10 ** (peak_dbtp / 20) / (np.max(np.abs(x)) + 1e-9))
        sf.write(str(out / f"{name}.wav"), np.clip(x, -1, 1), out_sr, subtype="PCM_24")

    for i, (name, x) in enumerate(stems.items(), 1):
        write(f"{i:02d} {name}", x)
    write("Backing - No Guitar", sum(v for k, v in stems.items() if k != "Guitar"), -1.0)
    write("Backing - No Vocals", sum(v for k, v in stems.items() if k != "Vocals"), -1.0)
    # original straight from the source at the output rate (no double resampling)
    orig = work / "orig.wav"
    subprocess.run([FFMPEG, "-y", "-v", "error", "-i", str(raw), "-ar", str(out_sr), "-ac", "2",
                    "-c:a", "pcm_f32le", str(orig)], check=True)
    write("00 Original", sf.read(str(orig), dtype="float32", always_2d=True)[0], sr=out_sr)

    shutil.rmtree(work, ignore_errors=True)
    progress(1.0, "Done")
    emit("DONE", str(out))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        emit("ERROR", str(e).replace("\n", " ⏎ "))
        sys.exit(1)
