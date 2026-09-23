# syntax=docker/dockerfile:1

# === Build stage ===
ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.2.3
ARG DEBIAN_CODENAME=bookworm

# Named `source` rather than `builder` because it now stops at `COPY lib lib`:
# the `beams` stage below (hot code generations) and the `builder` stage (the
# release) both branch off it. The instructions are the same ones, in the same
# order, as when this was a single stage, so BuildKit's cache keys — and the
# release/image bytes — are unchanged; a stage NAME is not part of any key.
FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_CODENAME}-20260223 AS source

RUN apt-get update -y && \
    apt-get install -y build-essential git curl nodejs npm && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# No .git dir reaches the build context (only lib/priv/assets/rel are
# COPYed below), so OrcaHub.BuildInfo can't shell out to `git rev-parse`
# the way a host `mix release` build can. The deploy script passes this as
# --build-arg GIT_SHA=$(git rev-parse --short HEAD); it's written to
# priv/git_sha further down (right where priv is COPYed in, not here) so
# that a changing GIT_SHA doesn't invalidate the deps layers below on every
# single build — ARG is declared here only so it's in scope for that RUN.
ARG GIT_SHA

# Short hash of mix.lock, passed by the deploy script as
# --build-arg MIX_LOCK_SHA=$(sha256sum mix.lock | cut -c1-12). It is woven
# into the /app/deps and /app/_build cache-mount IDs below so that a lockfile
# change lands on FRESH mounts instead of reusing artifacts compiled against
# the previous lock. This exists because of the 2026-08-14 deploy failure:
# a warm /app/_build held a compiled plug_crypto 2.1.1 .app from the old lock
# while deps/ correctly held 2.2.0, and `mix compile`'s convergence check
# reads the dep version from the BUILD PATH — so it reported 2.1.1 against
# phoenix 1.8.11's `~> 2.2` and failed, twice, against a perfectly correct
# mix.lock. Keying the IDs makes that class of staleness unreachable rather
# than relying on Mix's own staleness detection, which is what missed it.
#
# NO DEFAULT VALUE, deliberately: an unset ARG would expand to "" and
# collapse every build onto one shared ID — the same bug wearing a fix's
# clothing. The guard below turns that into a loud failure instead. The
# deploy script carries the matching -n check on its side.
ARG MIX_LOCK_SHA
RUN test -n "$MIX_LOCK_SHA" || { \
      echo "ERROR: MIX_LOCK_SHA build-arg is required (got empty/unset)." >&2; \
      echo "       Pass --build-arg MIX_LOCK_SHA=\$(sha256sum mix.lock | cut -c1-12)." >&2; \
      exit 1; \
    }

# Install dependencies first (layer caching). Cache-mounted /app/deps,
# /app/_build, /root/.hex, /root/.cache/rebar3 persist across builds keyed
# by BuildKit's own cache store (not the Docker layer cache) — so even when
# an earlier layer invalidates (mix.lock or source changes), deps.get/compile
# hit a warm cache instead of a cold re-fetch + full rebuild. Cache-mounted
# paths are NOT committed into the image layer when a RUN exits, so nothing
# outside these RUNs may read from /app/deps or /app/_build directly.
#
# /app/deps and /app/_build are ID-keyed on MIX_LOCK_SHA (see above); every
# mount of the same target MUST carry the identical id or the RUNs below stop
# sharing one cache and silently rebuild from scratch. /root/.hex,
# /root/.cache/rebar3 and /root/.npm are deliberately NOT keyed: .hex holds
# version-addressed package tarballs that make a re-fetch fast and cannot
# carry a version mismatch, and .npm is keyed by assets/package-lock.json,
# not by mix.lock.
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/app/deps,id=orca-deps-${MIX_LOCK_SHA},sharing=locked \
    --mount=type=cache,target=/root/.hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,sharing=locked \
    mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/runtime.exs config/
RUN --mount=type=cache,target=/app/deps,id=orca-deps-${MIX_LOCK_SHA},sharing=locked \
    --mount=type=cache,target=/app/_build,id=orca-build-${MIX_LOCK_SHA},sharing=locked \
    --mount=type=cache,target=/root/.hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,sharing=locked \
    mix deps.compile

# Copy application source
COPY priv priv

# Written here (not up near ENV MIX_ENV) so GIT_SHA only invalidates cache
# from this point forward — deps.get/deps.compile above stay cache-hit
# across builds that change nothing but the commit. OrcaHub.BuildInfo
# declares this file as an @external_resource, so a changed GIT_SHA (and
# therefore a changed file) is exactly what makes Mix recompile it, even
# though the cache-mounted /app/_build below would otherwise let Mix skip
# recompiling a source file whose own text hasn't changed.
RUN echo "$GIT_SHA" > priv/git_sha

COPY lib lib

# === Hot code generation beams ===
# What `OrcaHub.Cluster.CodePush.collect_payload/1` publishes: the compiled
# :orca_hub ebin, produced by exactly the toolchain and deps that built the
# running releases, instead of by whatever Erlang/Elixir the publishing host
# has installed. Pulled out with
#   docker buildx build --builder orca --platform linux/amd64 \
#     --build-arg GIT_SHA=... --build-arg MIX_LOCK_SHA=... \
#     --target beams-export --output type=local,dest=<dir> .
# One platform is enough: beams are architecture-independent and :orca_hub
# has no NIFs (its NIF-carrying deps are never part of a payload).
#
# Branches off `source` BEFORE assets/rel, so it never runs npm or the asset
# pipeline — none of that feeds a beam. The cache mounts are the release
# RUN's, same ids, so it shares that warm deps/_build: on a checkout the last
# deploy already built this is a no-op compile, and the release build that
# follows it gets the same courtesy back.
#
# Like the release RUN, the ebin is copied OUT of the cache-mounted /app/_build
# inside the same RUN; cache-mount contents never reach a layer.
# toolchain.txt records the runtime that did the compiling — beams carry their
# compiler version but no ERTS stamp, so this is how the generation learns
# which ERTS it was built for. BEAMS_COMPILE_FLAGS is how CodePush asks for
# `--force` (it is empty otherwise, so the cache key is stable).
FROM source AS beams
ARG MIX_LOCK_SHA
ARG BEAMS_COMPILE_FLAGS=""
RUN --mount=type=cache,target=/app/deps,id=orca-deps-${MIX_LOCK_SHA},sharing=locked \
    --mount=type=cache,target=/app/_build,id=orca-build-${MIX_LOCK_SHA},sharing=locked \
    --mount=type=cache,target=/root/.hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,sharing=locked \
    mix compile $BEAMS_COMPILE_FLAGS && \
    rm -rf /app/beams && mkdir -p /app/beams && \
    cp -a /app/_build/prod/lib/orca_hub/ebin /app/beams/ebin && \
    elixir -e 'Application.load(:compiler); IO.puts("erts_version=#{:erlang.system_info(:version)}\notp_release=#{:erlang.system_info(:otp_release)}\nelixir_version=#{System.version()}\ncompiler_version=#{Application.spec(:compiler, :vsn)}")' \
      > /app/beams/toolchain.txt

FROM scratch AS beams-export
COPY --from=beams /app/beams /

# === Release build ===
# Both ARGs re-declared, in their original order: a build arg in scope is part
# of every later RUN's environment, and so of its cache key. Dropping GIT_SHA
# here would re-key `npm ci` and the release RUN below.
FROM source AS builder
ARG GIT_SHA
ARG MIX_LOCK_SHA
COPY assets assets
COPY rel rel

# assets/package.json deps (e.g. @xterm/xterm for the terminal hook) aren't
# fetched by `mix assets.setup` (that only installs the tailwind/esbuild
# standalone binaries) — esbuild needs them present in assets/node_modules
# to resolve the imports when bundling.
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm --prefix assets ci

# Compile first (generates phoenix-colocated hooks JS), then build assets,
# then release. `mix release`'s output lands inside the cache-mounted
# /app/_build, so it's `cp -a`'d out to /app/release (a normal,
# non-cache-mounted path) as the last command in the same RUN — that's what
# actually survives into the image layer for the COPY --from=builder
# instructions below (both the artifact stage and the runtime stage).
#
# --overwrite is required here: with /app/_build cache-mounted and
# persisting across builds, `mix release` finds an already-assembled
# release from a previous build and (with no tty to answer "Release ...
# already exists. Overwrite? [Yn]") gets EOF on stdin, which Mix treats as
# "no" — silently skipping the copy of freshly-compiled .beam files (e.g.
# OrcaHub.BuildInfo, recompiled because priv/git_sha changed) into the
# release dir. Without this flag every build after the first would keep
# assembling the SAME stale release forever, regardless of what actually
# got recompiled above.
RUN --mount=type=cache,target=/app/deps,id=orca-deps-${MIX_LOCK_SHA},sharing=locked \
    --mount=type=cache,target=/app/_build,id=orca-build-${MIX_LOCK_SHA},sharing=locked \
    --mount=type=cache,target=/root/.hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,sharing=locked \
    mix compile && \
    mix assets.deploy && \
    mix release --overwrite && \
    rm -rf /app/release && \
    cp -a /app/_build/prod/rel/orca_hub /app/release

# === Artifact export stage ===
# Exports just the release directory as build output (no runtime-stage OS
# packages), so deploy-orca-hub.sh can pull it out with `docker build
# --target artifact --output type=local,dest=<dir>` and reuse the SAME
# bookworm-glibc-built release for the local systemd instance and mini,
# instead of building a second, separate release on each host. Bookworm's
# glibc 2.36 is older than (forward-compatible with) both mini's Arch glibc
# 2.43 and the debian trixie host's glibc 2.41 — smoke-tested on all three.
FROM scratch AS artifact
COPY --from=builder /app/release /

# === Runtime stage ===
FROM debian:${DEBIAN_CODENAME}-slim

RUN apt-get update -y && \
    apt-get install -y \
      libstdc++6 openssl libncurses5 locales ca-certificates \
      curl bsdutils git && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Create app user (UID/GID 1000 to match host user for volume mounts)
RUN groupadd -g 1000 orca && useradd -u 1000 -g orca -m -d /home/orca orca

# Install Claude CLI (native binary, no Node.js needed)
ENV HOME=/home/orca
RUN curl -fsSL https://claude.ai/install.sh | su orca -c bash
ENV PATH="/home/orca/.local/bin:${PATH}"

# Install mise (mise.jdx.dev) for the orca user. Used to bake in a pinned
# Node LTS now, and to let tools be added on-demand in running pods later.
# The mise.run script just drops a static binary at ~/.local/bin/mise (no
# package manager / build deps needed), which is already on PATH above.
RUN curl -fsSL https://mise.run | su orca -c sh

# Shims (not `mise activate`) are what make mise-installed tools resolve in
# a plain non-interactive, non-login shell — which is what the OTP release
# process sees, since it never sources .bashrc/.profile.
ENV PATH="/home/orca/.local/share/mise/shims:${PATH}"

# Pin a Node LTS via mise, then bake in codex + pi on top of it so they're
# available by default on every pod (mise-managed tools installed at
# container runtime are ephemeral across pod restarts; baking into the
# image is the durable path).
RUN su orca -c "mise use -g node@22" && \
    su orca -c "npm install -g @openai/codex@latest @earendil-works/pi-coding-agent@latest" && \
    su orca -c "npm cache clean --force" && \
    su orca -c "mise reshim" && \
    rm -rf /home/orca/.local/share/mise/installs/node/*/include

# === Playwright (Chromium only) ===
#
# Sessions run as `orca` with no root and no apt. Playwright's bundled
# Chromium links against ~20 shared libraries that bookworm-slim doesn't
# ship, and the documented fix (`npx playwright install-deps`) is apt-get
# under the hood — so it can only happen HERE, at build time. Without this,
# every front-end session either gives up on browser verification or spends
# half an hour `apt-get download`ing .debs, `dpkg -x`ing them into /tmp and
# hand-rolling LD_LIBRARY_PATH (observed twice on dell-agent, 2026-09-22).
#
# The package list below is upstream's own, captured from
#   npx playwright@<ver> install-deps --dry-run chromium
# MINUS `xvfb` and the CJK/Thai font packs (fonts-unifont,
# fonts-ipafont-gothic, fonts-wqy-zenhei, fonts-tlwg-loma-otf,
# xfonts-scalable, fonts-freefont-ttf). Measured on bookworm-slim: upstream's
# full list adds 436MB, this one adds 63MB — the delta is almost entirely an
# X server we can't use (nothing here runs headed) and font coverage for
# scripts we don't render.
#
# fonts-dejavu-core is the one ADDITION to upstream's list, and it is not
# cosmetic: Debian's 60-latin.conf resolves sans-serif by preferring
# "Noto Sans", then "DejaVu Sans", then Verdana/Arial. With none of those
# installed, fontconfig falls back alphabetically and EVERY generic family —
# sans-serif, serif, system-ui, "Segoe UI" — lands on Liberation Mono, so
# screenshots of a normal UI come back in a monospace face. (Measured: this
# also afflicts upstream's own full list, which resolves sans-serif AND serif
# to WenQuanYi Zen Hei, a Chinese font, because its font packs are likewise
# all outside the prefer list.) 5MB buys a correct sans/serif/mono split,
# which is the difference between a screenshot you can trust for visual
# verification and one you can't.
#
# WHY IT WENT MISSING, since this is a trap worth not re-walking: nothing here
# asks for fonts implicitly, but `libcairo2`/`libpango-1.0-0` Depend on
# `fontconfig`/`libfontconfig1`, and `fontconfig-config` in turn Depends on
# the ALTERNATIVES group `fonts-dejavu-core | ttf-bitstream-vera |
# fonts-liberation | ...`. apt satisfies an OR-dependency with the first
# alternative UNLESS another one is already in the transaction — so naming
# `fonts-liberation` explicitly (as upstream's list does) is precisely what
# suppresses DejaVu. Install the libs alone and you get DejaVu free and
# correct; add fonts-liberation and you silently lose it. Hence both.
#
# Corollary for anyone debugging a browser that lays out NO text at all
# (empty innerText, keystrokes not landing): that symptom does not come from
# an apt-installed image, because fontconfig + a font arrive transitively and
# unavoidably via the pango/cairo chain above — verified by building the
# 16-library list alone and getting correct layout. It comes from the
# `apt-get download` + `dpkg -x` + LD_LIBRARY_PATH workaround, which resolves
# no dependencies and so ships neither fontconfig's config nor any font.
# Regenerate with the --dry-run command above when
# bumping PLAYWRIGHT_VERSION and re-apply that same filter; a NEW lib*
# package appearing upstream is the one thing this list can't learn on its
# own, and the symptom would be a "missing shared libraries" launch error.
#
# Kept as its own RUN, after the node/codex/pi layer, so it's purely
# additive: nothing above it re-builds, and bumping the version below
# re-does only this layer.
ARG PLAYWRIGHT_VERSION=1.63.0
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libasound2 libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 libcairo2 \
      libcups2 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0 libnspr4 libnss3 \
      libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 \
      libxfixes3 libxkbcommon0 libxrandr2 libfontconfig1 libfreetype6 \
      fonts-liberation fonts-noto-color-emoji fonts-dejavu-core && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

# Browsers live OUTSIDE $HOME, in a dir owned by orca. Two reasons for the
# ownership, both load-bearing:
#   1. the baked browsers are shared by every session instead of each one
#      re-downloading ~150MB into its own ~/.cache/ms-playwright;
#   2. Playwright pins an exact Chromium build per release, so a session
#      running `npx playwright@latest` AFTER upstream moves past the version
#      pinned above finds no matching build. Because this dir is writable by
#      orca, that degrades to a one-off `npx playwright install chromium`
#      that SUCCEEDS (the apt deps above are the part it couldn't fix
#      itself) rather than to the EACCES dead end a root-owned dir gives.
# `playwright install chromium` installs both the full browser and the
# headless shell (what `playwright screenshot` and headless:true actually
# launch). Dropping to `chromium-headless-shell` alone saves ~600MB if image
# size ever needs to come down; nobody here needs firefox or webkit.
# `playwright` is also installed globally so `npx playwright ...` resolves it
# from PATH — matching the baked browsers with no download at all — while an
# explicit `npx -y playwright@latest ...` still works via the fallback above.
RUN install -d -o orca -g orca /opt/ms-playwright && \
    su orca -c "npm install -g playwright@${PLAYWRIGHT_VERSION}" && \
    su orca -c "playwright install chromium" && \
    su orca -c "npm cache clean --force" && \
    su orca -c "mise reshim"

WORKDIR /app

ENV MIX_ENV=prod
ENV PHX_SERVER=true

COPY --from=builder --chown=orca:orca /app/release ./

# Entrypoint: run migrations then start the server
COPY --chown=orca:orca <<'EOF' /app/bin/entrypoint.sh
#!/bin/sh
set -e

# Auto-generate SECRET_KEY_BASE if not provided, persisting to a file
# so it stays stable across container restarts.
if [ -z "$SECRET_KEY_BASE" ]; then
  secret_file="/home/orca/.claude/secret_key_base"
  if [ ! -f "$secret_file" ]; then
    openssl rand -base64 48 > "$secret_file"
  fi
  export SECRET_KEY_BASE="$(cat "$secret_file")"
fi

# Only run migrations in hub mode (agents have no database)
if [ "${ORCA_MODE}" != "agent" ]; then
  /app/bin/migrate
fi
exec /app/bin/server
EOF
RUN chmod +x /app/bin/entrypoint.sh

# Pre-create git's global config dir, orca-owned, with a default global
# ignore file at git's default core.excludesFile location (no gitconfig
# change needed). k8s mounts ConfigMap/Secret files via subPath into
# /home/orca/.config/git; if the directory doesn't already exist in the
# image, the container runtime creates it root-owned on mount, and
# git-as-orca can't create its lock files or this ignore file there.
RUN mkdir -p /home/orca/.config/git && \
    printf '.agents/\n.orca_uploads/\n.worktrees/\n.pi_sessions/\n*.local.*\n' > /home/orca/.config/git/ignore && \
    chown -R orca:orca /home/orca/.config

USER orca

CMD ["/app/bin/entrypoint.sh"]
