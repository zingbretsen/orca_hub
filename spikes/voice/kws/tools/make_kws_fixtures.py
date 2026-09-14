#!/usr/bin/env python3
"""Build the keyword-spotter test fixtures from the rendered TTS clips.

Everything the offline runner eats is 16 kHz mono 16-bit PCM -- the rate both
engines actually consume -- so no resampling happens anywhere between the
fixture and the model, and a keyword's END TIME in the fixture is exact to the
sample. Detection latency is then measured in AUDIO time (how much audio past
the keyword end the model needed), which is reproducible and needs no
wall-clock alignment. A separate 48 kHz fixture exists for the live
fake-capture-device run, where Chrome's pipeline is in the loop.

Outputs (assets/):
  det_<slug>.wav          N renderings of one keyword, isolated in near-silence
  det_<slug>_carrier.wav  same renderings, each preceded by a carrier sentence
                          so the keyword sits at TERMINAL position after speech
  neg_speech.wav          continuous speech containing NO keyword, including
                          deliberate near-misses ("or Cassandra", "orchestra",
                          "orcas send signals", "hey Travis", "Alexandra")
  neg_pink_<lvl>.wav      fresh pink noise (NOT a tiled loop -- a tiled loop
                          makes one false accept reappear once per tile and
                          inflates the rate)
  live_<slug>_48k.wav     48 kHz version for --use-file-for-fake-audio-capture
  kws_fixtures.json       manifest: exact onset/offset ms of every keyword
"""
import json, os, wave
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "assets")
RAW = os.path.join(ASSETS, "raw")
SR = 16000
rng = np.random.default_rng(20260914)


def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 2, path
        n, ch, sr = w.getnframes(), w.getnchannels(), w.getframerate()
        x = np.frombuffer(w.readframes(n), dtype="<i2").astype(np.float64) / 32768.0
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr


def resample_to(x, sr_in, sr_out):
    if sr_in == sr_out:
        return x
    n_out = int(round(len(x) * sr_out / sr_in))
    return np.interp(np.arange(n_out) / sr_out, np.arange(len(x)) / sr_in, x)


def write_wav(path, x, sr=SR):
    x = np.clip(x, -1.0, 1.0)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes((x * 32767.0).astype("<i2").tobytes())
    return os.path.getsize(path)


def dbfs(x):
    r = float(np.sqrt(np.mean(x ** 2))) if len(x) else 0.0
    return 20 * np.log10(max(r, 1e-12))


def set_dbfs(x, target):
    return x * (10 ** ((target - dbfs(x)) / 20.0))


def trim_silence(x, sr, thresh_db=-45.0, pad_ms=20):
    win = int(sr * 0.010)
    n = len(x) // win
    if n == 0:
        return x
    e = np.array([dbfs(x[i * win:(i + 1) * win]) for i in range(n)])
    voiced = np.where(e > thresh_db)[0]
    if len(voiced) == 0:
        return x
    pad = int(pad_ms / 10)
    a = max(0, voiced[0] - pad) * win
    b = min(n, voiced[-1] + 1 + pad) * win
    return x[a:b]


def first_utterance(x, sr, thresh_db=-45.0, gap_ms=150, head_pad_ms=30, tail_pad_ms=60):
    """Keep ONLY the first contiguous voiced burst.

    Chatterbox reliably appends hallucinated audio after a short keyword: a
    render of "Alexa." came back 4.00 s long, as 0.03-0.52 s of the actual word
    followed by 2.79-3.63 s and 3.94-3.95 s of unrelated speech-like noise.
    Measured across every slug, the pattern is the same -- the phrase is always
    the FIRST burst and everything past the first >=150 ms silence is junk.
    Left in, that junk both moves the keyword's end time (which is the zero
    point for every latency number) and injects unlabelled speech into a
    detection fixture.

    The 150 ms gap threshold is safe for these phrases: a two-word command like
    "orca send" is produced as one burst (0.56-0.85 s), longer than a one-word
    "alexa" (0.44-0.50 s) by about the ratio you would expect, so the second
    word is not being cut off. The hey_jarvis detection rate measured on these
    trimmed clips is the independent check -- truncating the phrase would
    collapse it.
    """
    win = int(sr * 0.010)
    n = len(x) // win
    if n == 0:
        return x
    e = np.array([dbfs(x[i * win:(i + 1) * win]) for i in range(n)])
    v = e > thresh_db
    idx = np.where(v)[0]
    if len(idx) == 0:
        return x
    start = idx[0]
    end = start
    gap = int(gap_ms / 10)
    i = start
    silence = 0
    while i < n:
        if v[i]:
            end = i
            silence = 0
        else:
            silence += 1
            if silence >= gap:
                break
        i += 1
    a = max(0, start - int(head_pad_ms / 10)) * win
    b = min(n, end + 1 + int(tail_pad_ms / 10)) * win
    return x[a:b]


def pink(n, chunk=1 << 20):
    """Pink-ish noise via 1/f shaping, generated in chunks so a 10-minute
    fixture does not need a 10-minute-long FFT."""
    out = np.empty(n)
    i = 0
    while i < n:
        m = min(chunk, n - i)
        white = rng.standard_normal(m)
        X = np.fft.rfft(white)
        f = np.arange(len(X)).astype(float); f[0] = 1.0
        y = np.fft.irfft(X / np.sqrt(f), m)
        out[i:i + m] = y / (np.max(np.abs(y)) + 1e-12)
        i += m
    return out


def load_clip(slug, i, level=-20.0, keyword=False):
    """keyword=True keeps only the first voiced burst (see first_utterance)."""
    p = os.path.join(RAW, "%s-%02d.wav" % (slug, i))
    if not os.path.exists(p):
        return None
    x, sr = read_wav(p)
    x = resample_to(x, sr, SR)
    x = first_utterance(x, SR) if keyword else trim_silence(x, SR)
    if len(x) < SR * 0.15:
        return None
    return set_dbfs(x, level)


def floor_noise(n, level=-70.0):
    """A whisper-quiet floor so the stream is never mathematically digital
    silent, which some front ends treat specially."""
    return set_dbfs(pink(n), level)


KEYWORD_SLUGS = ["orca_send", "orca_cancel", "orca_stop", "orca_pause",
                 "hey_jarvis", "alexa", "hey_mycroft",
                 "computer", "jarvis", "porcupine"]
RENDERS = 16
GAP_MS = 2000          # silence between keyword instances
LEAD_MS = 1500         # lead-in before the first instance
CARRIER_GAP_MS = 250   # pause between carrier sentence and the keyword


def build_detection(manifest, slug, carrier=False):
    clips = [c for c in (load_clip(slug, i, keyword=True) for i in range(RENDERS)) if c is not None]
    if not clips:
        return
    carriers = [c for c in (load_clip("carrier", i) for i in range(4)) if c is not None]
    parts = [np.zeros(int(SR * LEAD_MS / 1000))]
    marks = []
    pos = len(parts[0])
    for k, c in enumerate(clips):
        if carrier and carriers:
            car = carriers[k % len(carriers)]
            parts.append(car); pos += len(car)
            g = np.zeros(int(SR * CARRIER_GAP_MS / 1000))
            parts.append(g); pos += len(g)
        onset = pos
        parts.append(c); pos += len(c)
        marks.append({"index": k,
                      "onset_ms": round(onset / SR * 1000, 1),
                      "offset_ms": round(pos / SR * 1000, 1),
                      "dur_ms": round(len(c) / SR * 1000, 1)})
        g = np.zeros(int(SR * GAP_MS / 1000))
        parts.append(g); pos += len(g)
    y = np.concatenate(parts)
    y = y + floor_noise(len(y))
    name = "det_%s%s" % (slug, "_carrier" if carrier else "")
    path = os.path.join(ASSETS, name + ".wav")
    manifest["fixtures"][name] = {
        "path": name + ".wav", "bytes": write_wav(path, y),
        "duration_ms": round(len(y) / SR * 1000, 1),
        "keyword": slug, "carrier": carrier,
        "instances": marks, "n": len(marks),
        "purpose": "detection rate + detection latency (latency is measured "
                   "from instance offset_ms)",
    }


def build_over_background(manifest, phrases, slug, snrs=(10.0, 0.0, -6.0)):
    """The keyword spoken WHILE the assistant is talking -- spec section 5.2's
    actual scenario, where the transcript path is muted or echo-degraded.

    Background is continuous TTS speech (the same corpus used for neg_speech),
    which stands in for our own playback leaking into the mic. Browser AEC
    would attenuate the real thing by an unknown amount (SPIKE 1 could not
    measure it with a fake capture device), so the SNR sweep brackets the
    answer instead of assuming one: +10 dB is "AEC works", -6 dB is "AEC barely
    helps and the user is talking over a loud reply".
    """
    clips = [c for c in (load_clip(slug, i, keyword=True) for i in range(RENDERS))
             if c is not None]
    if not clips:
        return
    bg_parts = []
    for i in range(len(phrases["general"])):
        c = load_clip("general", i)
        if c is not None:
            bg_parts.append(c)
    if not bg_parts:
        return
    bg = np.concatenate(bg_parts)
    for snr in snrs:
        parts = [np.zeros(int(SR * LEAD_MS / 1000))]
        marks, pos = [], len(parts[0])
        for k, c in enumerate(clips):
            onset = pos
            parts.append(c); pos += len(c)
            marks.append({"index": k, "onset_ms": round(onset / SR * 1000, 1),
                          "offset_ms": round(pos / SR * 1000, 1),
                          "dur_ms": round(len(c) / SR * 1000, 1)})
            g = np.zeros(int(SR * GAP_MS / 1000)); parts.append(g); pos += len(g)
        y = np.concatenate(parts)
        b = np.resize(bg, len(y))
        # keyword clips are already normalised to -20 dBFS by load_clip
        b = set_dbfs(b, -20.0 - snr)
        y = y + b + floor_noise(len(y))
        name = "bg_%s_snr%s" % (slug, ("m%02d" % abs(snr)) if snr < 0 else "%02d" % snr)
        path = os.path.join(ASSETS, name + ".wav")
        manifest["fixtures"][name] = {
            "path": name + ".wav", "bytes": write_wav(path, y),
            "duration_ms": round(len(y) / SR * 1000, 1),
            "keyword": slug, "snr_db": snr, "background": "continuous TTS speech",
            "instances": marks, "n": len(marks),
            "purpose": "detection while the assistant is speaking (spec 5.2)",
        }


def build_negative_speech(manifest, phrases):
    """One long stream of ordinary speech with NO keyword in it. Any detection
    here is a false accept."""
    clips = []
    for slug, texts in (("general", phrases["general"]),
                        ("nearmiss", phrases["near_misses"])):
        for i, text in enumerate(texts):
            c = load_clip(slug, i)
            if c is not None:
                clips.append((c, (slug, i, text)))
    order = list(range(len(clips)))
    rng.shuffle(order)
    parts, pos, total_speech, utts = [], 0, 0, []
    for j in order:
        c, (slug, i, text) = clips[j]
        # Record WHICH sentence sits where, so a false accept can be named
        # rather than just counted -- "it fired on 'Alexandra said she would
        # look at it on Monday'" is the actionable form of the finding.
        utts.append({"slug": slug, "index": i, "text": text,
                     "onset_ms": round(pos / SR * 1000, 1),
                     "offset_ms": round((pos + len(c)) / SR * 1000, 1)})
        parts.append(c); pos += len(c); total_speech += len(c)
        g = np.zeros(int(SR * 0.30))
        parts.append(g); pos += len(g)
    y = np.concatenate(parts) + floor_noise(pos)
    path = os.path.join(ASSETS, "neg_speech.wav")
    manifest["fixtures"]["neg_speech"] = {
        "path": "neg_speech.wav", "bytes": write_wav(path, y),
        "duration_ms": round(len(y) / SR * 1000, 1),
        "speech_ms": round(total_speech / SR * 1000, 1),
        "n_utterances": len(clips), "utterances": utts,
        "purpose": "false accepts per hour on SPEECH (no keyword present)",
        "note": "includes deliberate near-misses; see phrases.json near_misses",
    }


def build_negative_noise(manifest, minutes=5.0):
    for name, level in (("neg_pink_quiet", -50.0), ("neg_pink_room", -40.0),
                        ("neg_pink_loud", -26.0)):
        n = int(SR * 60 * minutes)
        y = set_dbfs(pink(n), level)
        path = os.path.join(ASSETS, name + ".wav")
        manifest["fixtures"][name] = {
            "path": name + ".wav", "bytes": write_wav(path, y),
            "duration_ms": round(n / SR * 1000, 1), "noise_dbfs": level,
            "purpose": "false accepts per hour on NOISE (fresh noise, not a tiled loop)",
        }


def build_live(manifest, slugs=("orca_send", "hey_jarvis", "alexa")):
    """48 kHz fixtures for Chrome's fake capture device. Chrome LOOPS the file
    for the browser's lifetime, so one file is exactly one loop period."""
    for slug in slugs:
        clips = [c for c in (load_clip(slug, i, keyword=True) for i in range(4)) if c is not None]
        if not clips:
            continue
        parts = [np.zeros(int(SR * 1.5))]
        marks, pos = [], len(parts[0])
        for k, c in enumerate(clips):
            marks.append({"index": k, "onset_ms": round(pos / SR * 1000, 1),
                          "offset_ms": round((pos + len(c)) / SR * 1000, 1)})
            parts.append(c); pos += len(c)
            g = np.zeros(int(SR * 2.0)); parts.append(g); pos += len(g)
        y = np.concatenate(parts) + floor_noise(pos)
        y48 = resample_to(y, SR, 48000)
        name = "live_%s_48k" % slug
        path = os.path.join(ASSETS, name + ".wav")
        manifest["fixtures"][name] = {
            "path": name + ".wav", "bytes": write_wav(path, y48, 48000),
            "sample_rate": 48000,
            "loop_period_ms": round(len(y) / SR * 1000, 1),
            "keyword": slug, "instances": marks,
            "purpose": "live realtime run through the AudioWorklet (fake device)",
        }


def main():
    with open(os.path.join(ASSETS, "phrases.json")) as f:
        phrases = json.load(f)
    manifest = {"sample_rate": SR, "renders_per_keyword": RENDERS,
                "gap_ms": GAP_MS, "lead_ms": LEAD_MS, "fixtures": {}}
    for slug in KEYWORD_SLUGS:
        build_detection(manifest, slug, carrier=False)
        build_detection(manifest, slug, carrier=True)
    for slug in ("hey_jarvis", "alexa"):
        build_over_background(manifest, phrases, slug)
    build_negative_speech(manifest, phrases)
    build_negative_noise(manifest)
    build_live(manifest)
    with open(os.path.join(ASSETS, "kws_fixtures.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    for k, v in manifest["fixtures"].items():
        print("%-28s %9d B  %8.1f s  %s" % (k, v["bytes"], v["duration_ms"] / 1000
              if "duration_ms" in v else v.get("loop_period_ms", 0) / 1000,
              v.get("n", v.get("n_utterances", ""))))


if __name__ == "__main__":
    main()
