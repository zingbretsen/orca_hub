# syntax=docker/dockerfile:1

# === Build stage ===
ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.2.3
ARG DEBIAN_CODENAME=bookworm

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_CODENAME}-20260223 AS builder

RUN apt-get update -y && \
    apt-get install -y build-essential git curl nodejs npm && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# No .git dir reaches the build context (only lib/priv/assets/rel are
# COPYed below), so OrcaHub.BuildInfo can't shell out to `git rev-parse`
# the way a host `mix release` build can. The deploy script passes this as
# --build-arg GIT_SHA=$(git rev-parse --short HEAD); exporting it as an ENV
# here (before `mix compile`) lets BuildInfo read it at compile time.
ARG GIT_SHA
ENV GIT_SHA=${GIT_SHA}

# Install dependencies first (layer caching). Cache-mounted /app/deps,
# /app/_build, /root/.hex, /root/.cache/rebar3 persist across builds keyed
# by BuildKit's own cache store (not the Docker layer cache) — so even when
# an earlier layer invalidates (mix.lock or source changes), deps.get/compile
# hit a warm cache instead of a cold re-fetch + full rebuild. Cache-mounted
# paths are NOT committed into the image layer when a RUN exits, so nothing
# outside these RUNs may read from /app/deps or /app/_build directly.
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/app/deps,sharing=locked \
    --mount=type=cache,target=/root/.hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,sharing=locked \
    mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/runtime.exs config/
RUN --mount=type=cache,target=/app/deps,sharing=locked \
    --mount=type=cache,target=/app/_build,sharing=locked \
    --mount=type=cache,target=/root/.hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,sharing=locked \
    mix deps.compile

# Copy application source
COPY priv priv
COPY lib lib
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
RUN --mount=type=cache,target=/app/deps,sharing=locked \
    --mount=type=cache,target=/app/_build,sharing=locked \
    --mount=type=cache,target=/root/.hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,sharing=locked \
    mix compile && \
    mix assets.deploy && \
    mix release && \
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

USER orca

CMD ["/app/bin/entrypoint.sh"]
