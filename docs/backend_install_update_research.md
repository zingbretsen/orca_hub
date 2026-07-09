# Backend install/update mechanics — research for Nodes page INSTALL/UPDATE actions

Discovery pass for the planned per-backend INSTALL/UPDATE actions on
`/nodes/:id` (`OrcaHubWeb.NodeLive.Show`) plus a one-click "update all
backends across all nodes." Read-only research only — nothing was
installed/upgraded on this host or the k3s pods. Verified against:
this host (`zach`, systemd `orca-hub` agent), the `orca-hub` k3s pod (DB
hub), the `orca-agent-discord` k3s pod (Discord agent), `--help` output of
all three CLIs, and web docs/GitHub issues where `--help` was silent.

## TL;DR / hard blockers

1. **codex and pi cannot be installed on either k3s pod.** The pods'
   Docker image (`Dockerfile`) only installs the Claude native binary —
   no Node.js/npm runtime at all. `which node npm codex pi` all resolve to
   nothing in both `orca-hub` and `orca-agent-discord` pods. Installing
   them would require rebuilding the Docker image (adding a Node.js
   layer), which is out of scope for an in-app INSTALL button. **The
   feature must gate codex/pi INSTALL actions off (or show a clear
   "requires image rebuild" message) for any node whose backing image
   lacks Node.js** — detectable by checking for `node`/`npm` in PATH.
2. **Claude installs/updates on the k3s pods are ephemeral.** Both pods'
   PVCs (`orca-hub-claude`, `orca-agent-discord-claude`, both `local-path`
   storage class, 1Gi nominal but unenforced — see below) mount ONLY
   `/home/orca/.claude` (credentials/session data). The Claude binary
   itself lives at `/home/orca/.local/bin/claude` →
   `/home/orca/.local/share/claude/versions/<ver>`, which is **not** on
   the PVC — it's baked into the container's writable layer by the
   Dockerfile's `curl -fsSL https://claude.ai/install.sh | su orca -c bash`
   step. Any in-pod `claude update`/`claude install` therefore evaporates
   on the next `kubectl rollout restart` / pod reschedule. The durable
   fix is rebuilding the Docker image with a newer `claude.ai/install.sh`
   pin (or bumping whatever pins the version at build time — currently
   the Dockerfile just installs "latest at build time," unpinned). The
   feature should surface this plainly for k3s nodes, e.g. "Updated to
   2.1.202 — this will NOT survive the next pod restart; rebuild the
   Docker image to persist it," rather than implying the update is durable.
3. **No sudo dependency anywhere.** This host: `/home/zach/.local/bin`,
   `/home/zach/.npm-global` are all owned by `zach` (the user the
   `orca-hub` systemd service runs as, `NoNewPrivileges=yes`). Pods: both
   `/home/orca/.local` and the PVC are owned by `orca` (uid 1000), which is
   also the container's runtime user. `System.find_executable/1` already
   resolves all three binaries from the app's inherited `PATH` in both
   environments (confirmed via `systemctl show orca-hub -p Environment`
   and the Dockerfile's `ENV PATH="/home/orca/.local/bin:${PATH}"`) — no
   new PATH/env plumbing needed to shell out to install/update commands.

## Per-backend mechanics

### Claude Code

Installed via the **native installer** on every node in this cluster
(confirmed — not npm). Layout: `~/.local/bin/claude` is a symlink to
`~/.local/share/claude/versions/<version>` (a real, standalone executable
file per version, ~250MB). Old versions are left on disk after an update
(this host has `2.1.199`, `2.1.200`, `2.1.202`, plus a manually-kept
`claude.bak` symlink to `2.1.15`) — **updates never truncate/overwrite the
running binary in place**; they write a brand-new versioned file and
atomically swap the symlink. A session process that already has the old
version's file open (or the OS already loaded its pages) is completely
unaffected by an update running concurrently — the old file isn't touched
at all until something explicitly prunes `versions/`. This is the safest
concurrency story of the three backends.

| | Command |
|---|---|
| Detect installed | `System.find_executable("claude")` (already used in `backend/claude.ex:126`) |
| Current version | `claude --version` / `claude -v` → e.g. `2.1.202 (Claude Code)` |
| Latest version (no install) | **No documented read-only check exists.** `claude --help` has no `--check`/`--dry-run` flag; `code.claude.com/docs/en/cli-reference` doesn't document one either. The only external reference is `github.com/anthropics/claude-code/releases`, which is a lagging community mirror, not authoritative for internal build numbers — not recommended as a version-compare source. |
| Fresh install (no claude present) | `claude install [target]` where target is `stable`, `latest`, or an exact version (e.g. `2.1.118`); `--force` reinstalls even if already present. This is itself the CLI's own subcommand — but obviously requires the binary to already exist to invoke `claude install`, so for a truly claude-less node the actual bootstrap is the shell installer: `curl -fsSL https://claude.ai/install.sh \| bash` (exactly what the Dockerfile runs). The feature's "fresh install" action for a node with no `claude` in PATH should shell out to this curl pipe, not `claude install`. |
| Update (already present) | `claude update` (alias `claude upgrade`) — "Check for updates and install if available." Only flag is `-h`. Docs confirm this is "most effective when installed via the native installer" (true for every node here). |
| Non-interactive/headless | Not explicitly documented either way. Given the CLI's `-p`/headless mode is a first-class, heavily-documented use case (CI pipelines, `stream-json` output, etc.) and `update`/`install` take no confirmation-related flags, they're very likely fully scriptable without a TTY — but this is inferred, not doc-confirmed. **Recommend a one-time smoke test in a scratch/CI-like environment (no TTY, no stdin) before shipping**, rather than assuming. |
| Duration | Unmeasured (didn't want to trigger a real download). Binary is ~250-260MB; expect low-tens-of-seconds on typical bandwidth. |
| Writes to | `~/.local/share/claude/versions/<new-version>` (new file) + symlink swap at `~/.local/bin/claude`. Never touches the old version file. |
| Pod persistence caveat | **Ephemeral** — see hard blocker #2 above. |

### Codex (OpenAI Codex CLI)

Installed via **npm global** on this host: `@openai/codex` in
`~/.npm-global/lib/node_modules/@openai/codex`, symlinked from
`~/.npm-global/bin/codex` → `~/.local/bin/codex`. **Not present at all**
on either k3s pod (no Node.js in that image — hard blocker #1).

| | Command |
|---|---|
| Detect installed | `System.find_executable("codex")` (already used in `backend/codex.ex:127`) |
| Current version | `codex --version` / `-V` → e.g. `codex-cli 0.142.5` |
| Latest version (no install) | `npm view @openai/codex version` — read-only, fast (~0.9s measured here), no auth needed. Also `npm outdated -g` lists all outdated global packages including codex in one shot (`Current`/`Wanted`/`Latest` columns) — useful if the "update all" action wants a single batched check across codex+pi+pnpm etc. |
| Fresh install (no codex present) | `npm install -g @openai/codex` (requires Node.js/npm present — not true of the k3s pods) |
| Update (already present) | Codex ships a built-in `codex update`, but it has a **known, currently-unresolved bug** ([openai/codex#24035](https://github.com/openai/codex/issues/24035)): it can misdetect the install method (tries the standalone `install.sh` binary-swap path even when the resolved binary is actually an npm-managed symlink under `~/.local/bin`), producing a SHA-256 digest error instead of updating. **Recommendation: don't trust `codex update`'s self-detection — for any codex install confirmed to be npm-managed (this cluster's only install method), run `npm install -g @openai/codex@latest` directly instead.** This sidesteps the detection bug entirely and matches how codex is actually installed everywhere in this deployment. |
| Non-interactive/headless | `npm install -g` is fully non-interactive/scriptable (standard npm behavior, no TTY prompts for a version bump). `codex update` behavior is undocumented beyond the bug above — another reason to prefer the direct npm command. |
| Duration | Unmeasured directly, but npm global installs of small CLI packages are typically single-digit seconds. |
| Writes to | `~/.npm-global/lib/node_modules/@openai/codex/` — npm extracts a new tarball into the package dir. **Concurrency note:** unlike Claude's versioned-directory approach, npm overwrites files in place inside the existing package directory (no atomic whole-directory swap). A process that already `require()`'d/read the old `codex.js` at spawn time keeps running fine (Linux inode semantics — the OS holds the old file's data as long as any process has it open/mapped), but there's a narrow window where a **brand-new** codex spawn starting exactly during the npm write could read a partially-updated file. Low-probability, not zero — the implementation should avoid running an update while new codex sessions might be starting, if it can (e.g. serialize via a lock, or just accept the small risk window, same as any live software update). One other known npm-specific footgun from the wild ([openai/codex#26563](https://github.com/openai/codex/issues/26563)): on NFS-backed filesystems, npm's self-update can hang because the running binary keeps the old file open, and NFS's `.nfs*` unlink semantics differ from local ext4. Not applicable here (local-path/ext4 on both host and pods), but worth a comment in code in case a future node uses NFS-backed storage. |
| Pod persistence caveat | N/A — codex can't be installed on the pods at all today (hard blocker #1). |

### pi (`@earendil-works/pi-coding-agent`)

Installed via **npm global** on this host, same pattern as codex:
`~/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent`,
symlinked `~/.npm-global/bin/pi` → `~/.local/bin/pi`. Package name
confirmed from both the live `npm ls -g` output and
`lib/orca_hub/backend/pi.ex`'s moduledoc/error message. **Not present at
all** on either k3s pod (same hard blocker #1 as codex).

| | Command |
|---|---|
| Detect installed | `System.find_executable("pi")` (already used in `backend/pi.ex:272`) |
| Current version | `pi --version` / `-v` → e.g. `0.80.3` |
| Latest version (no install) | `npm view @earendil-works/pi-coding-agent version` — same read-only npm-registry check as codex (~0.5s measured here). |
| Fresh install (no pi present) | `npm install -g @earendil-works/pi-coding-agent` |
| Update (already present) | pi has a well-documented, purpose-built self-updater: **`pi update`** (alone) updates pi itself only (this is the default target); `pi update --all` updates pi **and** all installed extensions/packages; `pi update --extensions` updates packages only; `pi update <source>` updates one specific package; `--force` reinstalls even if already latest. Unlike codex's buggy self-detection, pi's implementation appears actively maintained for exactly this npm-global scenario — GitHub history shows fixes specifically for "`pi update --self` fails when installed with `npm --prefix`" ([earendil-works/pi#3942](https://github.com/earendil-works/pi/issues/3942)) and hardening around `--ignore-scripts` for the self-update path, plus a handled npm package rename migration (`@mariozechner/pi-coding-agent` → `@earendil-works/pi-coding-agent`). **Recommendation: prefer `pi update` (pi's own command) over shelling out to npm directly** — the opposite recommendation from codex, because pi's self-updater is the actively-fixed, purpose-built path rather than a buggy wrapper. |
| Non-interactive/headless | Not explicitly flagged in `--help`, but `pi update` takes no confirmation prompts in its documented flag surface (`--approve`/`--no-approve` govern *project-local file trust*, not update confirmation) — very likely scriptable as-is, same "verify once before shipping" caveat as Claude. |
| Duration | Unmeasured; pi's package is npm-based like codex, expect similar single-digit-to-tens-of-seconds range. |
| Writes to | `~/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent/` via npm, same in-place-overwrite semantics and narrow-window caveat as codex above (pi's own `--ignore-scripts` hardening reduces *lifecycle-script* risk, not this file-write-race concern). |
| Pod persistence caveat | N/A — pi can't be installed on the pods at all today (hard blocker #1). |

## Recommended uniform strategy per backend

- **Claude**: always drive updates through `claude update` (native
  installer's own command — versioned-directory + symlink-swap makes it
  the safest of the three under concurrent sessions). For a claude-less
  node, fresh-install via the official `curl -fsSL https://claude.ai/install.sh | bash`
  pipe (matches the Dockerfile exactly). There is no reliable
  "latest version without installing" check — show only the currently
  installed version, and make the update action itself cheap/idempotent
  (a no-op if already current) rather than trying to preview whether an
  update is available.
- **Codex**: bypass `codex update` entirely and always run
  `npm install -g @openai/codex@latest` directly — sidesteps the
  documented install-method-misdetection bug and matches how it's
  actually installed everywhere in this deployment. Use
  `npm view @openai/codex version` for the "latest available" check.
- **pi**: prefer pi's own `pi update` (optionally `pi update --all` if the
  feature also wants to sweep pi's extensions, though that's likely out
  of scope for a CLI-version-only feature) — it's the actively-maintained,
  purpose-built path. Use
  `npm view @earendil-works/pi-coding-agent version` for the "latest
  available" check.
- **All three**: detect "installed?" via the existing
  `Backend.<X>.installed?/0` callbacks (already wrap
  `System.find_executable/1`) rather than re-implementing detection.
- **k3s nodes specifically**: gate codex/pi INSTALL actions off entirely
  (no Node.js in the image); label any Claude update on a k3s node as
  non-persistent across pod restarts, since only `/home/orca/.claude` is
  a PVC, not `/home/orca/.local`.

## Open items for the implementation stage (not resolved by this research)

1. **Confirm non-interactive behavior empirically** for `claude update`
   and `pi update` in a disposable/sandboxed environment before wiring
   them into a button the app can invoke unattended (docs don't say
   either way; inferred safe but unverified).
2. **Decide the k3s persistence story**: either (a) ship the ephemeral
   caveat as explicit UI copy and accept that updates must also be
   re-baked into the Docker image periodically, or (b) widen the PVC
   mount to cover `/home/orca/.local` too (nominal capacity is
   unenforced — both PVCs use the `local-path` StorageClass, which is
   just a hostPath dir with no real quota, confirmed via `kubectl get
   storageclass` showing `rancher.io/local-path` and `ALLOWVOLUMEEXPANSION:
   false` — so 1Gi is a soft/nominal request, not a hard ceiling, though
   it should still be bumped for correctness if (b) is chosen). Widening
   scope this way is a bigger architectural change than "add a button" and
   probably deserves its own decision, not an assumption baked into this
   feature.
3. **"Update all backends across all nodes"** will need to fan out over
   `OrcaHub.Cluster`-routed RPCs (mirroring how `Cluster.rpc/5` already
   routes session/terminal actions to the owning node) — each node runs
   its own install/update commands locally; there's no cross-node shared
   filesystem to exploit even between the two k3s pods (separate PVCs).
