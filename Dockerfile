# === Build stage ===
ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.2.3
ARG DEBIAN_CODENAME=bookworm

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_CODENAME}-20260223 AS builder

RUN apt-get update -y && \
    apt-get install -y build-essential git curl && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Install dependencies first (layer caching)
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/runtime.exs config/
RUN mix deps.compile

# Copy application source
COPY priv priv
COPY lib lib
COPY assets assets
COPY rel rel

# Compile first (generates phoenix-colocated hooks JS), then build assets
RUN mix compile
RUN mix assets.deploy
RUN mix release

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

# Create app user
RUN groupadd -r orca && useradd -r -g orca -m -d /home/orca orca

# Install Claude CLI (native binary, no Node.js needed)
ENV HOME=/home/orca
RUN curl -fsSL https://claude.ai/install.sh | su orca -c bash
ENV PATH="/home/orca/.local/bin:${PATH}"

WORKDIR /app

ENV MIX_ENV=prod
ENV PHX_SERVER=true

COPY --from=builder --chown=orca:orca /app/_build/prod/rel/orca_hub ./

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

/app/bin/migrate
exec /app/bin/server
EOF
RUN chmod +x /app/bin/entrypoint.sh

USER orca

CMD ["/app/bin/entrypoint.sh"]
