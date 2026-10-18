"""Smart metronome: beats, bars (with changing meters) and a click track, from separated stems."""
import numpy as np
import librosa

HOP = 256
METERS = (3, 4, 5, 7)  # beats per bar; 6 is left out because a 3-beat pattern also repeats after 6
PRIOR = {3: -0.4, 4: 0.0, 5: -0.8, 7: -0.8}  # per bar: favours 4 when the evidence is equal
SWITCH = np.log(2e-3)  # changing meter at a bar line is allowed but costly


def find_beats(drums, sr):
    """Beat times (s) and median BPM from the drum stem, or None when there is no steady pulse.

    beat_track gives a steady grid; each beat is then moved onto the drum hit it belongs to,
    so the click follows the drummer (live tempo drift) without skipping beats.
    """
    env = librosa.onset.onset_strength(y=drums, sr=sr, hop_length=HOP)
    _, frames = librosa.beat.beat_track(onset_envelope=env, sr=sr, hop_length=HOP, tightness=400)
    if len(frames) < 16:  # speech, ambient, no drums
        return None
    t = librosa.frames_to_time(frames, sr=sr, hop_length=HOP)

    # fill dropped beats / drop doubled ones so the click never skips
    med = np.median(np.diff(t))
    fixed = [t[0]]
    for x in t[1:]:
        g = x - fixed[-1]
        if g < 0.5 * med:
            continue
        k = int(round(g / med))
        fixed += [fixed[-1] + g * j / k for j in range(1, k)]
        fixed.append(x)
    t = np.array(fixed)

    # beat_track lands ~30 ms after the attack; snap to the attack start of the nearest hit
    hits = librosa.onset.onset_detect(onset_envelope=env, sr=sr, hop_length=HOP, units="time", backtrack=True)
    if len(hits) >= 2:
        i = np.clip(np.searchsorted(hits, t), 1, len(hits) - 1)
        near = np.where(np.abs(hits[i - 1] - t) < np.abs(hits[i] - t), hits[i - 1], hits[i])
        close = np.abs(near - t) < 0.06
        bias = np.median((t - near)[close]) if close.any() else 0.0
        t = np.where(close & (np.abs(near - (t - bias)) < 0.025), near, t - bias)
        t = np.maximum.accumulate(np.maximum(t, 0))
    return t, 60 / med


def _band_flux(y, sr):
    """Onset flux in low (<150 Hz), mid and high (>4 kHz) bands."""
    S = librosa.feature.melspectrogram(y=y, sr=sr, n_fft=2048, hop_length=HOP, n_mels=64)
    S = np.log1p(1000 * S / (S.max() + 1e-12))  # not dB: dB makes every hit after silence the same jump
    flux = np.maximum(0, np.diff(S, axis=1, prepend=S[:, :1]))
    f = librosa.mel_frequencies(n_mels=64, fmax=sr / 2)
    return np.stack([flux[f < 150].mean(0), flux[(f >= 150) & (f < 4000)].mean(0), flux[f >= 4000].mean(0)])


def _rank(x):
    return (np.argsort(np.argsort(x)) + 0.5) / len(x)


def _unit(m):
    return m / (np.linalg.norm(m, axis=1, keepdims=True) + 1e-9)


def _beat_features(times, drums, harmonic, sr):
    """Per beat: the drum pattern (to find how often it repeats) and an accent score (to find the 1)."""
    bands = _band_flux(drums, sr)
    chroma = librosa.feature.chroma_stft(y=harmonic, sr=sr, hop_length=HOP)
    nf = bands.shape[1]
    fr = lambda t: int(np.clip(round(t * sr / HOP), 0, nf - 1))
    ends = np.append(times[1:], times[-1] + np.median(np.diff(times)))
    pattern, chords, kick = [], [], []
    for t0, t1 in zip(times, ends):
        d = (t1 - t0) / 4  # four sub-beats per beat
        pattern.append(np.concatenate([bands[:, fr(t0 + s * d - d / 2):max(fr(t0 + s * d - d / 2) + 1,
                                                                          fr(t0 + s * d + d / 2))].max(1)
                                       for s in range(4)]))
        chords.append(chroma[:, fr(t0):max(fr(t0) + 1, fr(t1))].mean(1))
        kick.append(bands[0, fr(t0 - 0.03):fr(t0 + 0.05) + 1].max())
    pattern = np.array(pattern)
    chords = _unit(np.array(chords))
    change = np.r_[1.0, 1 - np.sum(chords[1:] * chords[:-1], axis=1)]
    # kick and chord changes mark the 1; snare/hats/crash and bass onsets proved misleading
    accent = 0.4 * _rank(np.array(kick)) + 0.6 * _rank(change)
    return _unit(pattern - pattern.mean(0)), np.clip(accent, 0.05, 0.95)


def _meter_evidence(pattern, window=7, temp=0.04):
    """log P(meter | beat): how well the drum pattern repeats m beats later, around each beat."""
    n = len(pattern)
    r = np.zeros((len(METERS), n))
    for j, m in enumerate(METERS):
        if n <= m:
            continue
        sim = np.sum(pattern[:-m] * pattern[m:], axis=1)
        for i in range(n):
            lo, hi = max(0, i - window), min(n - m, i + window)
            r[j, i] = sim[lo:hi].mean() if hi > lo else 0
    z = r / temp
    return z - np.logaddexp.reduce(z, axis=0)


def track_bars(times, drums, harmonic, sr):
    """Viterbi over (beats per bar, position in bar), letting the meter change at bar lines.

    Returns the beats-per-bar and position of every beat.
    """
    pattern, accent = _beat_features(times, drums, harmonic, sr)
    ev = _meter_evidence(pattern)
    states = [(m, k) for m in METERS for k in range(m)]
    last = {m: states.index((m, m - 1)) for m in METERS}
    la, lna = np.log(accent), np.log(1 - accent)
    emit = np.stack([ev[METERS.index(m)] + 2.0 * (la if k == 0 else lna) + (PRIOR[m] if k == 0 else 0)
                     for m, k in states], axis=1)
    n, S = emit.shape
    delta = emit[0].copy()
    back = np.zeros((n, S), dtype=np.int32)
    for i in range(1, n):
        new = np.empty(S)
        for s, (m, k) in enumerate(states):
            if k > 0:
                new[s], back[i, s] = delta[s - 1], s - 1
            else:
                prev = [(delta[last[m2]] + (0 if m2 == m else SWITCH), last[m2]) for m2 in METERS]
                new[s], back[i, s] = max(prev)
        delta = new + emit[i]
    s = int(np.argmax(delta))
    path = [s]
    for i in range(n - 1, 0, -1):
        s = back[i, s]
        path.append(s)
    return [states[s] for s in reversed(path)]


def analyze(drums, harmonic, sr):
    """Everything the click track and the Library need, or None when there is no steady beat."""
    found = find_beats(drums, sr)
    if not found:
        return None
    times, bpm = found
    bars = track_bars(times, drums, harmonic, sr)
    sections = []
    for t, (m, k) in zip(times, bars):
        if k != 0:
            continue
        if sections and sections[-1]["beats_per_bar"] == m:
            sections[-1]["bars"] += 1
        else:
            sections.append({"start": round(float(t), 3), "beats_per_bar": m, "bars": 1})
    return {"bpm": round(float(bpm), 1), "beats": [round(float(t), 4) for t in times],
            "downbeats": [k == 0 for _, k in bars], "sections": sections}


def click_track(times, downbeats, n, sr):
    """Stereo click: a higher, louder tick on each 1, softer ticks on the other beats."""
    tt = np.arange(int(0.04 * sr)) / sr
    tick = lambda hz, amp: amp * np.sin(2 * np.pi * hz * tt) * np.exp(-tt * 110)
    accent, beat = tick(1760, 0.8), tick(1320, 0.5)
    x = np.zeros(n, dtype=np.float32)
    for t, down in zip(times, downbeats):
        s = int(round(t * sr))
        if s >= n:
            break
        c = accent if down else beat
        x[s:s + len(c)] += c[:n - s]
    return np.stack([x, x], axis=1)
