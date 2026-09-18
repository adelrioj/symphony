# syntax=docker/dockerfile:1
# Symphony runtime image: one container runs `mix symphony serve` for one installation with
# multiple lanes. The built bin/symphony escript remains the agent-side --linear-mcp server.
# node base gives us the Codex CLI prerequisite; mise pins Erlang/Elixir from the repo's mise.toml.
# Global scope on purpose: an ARG referenced by a FROM must be declared before the first FROM.
# Pinned by digest, not tag — `helper_sha256` pins the helper's exact bytes, so a moving tag would
# reintroduce the same class of failure this stage exists to prevent. Override with
# --build-arg HELPER_IMAGE=... when the helper is rebuilt, and repin helper_sha256 to match.
ARG HELPER_IMAGE=ghcr.io/trazadera/agent-sandbox-symphony-helper@sha256:52e055ca90ddbb576ede5245ba73caaaa2c113cd3280ebb4d2ada00b98b3e0a7

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
FROM ${HELPER_IMAGE} AS helper

FROM runtime AS candidate

# Candidate.validate/2 does System.find_executable("symphony-kubernetes-create") and compares the
# file's sha256 to pins.helper_sha256. Without it validation fails on a missing executable, which
# reads like a pin mismatch rather than a missing file.
COPY --from=helper /symphony-kubernetes-create /usr/local/bin/symphony-kubernetes-create

# Kubernetes.Client shells out to `kubectl` for every non-POST call (only POST goes through
# symphony-kubernetes-create), so without it candidate_preflight fails as
# {:unknown, :kubernetes_command_failed} — indistinguishable from a bad kubeconfig.
# Pinned to the cluster's server version; checksum verified against the official published one.
ARG KUBECTL_VERSION=v1.33.13
ARG TARGETARCH=amd64
RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256" \
      | awk '{print $1"  /usr/local/bin/kubectl"}' | sha256sum -c - \
 && chmod 0755 /usr/local/bin/kubectl \
 && kubectl version --client >/dev/null

# ssh drives the managed connection into the guest (ssh.ex, kubernetes.ex) and ssh-keygen mints
# the per-sandbox client key in rotate_credentials/6. gcloud is Workstations-only and gh is only
# used by a Mix task, so neither is installed here.
RUN apt-get update && apt-get install -y --no-install-recommends openssh-client \
 && rm -rf /var/lib/apt/lists/*

# Every external binary this code resolves with System.find_executable/1 must exist, or the
# failure surfaces far from its cause: a missing kubectl reads as {:unknown,
# :kubernetes_command_failed}, which looks exactly like a bad kubeconfig. Assert the surface at
# build time instead of discovering it one qualification run at a time.
RUN set -e; for b in bash kill kubectl ssh ssh-keygen symphony symphony-kubernetes-create; do \
      command -v "$b" >/dev/null || { echo "required executable missing from candidate image: $b" >&2; exit 1; }; \
    done
RUN symphony-kubernetes-create --help >/dev/null 2>&1 || true; \
    test -x "$(command -v symphony-kubernetes-create)" \
 || { echo "symphony-kubernetes-create is not executable on PATH" >&2; exit 1; }

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

# artifact_identity/0 hashes compiled BEAM object code, which is not reproducible: two builds
# of the same commit produce different sha256 values (verified — stable within an image, not
# across builds). So `consumer_artifact_sha256` must be READ OUT OF THE IMAGE you are about to
# run, never precomputed from a commit or copied from a previous run's pins:
#
#   docker run --rm -w /app/elixir -e MIX_ENV=test <image> mix run \
#     -e 'IO.puts(SymphonyElixir.ExecutionEnvironment.Kubernetes.Candidate.artifact_identity().sha256)'
#
# Getting this wrong is what made the 2026-09-18 run fail its second integrity check.

COPY docker/candidate-launch.exs ./launch.exs

# `runtime` sets ENTRYPOINT ["mix", "symphony"], which would otherwise prefix everything below
# and turn the command into `mix symphony mix run launch.exs`. Clear it.
ENTRYPOINT []
# Operators drive this through `kubectl exec` against a pod whose command is `sleep infinity`,
# so this default only documents the intended invocation.
CMD ["mix", "run", "launch.exs"]
