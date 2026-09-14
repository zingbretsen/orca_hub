#!/usr/bin/env python3
"""Independent, offline verification of the dumped segment WAVs.

The harness measures speech-onset position in-page; this recomputes it from the
files on disk with a different implementation, so a bug in the page's own
measurement cannot make the pre-roll look present when it isn't.
"""
import glob, json, os, sys, wave
import numpy as np

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "out")


def load(p):
    w = wave.open(p, "rb")
    x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768.0
    sr, ch = w.getframerate(), w.getnchannels()
    w.close()
    return x, sr, ch


def onset_ms(x, sr, rel_db=-25.0, win_ms=10):
    win = int(sr * win_ms / 1000)
    n = len(x) // win
    e = np.array([20 * np.log10(max(np.sqrt(np.mean(x[i*win:(i+1)*win]**2)), 1e-12)) for i in range(n)])
    thr = e.max() + rel_db
    idx = np.where(e > thr)[0]
    return None if not len(idx) else float(idx[0] * win_ms), e, thr


def offset_ms(e, thr, win_ms=10):
    idx = np.where(e > thr)[0]
    return None if not len(idx) else float((idx[-1] + 1) * win_ms)


def main():
    rows = []
    for p in sorted(glob.glob(os.path.join(OUT, "*.wav"))):
        x, sr, ch = load(p)
        on, e, thr = onset_ms(x, sr)
        off = offset_ms(e, thr)
        dur = len(x) / sr * 1000
        rows.append({
            "file": os.path.basename(p), "sample_rate": sr, "channels": ch,
            "total_ms": round(dur, 1),
            "speech_onset_ms": on,
            "speech_offset_ms": off,
            "trailing_silence_ms": None if off is None else round(dur - off, 1),
            "peak_dbfs": round(float(20*np.log10(max(np.abs(x).max(), 1e-12))), 2),
        })
    print(json.dumps(rows, indent=1))
    if rows:
        ons = [r["speech_onset_ms"] for r in rows if r["speech_onset_ms"] is not None]
        tails = [r["trailing_silence_ms"] for r in rows if r["trailing_silence_ms"] is not None]
        print("\n--- summary over %d files ---" % len(rows), file=sys.stderr)
        print("onset ms : min=%.0f median=%.0f max=%.0f  (pre-roll should put this near the configured preSpeechPadMs, NOT near 0)"
              % (min(ons), float(np.median(ons)), max(ons)), file=sys.stderr)
        print("trailing silence ms: min=%.0f median=%.0f max=%.0f  (~= redemption window)"
              % (min(tails), float(np.median(tails)), max(tails)), file=sys.stderr)
        print("all 16 kHz mono: %s" % all(r["sample_rate"] == 16000 and r["channels"] == 1 for r in rows), file=sys.stderr)


if __name__ == "__main__":
    main()
