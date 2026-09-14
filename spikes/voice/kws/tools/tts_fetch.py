#!/usr/bin/env python3
"""Render every phrase this spike needs on the homelab TTS endpoint.

Chatterbox is stochastic: the SAME text rendered twice comes back with a
different duration and prosody (verified: 55,724 B vs 88,364 B for "orca send").
That is exactly what we want -- N renderings of a keyword is N genuinely
different utterances, not N copies -- so `--renders` controls the sample size
for the detection-rate measurement.

Output: assets/raw/<slug>-<NN>.wav (24 kHz mono, whatever the endpoint returns).
Cached: an existing file is never re-rendered, so re-running is cheap.
"""
import argparse, concurrent.futures as cf, json, os, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "..", "assets", "raw")
URL = os.environ.get("TTS_URL", "https://ai.lab.ingbretsenhome.com/v1/audio/speech")
MODEL = os.environ.get("TTS_MODEL", "tts-chatterbox-23lang")

# --- keywords under test -----------------------------------------------------
KEYWORDS = {
    "orca_send":   "Orca send.",
    "orca_cancel": "Orca cancel.",
    "orca_stop":   "Orca stop.",
    "orca_pause":  "Orca pause.",
    # openWakeWord pre-trained models
    "hey_jarvis":  "Hey Jarvis.",
    "alexa":       "Alexa.",
    "hey_mycroft": "Hey Mycroft.",
    # Porcupine built-ins (rendered so the numbers exist the moment a key does)
    "computer":    "Computer.",
    "jarvis":      "Jarvis.",
    "porcupine":   "Porcupine.",
}

# --- carrier speech that a keyword is spoken AFTER ---------------------------
CARRIERS = [
    "Okay, I think that covers the migration plan.",
    "Let's add a test for the empty list case as well.",
    "The deploy script needs to run on the agent node first.",
    "I want the retry to back off exponentially here.",
]

# --- negative corpus: ordinary speech + deliberate near-misses ---------------
NEAR_MISSES = [
    # near-misses for "orca <verb>"
    "Or Cassandra thought the whole thing was a mistake.",
    "The orchestra sent their apologies this morning.",
    "Orcas send signals to each other across the whole bay.",
    "Send the email to Bob when you get a chance.",
    "I was going to send it but the network was down.",
    "An orca is a kind of dolphin, not a whale.",
    "Or can send it later if that is easier.",
    "Arcade cabinets used to cost a quarter.",
    "Please cancel the meeting on Thursday.",
    "We should stop and think about this for a second.",
    "Let's pause here and come back to it tomorrow.",
    "Organic search traffic is down again this quarter.",
    "The orchard sends us apples every October.",
    "Orchestration of the containers is handled by Flux.",
    "Mark it as sent and move on.",
    "I will cancel my subscription at the end of the month.",
    # near-misses for "hey jarvis" / "alexa" / "hey mycroft"
    "Hey, Travis called about the invoice.",
    "Jarvis is the assistant in the Iron Man films.",
    "Hey there, did you get my message?",
    "Alexandra said she would look at it on Monday.",
    "A Lexus is not really my kind of car.",
    "Hey Darius, can you take a look at this?",
    "Alex asked whether the build had finished.",
    "Hey, Jarvis Cocker was the singer in Pulp.",
    "My croft is a small farm in the Scottish highlands.",
    "Hey, my crofting neighbour has sheep on the hill.",
    "Electra was a Greek tragedy by Sophocles.",
    "The lexer produces a token stream for the parser.",
]

GENERAL = [
    "The supervision tree is rebuilt on every boot from the mode configuration.",
    "We route database calls through the hub because agents have no repository.",
    "Every session gets its own message control protocol server.",
    "The warm pool evicts the least recently used idle session under pressure.",
    "Streaming keeps a long lived port open across turns.",
    "A trigger inherits its node from the project it belongs to.",
    "The scheduler only runs on the hub node, never on an agent.",
    "Quantum's default run strategy picks a random node from the cluster.",
    "That silently dropped the nightly trigger for several weeks.",
    "Artifacts render inside a sandboxed iframe with scripts allowed.",
    "The object store keeps bytes out of Postgres entirely.",
    "File visibility is creator, same project, or an explicit share.",
    "Deleting is narrower than reading, and a share never grants delete.",
    "Memory extraction spawns a cheap child session at archive time.",
    "The child reads the transcript since the last watermark.",
    "Nightly consolidation proposes merges but never retires anything.",
    "Weekly verification checks concrete claims with grep and git.",
    "Humans still decide what gets thrown away.",
    "The embedding endpoint has an eight thousand token context window.",
    "An over length input is a hard four hundred, not a truncation.",
    "Chunks are sized well under that limit for safety.",
    "The vector column is nullable because embedding can fail independently.",
    "Every search query has to filter out the null embeddings.",
    "A null means not indexed yet, not no match.",
    "The hierarchical index uses cosine distance.",
    "Creating the extension is a manual superuser step per database.",
    "Migrations cannot grant themselves superuser.",
    "We build a real multi architecture manifest list on every deploy.",
    "One node builds for x86 and the other builds for arm natively.",
    "No emulation is involved at any point.",
    "Each node keeps its own build cache warm across deploys.",
    "Cross architecture cache poisoning shipped the wrong binary twice.",
    "The architecture assertion stays as a cheap safety check.",
    "The local restart runs last because it kills the deploy script.",
    "Routing through the secure shell daemon escapes the privilege restriction.",
    "A password prompt looks exactly like a broken escape hatch.",
    "The audio worklet resamples from the context rate down to sixteen kilohertz.",
    "The ratio is not an integer and hard coding three is a bug.",
    "Whisper will happily transcribe pitch shifted audio into plausible wrong words.",
    "The pre roll ring buffer prevents the first phoneme from being clipped.",
    "Without it the leading consonant simply disappears.",
    "Voice activity detection dominates the end of speech latency budget.",
    "The redemption window is the only knob that really moves it.",
    "Six hundred milliseconds fits the budget with room to spare.",
    "The library defaults are roughly twice the target.",
    "Noise suppression does about six decibels of real work on capture.",
    "Echo cancellation is honoured in both directions.",
    "The fake capture device bypasses the acoustic loop entirely.",
    "There is no speaker, no room, and therefore no echo to cancel.",
    "Only a human with real speakers can answer that question.",
    "Half duplex remains the safe default for the first version.",
    "The assistant's reply is spoken back as the deltas arrive.",
    "Sentence chunking happens before the prefetch pipeline.",
    "Rate limiting is handled with exponential backoff.",
    "The bearer token reaches the browser through a live view event.",
    "Scoped tokens are hashed at rest and can be pinned to one session.",
    "A pinned token is rejected if it asks for a scope that takes no session.",
    "The legacy global token is preserved as a full access fallback.",
    "A scope violation returns a deliberately distinct forbidden status.",
    "It never echoes back what it denied.",
    "Detached jobs survive idle teardown and deploys.",
    "The process is never a child of the virtual machine.",
    "A disposable watcher only observes the sentinel file.",
    "The exit code is written with an atomic rename.",
    "Progress metrics are declared by the job, never inferred.",
    "We surface the age of the last update and adjudicate nothing.",
    "Churn sampling runs every two minutes on the hub.",
    "Two nodes sweeping would double sample and double alert.",
    "Alerts fire on a rising edge with a cooldown.",
    "A still true condition does not re alert every tick.",
    "The evaluator must fail closed to a neutral value.",
    "Otherwise a persistent failure ends alerting forever and silently.",
    "No alerts is the normal baseline, so nothing would look wrong.",
    "The terminal allocates a pseudo terminal through the script utility.",
    "Multiple browser tabs can join the same channel topic.",
    "Input from any client reaches the same shell.",
    "That enables pairing between a human and an agent.",
    "The prefix differs from the channel topic to avoid double delivery.",
    "Joining the same group twice is allowed and duplicates every message.",
    "Email polling is hub only because the watermark is hub state.",
    "Two pollers would race to fire the same trigger twice.",
    "The sender allow list must be non empty at the changeset level.",
    "An empty one would fire for mail from any authenticated sender.",
    "Subject matching is a case insensitive substring, not a regular expression.",
    "Setup scripts run before every firing, including a reused session.",
    "No part of an inbound payload ever reaches the script or its environment.",
    "A timeout signals the entire process group.",
    "A script that backgrounds children cannot leave orphans behind.",
    "A non zero exit is logged and surfaced, never fatal.",
    "The tool policy covers protocol tools only, not the built in file tools.",
    "That is the likeliest misreading and every surface says so.",
    "An untouched multi select casts to an empty list.",
    "Treating that as deny all would strip every tool silently.",
    "Explicit deny all is a single glob character.",
    "Deny wins over allow in every case.",
    "The policy is cached for the life of the connection.",
    "Changing it evicts the warm port so the next turn re reads it.",
    "A running session always refuses an eviction requested from outside.",
    "The flag change defers its eviction to the next idle transition.",
    "Forked children serialize their first turns through a gate.",
    "Concurrent same prefix turns get one cache hit and many cold prefills.",
    "An ungated fork is strictly worse than a plain spawn.",
    "The fork discriminant is a separate column from the parent link.",
    "Timestamps compare alphabetically by field under default term ordering.",
    "Microsecond sorts before minute, month, second, and year.",
    "Any two timestamps sharing an hour get silently scrambled.",
    "Always pass an explicit comparator to the sort function.",
    "That caused an out of order windowed feed last August.",
    "The audit found twelve rotted deployment status claims.",
    "Record the commit hash and let the reader resolve the state live.",
    "Deployments happen out of band all the time.",
    "Trunk based development means committing straight to the main branch.",
    "Commit by explicit path so you never sweep up a sibling's work.",
    "A lock file change forces a full recompile for everyone.",
    "Tell the active sessions before you land one.",
    "Establish the baseline before you start upgrading anything.",
    "A green test run proves nothing about production resolution.",
    "It never re resolves against a populated dependency directory.",
    "Prove it from a pristine tree with its own empty build directory.",
    "The archive command keeps the shared working tree untouched.",
]


def render(text, dest, timeout=120):
    body = json.dumps({"model": MODEL, "input": text, "language": "en"}).encode()
    req = urllib.request.Request(URL, data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
    if data[:4] != b"RIFF":
        raise RuntimeError("not a WAV: %r" % data[:80])
    tmp = dest + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, dest)
    return len(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--renders", type=int, default=8,
                    help="renderings per keyword phrase")
    ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args()
    os.makedirs(RAW, exist_ok=True)

    jobs = []   # (slug, index, text)
    for slug, text in KEYWORDS.items():
        for i in range(a.renders):
            jobs.append((slug, i, text))
    for i, t in enumerate(CARRIERS):
        jobs.append(("carrier", i, t))
    for i, t in enumerate(NEAR_MISSES):
        jobs.append(("nearmiss", i, t))
    for i, t in enumerate(GENERAL):
        jobs.append(("general", i, t))

    todo = [(s, i, t) for (s, i, t) in jobs
            if not os.path.exists(os.path.join(RAW, "%s-%02d.wav" % (s, i)))]
    print("%d phrases total, %d to render (%d cached)"
          % (len(jobs), len(todo), len(jobs) - len(todo)), flush=True)

    manifest = {"url": URL, "model": MODEL, "renders": a.renders,
                "keywords": KEYWORDS, "carriers": CARRIERS,
                "near_misses": NEAR_MISSES, "general": GENERAL}
    failures = []

    def work(job):
        slug, i, text = job
        dest = os.path.join(RAW, "%s-%02d.wav" % (slug, i))
        for attempt in range(3):
            try:
                return slug, i, render(text, dest)
            except Exception as e:                      # noqa: BLE001
                if attempt == 2:
                    failures.append((slug, i, repr(e)))
                    return slug, i, None
        return slug, i, None

    done = 0
    with cf.ThreadPoolExecutor(max_workers=a.workers) as ex:
        for slug, i, n in ex.map(work, todo):
            done += 1
            if done % 20 == 0 or n is None:
                print("  %d/%d %s-%02d %s" % (done, len(todo), slug, i,
                                              "FAILED" if n is None else "%d B" % n),
                      flush=True)

    with open(os.path.join(RAW, "..", "phrases.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    if failures:
        print("FAILURES: %d" % len(failures), file=sys.stderr)
        for f_ in failures[:10]:
            print("  ", f_, file=sys.stderr)
        sys.exit(1)
    print("ok")


if __name__ == "__main__":
    main()
