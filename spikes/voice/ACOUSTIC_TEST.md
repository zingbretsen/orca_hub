# Acoustic test — the two human-in-the-loop checks voice mode is blocked on

**~10 minutes, one sitting.** Everything else in `voice_mode_spec.md` is
measured. These two are not, and cannot be: SPIKE 1 and SPIKE 3 ran on a fake
capture device (no speaker, no room, no mic), and SPIKE 2b's corpus is one
synthetic TTS voice.

- **Part A — AEC** decides spec §4.1 rung 3 (open channel) and §5.2
  (STOP/PAUSE during playback).
- **Part B — real-voice wake word** decides spec §5.1 (SEND on the transcript
  matcher, at threshold 0.85).
- **Part C** is optional, 2 minutes, and qualitative.

Steps and thresholds only. Rationale is in `voice_mode_spec.md` §4.1, §5.1,
§5.2 and in the two spike READMEs.

---

## 0 · Prerequisites

1. **Chrome, on a secure origin.** `http://localhost:<port>` counts;
   `http://192.168.1.177:<port>` does **not** (`navigator.mediaDevices` is
   simply `undefined`, no error). Either run Chrome on debian itself, or from
   a laptop:

       ssh -L 8777:127.0.0.1:8777 zach@192.168.1.177

   and open `http://localhost:8777/` **on the laptop**. Never the LAN IP.

2. **Speakers ON, headphones OFF for Part A.** Headphones remove the acoustic
   path and make the measurement meaningless. Normal listening volume.

3. **Start the harness server** (serves both harnesses — its document root is
   `spikes/voice/`, so `/` is SPIKE 1 and `/kws/` is SPIKE 3):

       cd ~/orca_hub/spikes/voice && ./serve.sh        # -> http://localhost:8777/

   Port 8777 is deliberate: 4000/4001 belong to the dev server and the local
   prod release. Stop it afterwards with `Ctrl-C`.

4. **The transcription container must be up** (Part B only):

       curl -sS http://192.168.1.77:8000/healthz

   Expect `{"status":"ok",...}` with `"cuda":{"available":true,...}`. If it is
   down: `ssh zach@192.168.1.77 'cd ~/transcription/docker && docker compose up -d'`.
   The **first** Part B clip may take up to 35 s if the model was evicted;
   everything after it is ~0.5–0.9 s.

---

## Part A — does browser AEC suppress our own TTS? (5 min)

5. Open `http://localhost:8777/`. Click **`open mic (AEC/NS/AGC ON)`** and
   grant the permission prompt.

6. Check the table: **`echoCancellation applied` must be green `true`**. Note
   the **AudioContext sampleRate** (it may well not be 48000 — that is
   expected, spec §9 trap 5).

7. Click **`record (direct Silero)`**, say **"orca send"**, pause ~2 s, repeat
   **three times**, then **`stop run`**.

8. In the segments table read the **`onset ms`** column. **Expect ~420–510 ms,
   not ~0** — that is the pre-roll working. Three WAVs are now in
   `spikes/voice/out/`; play one and confirm you hear the full word "orca",
   not "rca". **Keep these three WAVs — Part B reuses them.**

9. **SPEAKERS ON, HEADPHONES OFF.** Click
   **`run AEC A/B (~25 s, plays a clip twice)`** and **stay silent for ~25 s**
   while it plays a TTS clip with `echoCancellation` on, then off.

10. Read the AEC table and copy back four things: `Δ dB` for **aec-on**,
    `Δ dB` for **aec-off**, the headline **`AEC suppression = N dB`**, and
    **`triggers (playback)`** for each trial.

**Part A verdicts** — on `AEC suppression`:

| number | verdict |
|---|---|
| **> ~15 dB** | Full duplex plausible. §4.1 rung 3 is reachable; §5.2's keyword spotter is viable during playback (SPIKE 3 measured 16/16 detections at +10 dB SNR). Ship rungs 1–2 first, then revisit. |
| **~6–15 dB** | **Duck-on-detect (§4.1 rung 2) is the ceiling.** §5.2 needs the playback ducked on VAD speech-start before the spotter can work (SPIKE 3: 7/16 at 0 dB SNR). |
| **< ~6 dB** | **Half-duplex is the permanent answer.** Do not build §4.1 rung 3. §5.2 needs a different mechanism entirely (SPIKE 3: 2/16 at −6 dB SNR). |

**Independent hard FAIL:** any **`triggers (playback)` > 0 with AEC ON** means
our own TTS false-triggers the VAD. That breaks an open channel on its own,
whatever the dB number says.

11. Click **`copy results JSON`** (or **`POST results to out/`**, which writes
    `spikes/voice/out/results-<ts>.json`) and paste it into the thread.

---

## Part B — does the SEND matcher survive a real larynx? (4 min)

12. **Record 20 clips**, 5 each of the four commands, spoken the way you would
    actually say them to OrcaHub. Either reuse the harness's WAV dump
    (step 7–8, files land in `spikes/voice/out/`) or record directly:

        mkdir -p ~/voice-human && cd ~/voice-human
        for c in send cancel stop pause; do for i in 1 2 3 4 5; do
          echo "say: orca $c"; arecord -f S16_LE -r 16000 -c 1 -d 2 "${c}_${i}.wav"
        done; done

    **File naming matters** — the scorer parses it: `<intent>_<n>.wav` with
    intent in `send` | `cancel` | `stop` | `pause`. 16 kHz mono 16-bit.

13. *(Optional but it is the only way to measure FP.)* Record 5 ordinary
    dictation sentences that end near-but-not-on a command — "…and then I
    clicked submit", "…let's stop there", "…just send it to Bob" — as
    `none_1.wav` … `none_5.wav`. For these the reading is **inverted**:
    `MISS` (nothing fired) is the PASS, any fired intent is a false positive.

14. **Copy them to the GB10 box:**

        scp *_?.wav zach@192.168.1.77:/home/zach/transcription/spike-asr/audio/human/

15. **Score them** (threshold 0.85 is hardcoded, matching the spec):

        ssh zach@192.168.1.77 'cd /home/zach/transcription/spike-asr && python3 wakeword_test.py --human'

    It prints per-clip transcript / fired intent / score / verdict and a
    summary line `N/20 correct | W wrong intent | M no match`, and writes
    `results/wakeword_human.json`. Copy the whole output back.

**Part B verdicts** (the 20 command clips):

| result | verdict |
|---|---|
| **≥ 19/20 correct (≥ 95 % TP), 0 wrong intent, and 0 of the `none_*` clips fired** | **PASS.** §5.1 option (b) stands: the phonetic tail-matcher at 0.85 is the SEND path. Build it. |
| 15–18/20, with the misses scoring **0.75–0.85** | Marginal. The phrase is right, the threshold is not — re-score with a lower threshold before changing anything else, and re-check FP on the `none_*` clips at that threshold. |
| < 15/20, or misses scoring ~0.4, or any wrong intent | **FAIL.** Fall back to §5.1 option (a): SEND moves onto the openWakeWord spotter, which means training an `orca send` model (~half a day, SPIKE 3 §5). |

---

## Part C — barge-in feel (2 min, optional)

**No `orca stop` model has been trained yet**, so this uses `hey_jarvis` as a
stand-in for the phrase. It answers "does a spotter fire at all through my
speakers", not "does `orca stop` work".

16. Open a second tab at `http://localhost:8791/kws/` (or
    `http://localhost:8777/kws/` — the same server root serves both). If you
    prefer the documented port, `cd ~/orca_hub/spikes/voice/kws && ./tools/serve.sh`.

17. Click **`init openWakeWord`** with `hey_jarvis_v0.1` selected, then
    **`run live 20s (fake/real mic)`**.

18. While it runs, switch to the Part A tab and click **`run AEC A/B`** again
    so TTS is playing through the speakers, and say **"hey jarvis"** three
    times over the playback at a normal speaking volume.

19. Note **how many of the three were detected** in the kws log, and whether
    the detection landed within ~200 ms of the word ending. Report `3/3`,
    `1/3`, etc. Expect this to track Part A: near 3/3 if AEC suppression was
    > 15 dB, near 0/3 if it was < 6 dB.

---

## Paste this back

```
PART A — AEC
  echoCancellation applied  :
  AudioContext sampleRate   :
  onset ms (3 segments)     :            (expect ~420-510, not ~0)
  Δ dB  aec-on              :
  Δ dB  aec-off             :
  AEC suppression           :            dB   -> >15 / 6-15 / <6
  triggers (playback) aec-on:            (ANY non-zero = hard FAIL)
  triggers (playback) aec-off:
  results JSON              : (paste, or the out/results-<ts>.json filename)

PART B — real-voice wake word (threshold 0.85)
  correct / 20              :            (PASS >= 19)
  wrong intent              :            (PASS = 0)
  no match                  :
  none_*.wav that fired     :            (PASS = 0; skip if not recorded)
  full wakeword_test.py --human output: (paste)

PART C — barge-in (optional)
  "hey jarvis" detected     :   / 3  during TTS playback
```
