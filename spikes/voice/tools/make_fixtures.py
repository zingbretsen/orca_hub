#!/usr/bin/env python3
"""Build deterministic test WAVs for the headless voice spike.

Chrome's --use-file-for-fake-audio-capture LOOPS the given WAV, so each fixture
is built as one loop period with EXACTLY KNOWN speech onset/offset timestamps.
Everything is 48 kHz mono 16-bit PCM (what a real mic negotiates here), so the
harness's 48k->16k worklet path is exercised for real.
"""
import json, wave, sys, os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "assets")
SR = 48000
rng = np.random.default_rng(20260914)


def read_wav(path):
    w = wave.open(path, "rb")
    assert w.getsampwidth() == 2, path
    n, ch, sr = w.getnframes(), w.getnchannels(), w.getframerate()
    x = np.frombuffer(w.readframes(n), dtype="<i2").astype(np.float64) / 32768.0
    w.close()
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr


def resample_to(x, sr_in, sr_out):
    if sr_in == sr_out:
        return x
    n_out = int(round(len(x) * sr_out / sr_in))
    # linear interpolation is plenty for fixture generation
    return np.interp(
        np.arange(n_out) / sr_out, np.arange(len(x)) / sr_in, x
    )


def write_wav(path, x, sr=SR):
    x = np.clip(x, -1.0, 1.0)
    w = wave.open(path, "wb")
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes((x * 32767.0).astype("<i2").tobytes())
    w.close()
    return os.path.getsize(path)


def dbfs(x):
    r = float(np.sqrt(np.mean(x ** 2))) if len(x) else 0.0
    return 20 * np.log10(max(r, 1e-12))


def set_dbfs(x, target):
    cur = dbfs(x)
    return x * (10 ** ((target - cur) / 20.0))


def trim_silence(x, sr, thresh_db=-45.0, pad_ms=20):
    """Trim to the energetic region so speech onset is exactly known."""
    win = int(sr * 0.010)
    n = len(x) // win
    e = np.array([dbfs(x[i * win:(i + 1) * win]) for i in range(n)])
    voiced = np.where(e > thresh_db)[0]
    if len(voiced) == 0:
        return x
    pad = int(pad_ms / 10)
    a = max(0, voiced[0] - pad) * win
    b = min(n, voiced[-1] + 1 + pad) * win
    return x[a:b]


def pink(n):
    """Pink-ish noise via 1/f shaping in the frequency domain."""
    white = rng.standard_normal(n)
    X = np.fft.rfft(white)
    f = np.arange(len(X)); f[0] = 1
    X = X / np.sqrt(f)
    y = np.fft.irfft(X, n)
    return y / (np.max(np.abs(y)) + 1e-12)


def main():
    manifest = {"sample_rate": SR, "fixtures": {}}

    speech_raw, sr0 = read_wav(os.path.join(ASSETS, "tts_orca_send.wav"))
    speech = trim_silence(resample_to(speech_raw, sr0, SR), SR)
    speech = set_dbfs(speech, -20.0)
    sent_raw, sr1 = read_wav(os.path.join(ASSETS, "tts_sentence.wav"))
    sentence = set_dbfs(trim_silence(resample_to(sent_raw, sr1, SR), SR), -20.0)

    # 1. onset fixture: lead silence -> speech -> trail silence, looped by Chrome.
    #    Everything (pre-roll presence, EOS latency, onset position) is measured
    #    against LEAD_MS.
    for name, sp, lead_ms, trail_ms in [
        ("fix_onset_orca_send", speech, 1500, 2500),
        ("fix_onset_sentence", sentence, 1500, 2500),
    ]:
        lead = np.zeros(int(SR * lead_ms / 1000))
        trail = np.zeros(int(SR * trail_ms / 1000))
        # a whisper-quiet noise floor so the stream is not mathematically
        # digital-silent (which some AEC/noise gates treat specially)
        y = np.concatenate([lead, sp, trail])
        y = y + set_dbfs(pink(len(y)), -70.0)
        p = os.path.join(ASSETS, name + ".wav")
        manifest["fixtures"][name] = {
            "path": name + ".wav", "bytes": write_wav(p, y),
            "loop_period_ms": round(len(y) / SR * 1000, 1),
            "speech_onset_ms": lead_ms,
            "speech_offset_ms": round((len(lead) + len(sp)) / SR * 1000, 1),
            "speech_dur_ms": round(len(sp) / SR * 1000, 1),
            "speech_dbfs": round(dbfs(sp), 2),
            "purpose": "pre-roll onset position, EOS latency, VAD inference",
        }

    # 2. pure-noise fixtures: NO speech at all -> every VAD fire is a false trigger.
    for name, level in [("fix_noise_pink_quiet", -50.0),
                        ("fix_noise_pink_room", -40.0),
                        ("fix_noise_pink_loud", -26.0)]:
        y = set_dbfs(pink(SR * 30), level)
        p = os.path.join(ASSETS, name + ".wav")
        manifest["fixtures"][name] = {
            "path": name + ".wav", "bytes": write_wav(p, y),
            "loop_period_ms": 30000.0, "speech_onset_ms": None,
            "noise_dbfs": round(dbfs(y), 2),
            "purpose": "false-trigger rate per minute (any fire is false)",
        }

    # 3. speech in noise at known SNR
    for name, snr in [("fix_speech_snr10", 10.0), ("fix_speech_snr05", 5.0)]:
        lead = np.zeros(int(SR * 1.5)); trail = np.zeros(int(SR * 2.5))
        base = np.concatenate([lead, speech, trail])
        nz = set_dbfs(pink(len(base)), dbfs(speech) - snr)
        y = base + nz
        p = os.path.join(ASSETS, name + ".wav")
        manifest["fixtures"][name] = {
            "path": name + ".wav", "bytes": write_wav(p, y),
            "loop_period_ms": round(len(y) / SR * 1000, 1),
            "speech_onset_ms": 1500, "snr_db": snr,
            "purpose": "VAD robustness / onset accuracy under noise",
        }

    out = os.path.join(ASSETS, "fixtures.json")
    with open(out, "w") as f:
        json.dump(manifest, f, indent=2)
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
