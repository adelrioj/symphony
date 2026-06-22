# Symphony-driven local autonomous PR pipeline — Design

**Date:** 2026-06-18
**Status:** Design (approved for planning)
**Author:** adelrio

## Problem

Today the developer drives a feature from idea to PR by manually invoking a chain
of skills locally, updating Jira status by hand at each step:

1. `superpowers:brainstorming` → design doc (interactive)
2. `spec-review-codex` → adversarial review, commit fixes to the doc
3. `plan-to-dex` → execute the plan until a PR is opened
4. `review-pr` → automated PR review
5. wait for human approval

Every transition is a manual command and a manual status update. The goal is to
remove the manual driving: a ticket should flow through the pipeline on its own,
with the developer only stepping in to brainstorm (start) and to review the final
PR (end).

## Goal & shape

A **state machine of tickets** with **specialized stage-workers**. Each worker
does exactly one job, then advances the ticket's status. The ticket status *is*
the queue and the program counter. Explicitly **not** one mega-agent running the
whole pipeline.

## Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| Runtime | **Self-hosted on a dedicated always-on host the developer controls** | codex CLI, Vault token, SSH certs, repo checkouts must be provisioned on this host (the reason cloud/routines were rejected — they can't reach them). Because the host is always-on, the pipeline advances continuously; the "laptop sleeps" limitation does not apply. **Prerequisite:** the host must have the full local toolchain provisioned (codex auth, Vault token, SSH certs, gh credentials, repo checkouts). |
| Orchestrator | **Symphony (self-hosted locally)** | OpenAI's open-source spec/impl is purpose-built to orchestrate codex from an issue-tracker control plane. Solves polling, per-issue persistent workspaces, concurrency, retry/backoff, crash recovery. The pipeline is codex-heavy and local — Symphony's design center. |
| Control plane | **Linear (migrate from Jira)** | Symphony's reference implementation targets Linear's API. Running it "for real" on Linear means zero tracker-adapter code to own/maintain. |
| Repo mapping | **One Linear team per repo** | `trazadera-infra`, `modernaize`, `llm-broker` each get a team and a Symphony workflow config pointing at that repo's checkout. Clean separation, scales. |
| Autonomy | **Fully auto from `Ready` to PR** | Once a ticket hits `Ready for Spec Review`, all stages run with no stops. The PR (Linear `Human Review` + GitHub review) is the only human gate. |
| Failure handling | **Stage failure → `Blocked / Needs Attention`** | A safety valve: a failing stage parks the ticket for human attention instead of silently advancing. |
| Recurring tasks | **Deferred** | Weekly docs/`CLAUDE.md` refresh is a different (single-shot) pipeline. Designed later. |

## Architecture

Symphony runs locally and polls Linear (~30s). For any ticket in an *active*
status it spawns one agent run that performs exactly one stage, advances the
status, and stops. The next poll tick sees the new status and runs the next
stage.

### State machine

```
 [you, manually]                    [Symphony, fully auto]                       [you]
Backlog ──▶ Ready for Spec Review ──▶ Spec Reviewed ──▶ Implemented ──▶ Human Review ──▶ Done
   │              │ (spec-review-codex)   │ (plan-to-dex)   │ (review-pr)      ▲           (terminal)
   │              │                       │                 │                  │
 brainstorm    ACTIVE                  ACTIVE            ACTIVE            handoff (parked)
 + design doc                                                                  │
 committed                          any stage fails ──────────────────▶  Blocked / Needs Attention
                                                                          (parked, you fix)
```

- **Active states** (Symphony dispatches): `Ready for Spec Review`, `Spec Reviewed`, `Implemented`
- **Parked / handoff** (Symphony ignores; not terminal): `Human Review`, `Blocked / Needs Attention`
- **Terminal** (Symphony cleans up the worktree): `Done`, `Cancelled`

These map to Symphony's `tracker.active_states` / `tracker.terminal_states`
config. The parked states must sit *outside* `active_states` so they are not
re-dispatched (see Open items).

### Entry & continuity

- **Entry:** developer brainstorms interactively, commits the design doc to a
  branch named `TICKET-ID-slug`, pushes, and sets the ticket to
  `Ready for Spec Review`. Hands-off from there until `Human Review`.
- **Continuity = the branch.** Symphony's per-issue worktree checks out
  `TICKET-ID-slug`. The design doc, plan, implementation commits, and PR all
  accrete on that one branch across stages. No stage has to locate the previous
  stage's output — it's present in the worktree.
- **Brainstorming stays outside the machine** by design: it is interactive
  (asks one question at a time) and cannot run unattended. The pipeline starts
  at a committed design doc.

## The per-stage workflow (the "brain")

Symphony's orchestrator is dumb (poll, dispatch, supervise, retry). All stage
logic lives in the **workflow prompt**, which branches on the ticket's current
status:

| Status on entry | Agent | Action | On success → | On failure → |
|---|---|---|---|---|
| `Ready for Spec Review` | **codex** | run `spec-review-codex` against the design doc on the branch; commit fixes | `Spec Reviewed` | `Blocked` + comment |
| `Spec Reviewed` | **codex** | run `plan-to-dex`: generate plan, implement, push, open PR | `Implemented` (PR linked) | `Blocked` + comment |
| `Implemented` | **claude** (`claude -p /review-pr`) | run `review-pr`; post findings as PR comments | clean → `Human Review`; blockers → `Blocked` | `Blocked` + comment |

**Conventions:**
- Worktree = Symphony per-issue dir, checked out to `TICKET-ID-slug` of the
  team's repo.
- All commits land on that branch; `plan-to-dex` opens the PR from it.
- Branch/commit naming follows `.claude/rules/GIT_RULES.md` (conventional
  commits, **no AI attribution footers**, branch `TICKET-ID-short-description`).

## Error handling, secrets, observability

- **Failure → `Blocked`.** Symphony's retry/backoff handles transient crashes
  (clean exit re-checks in ~1s; failures back off, capped ~5min). When a stage
  genuinely cannot proceed (codex errors, tests stay red, `review-pr` finds
  blockers), the workflow sets `Blocked` and posts the error/log as a Linear
  comment. Nothing auto-advances past a real failure.
- **Audit trail = Linear comments.** Each run posts a progress comment (stage
  started, result, PR link). Symphony's local logs are the deep-debug layer.
- **Secrets, all local:** Linear **API key** (direct API, *not* the claude.ai
  connector — connectors may be absent in headless runs), codex auth, Vault
  token, SSH certs, GitHub token.
- **PR-creation gotcha:** `gh pr create` fails under the default `adelrioj`
  account — it requires `adelrio-trazadera`. The `plan-to-dex` PR step must
  switch gh accounts before opening the PR (then switch back), or PRs fail.

## Rollout (phased)

1. **Linear setup** — teams per repo, the 6-status workflow, API key. Decide
   Jira→Linear migration strategy (clean cutover vs. parallel run for in-flight
   tickets). *This phase is its own self-contained sub-project / plan.*
2. **Symphony up, no-op workflow** — Elixir orchestrator polling one repo's
   team; prove the loop, worktree creation, and status reads/writes with a stage
   that only advances status.
3. **Stages one at a time** — implement + verify `spec-review-codex`, then
   `plan-to-dex`, then `review-pr`. Verify each on a throwaway ticket before
   chaining.
4. **First real ticket on a low-stakes repo** (`llm-broker` or a sandbox),
   full-auto to `Human Review`; then roll to all three repos.
5. *(Later)* recurring/scheduled tasks — deferred.

## Open items (verify during build, not design blockers)

1. **Per-stage agent command.** Confirm Symphony's coding-agent launch accepts
   an arbitrary per-stage command (codex *and* `claude -p`) vs. assuming a
   single fixed codex binary. **Highest-priority verification.** If hard-wired
   to codex, `review-pr` is reimplemented as a codex prompt or wrapped so codex
   shells out to `claude`.
2. **Parked/handoff semantics.** Confirm `Human Review` / `Blocked` sit outside
   `active_states` so they are not re-dispatched every poll tick.
3. **Running Elixir locally.** Deps, supervision, autostart-on-login (the
   orchestrator must be awake to work).

## Decomposition

Write as one design spec, but split into two implementation plans:
- **Plan A:** Jira→Linear migration + Linear workspace/status setup (Phase 1).
- **Plan B:** Symphony pipeline (Phases 2–4).
