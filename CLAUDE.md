# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

This repo is two things:

- **`SPEC.md`** (repo root) — the language-agnostic specification of Symphony. It is the source of truth.
- **`elixir/`** — the reference implementation (Elixir/OTP). It may be a *superset* of the spec but must never *conflict* with it. When an implementation change meaningfully alters intended behavior, update `SPEC.md` in the same change.

Symphony orchestrates autonomous coding work: it polls an issue tracker, creates an isolated workspace per issue, and runs a coding-agent backend inside that workspace until the issue reaches a terminal state. Both boundaries are pluggable behaviours — `Tracker` (6 adapters) and `Agent` (`codex`, `claude`).

**Nearly all development happens in `elixir/`.** Read `elixir/AGENTS.md` first — it carries the authoritative implementation rules (the most important ones are summarized below).

## Where the detail lives

Read these on demand; each covers one area and is not needed unless you're in it.

- Supervision tree, component roles, `.codex/skills`: see `.claude/docs/architecture.md`
- `WORKFLOW.md` front matter & config internals: see `.claude/docs/configuration.md`
- Docker, client deploys, tracker credentials, release builds: see `.claude/docs/deployment.md`
- Live external e2e tests and the coverage gate: see `.claude/docs/testing-e2e.md`
- Logging conventions: see `elixir/docs/logging.md`; token/usage reporting: `elixir/docs/token_accounting.md`

## Commands

Run all `mix` commands from the `elixir/` directory. Toolchain (Elixir 1.19.x / OTP 28) is pinned via `mise` (`mise.toml`); prefix with `mise exec --` if not using a mise-activated shell.

```bash
mix setup                 # install deps (alias for deps.get)
mix build                 # escript.build -> bin/symphony
mix test                  # full suite
mix test path/to/file_test.exs            # single file
mix test path/to/file_test.exs:42         # single test by line number
mix test --cover          # coverage (threshold is 100% — see mix.exs)
mix lint                  # specs.check + credo --strict
mix format                # apply formatting (line_length: 200)
mix specs.check           # enforce @spec on public functions (see rule below)
```

The `make` targets wrap these; the `Makefile` also lives in `elixir/`. The full quality gate before handoff:

```bash
make all        # == make ci: setup, build, fmt-check, lint, coverage, dialyzer
```

CI runs `make all` (`.github/workflows/make-all.yml`). PR descriptions are linted against `.github/pull_request_template.md` (`pr-description-lint.yml`); validate locally with `mix pr_body.check --file <path>`.

## Running the service

```bash
./bin/symphony ./WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails          # defaults to ./WORKFLOW.md if no path given
./bin/symphony ./WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4000   # also start the Phoenix dashboard + JSON API
```

`--logs-root` overrides the log directory (default `./log`). Tracker credentials, the `--linear-mcp` mode, and Docker deployment are in `.claude/docs/deployment.md`.

## Non-negotiables

- Workspaces must stay under the configured workspace root, and a turn's cwd must never be the source repo. Path checks live in `path_safety.ex`.
- Add tracker capabilities through the `Tracker` behaviour and agent backends through the `Agent` behaviour — never by branching in `AgentRunner` or calling an adapter directly.
- Always add config access through `SymphonyElixir.Config`, never ad-hoc env reads.
- Orchestrator state is concurrency-sensitive — preserve retry, reconciliation, and cleanup semantics when editing.

## Key implementation rules (from `elixir/AGENTS.md`)

- Every public function (`def`) in `lib/` needs an adjacent `@spec`. `defp` and `@impl` callbacks are exempt. Enforced by `mix specs.check`.
- Keep changes narrowly scoped; avoid unrelated refactors. Match existing patterns in `lib/symphony_elixir/*`.
- Follow `docs/logging.md` (under `elixir/`): include `issue_id` + `issue_identifier` for issue events and `session_id` for agent lifecycle events.
- Coverage threshold is 100% (`mix.exs` lists explicitly ignored modules — prefer adding tests over expanding that list).
- When behavior/config changes, update docs in the same PR: root `README.md` (concept), `elixir/README.md` (run instructions), `elixir/WORKFLOW.md` (workflow/config contract).
