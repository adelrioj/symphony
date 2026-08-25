# syntax=docker/dockerfile:1
# Symphony runtime image: one container runs `bin/symphony <WORKFLOW.md>` for one repo plus one
# tracker scope.
# node base gives us the Codex CLI prerequisite; mise pins Erlang/Elixir from the repo's mise.toml.
FROM node:20-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git ripgrep unzip \
      build-essential autoconf m4 libncurses-dev libssl-dev \
  && rm -rf /var/lib/apt/lists/*

# Codex CLI — the default agent backend the workflow launches (`codex ... app-server`)
RUN npm install --global @openai/codex

# mise reads the repo's own mise.toml, so the container toolchain can't drift from local dev
RUN curl -fsSL https://mise.run | sh
ENV PATH="/root/.local/bin:/root/.local/share/mise/shims:${PATH}"
# headless Erlang build — skip GUI apps + docs so the (cached) OTP compile is much faster
ENV KERL_CONFIGURE_OPTIONS="--without-wx --without-debugger --without-observer --without-et --without-javac" \
    KERL_BUILD_DOCS="no"

WORKDIR /app/elixir

# Toolchain layer: cached until mise.toml changes (this is the slow, one-time OTP compile).
COPY elixir/mise.toml ./
RUN mise trust && mise install && mise reshim \
 && mix local.hex --force && mix local.rebar --force

# The Erlang VM takes its native name encoding from the locale, and node:20-bookworm-slim ships
# none: without this the VM comes up latin1 and warns that Elixir "may malfunction" — any
# non-ASCII byte in an issue title, branch name or path is mangled on the way to the filesystem.
# Placed below the OTP layer on purpose: setting it earlier would invalidate that slow build.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Dependency layer: cached until mix.exs / mix.lock change.
COPY elixir/mix.exs elixir/mix.lock ./
RUN mix deps.get

# App layer.
COPY elixir/ ./
RUN mix escript.build

# Workspaces (per-issue clones) and logs are runtime volumes, not baked into the image.
VOLUME ["/workspaces", "/app/elixir/log"]

# WORKFLOW.md is mounted per deployment; compose `command` passes its path + flags.
ENTRYPOINT ["./bin/symphony"]
