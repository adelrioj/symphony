# syntax=docker/dockerfile:1
# Symphony runtime image: one container runs `mix symphony serve` for one installation with
# multiple lanes. The built bin/symphony escript remains the agent-side --linear-mcp server.
# node base gives us the Codex CLI prerequisite; mise pins Erlang/Elixir from the repo's mise.toml.
FROM node:20-bookworm-slim AS runtime

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
# escript.build also compiles the project and dependencies on disk. Keep _build here so the
# Mix daemon can load SQLite's NIF; a second mix compile adds no packaging effect.
RUN mix escript.build

ENV PATH="/app/elixir/bin:${PATH}"

# Per-issue clones and durable database/log data are runtime volumes, not image contents.
VOLUME ["/workspaces", "/data"]

# Compose passes serve + installation flags; /config is only an import/export source.
ENTRYPOINT ["mix", "symphony"]


# --- candidate ----------------------------------------------------------------------------
# The Kubernetes qualification runner. It is deliberately NOT the production image: it needs a
# MIX_ENV=test build, because SymphonyElixir…Kubernetes.Candidate is wrapped in
# `if Mix.env() == :test`, and it needs .git, because the runner compares `git rev-parse HEAD`
# against pins.consumer_source_commit before it will run.
#
# Build it explicitly:  docker build --target candidate -f docker/Dockerfile .
# `runtime` stays the default target for docker-publish.yml.
#
# Why this stage exists: the image used through 2026-09-18,
# ghcr.io/trazadera/symphony-runtime-controller:candidate-test-e6c1f61155de, was hand-built and
# hand-tagged, and baked a pre-model runner (405 lines against the repo's 741) under a tag that
# named a current commit. Every pin in the candidate contract is content-addressed against files
# in this image, so an image whose tag does not describe its contents makes all of them vacuous.
FROM runtime AS candidate

# .git belongs at /app, one level above WORKDIR: the runner resolves HEAD from /app/elixir and
# git walks up. Only elixir/ was copied into `runtime`, so scope the cleanliness check to it —
# every other tracked path would otherwise read as deleted.
COPY .git /app/.git
RUN git config --global --add safe.directory /app \
 && test -n "$(git -C /app rev-parse HEAD)" \
 && if [ -n "$(git -C /app status --porcelain -- elixir)" ]; then \
      echo "refusing to bake a dirty elixir/ worktree: the baked source would not match the baked HEAD," >&2; \
      echo "and consumer_source_commit would pin a commit this image does not actually contain." >&2; \
      git -C /app status --porcelain -- elixir >&2; \
      exit 1; \
    fi

ENV MIX_ENV=test
RUN mix deps.get && mix compile

COPY docker/candidate-launch.exs ./launch.exs

# Operators drive this through `kubectl exec` against a pod whose command is `sleep infinity`,
# so this default only documents the intended invocation.
CMD ["mix", "run", "launch.exs"]
