# Symphony Spike — Findings

**Status:** Source investigation complete (Plan 0, Task 1 + pre-answers for Tasks 5–6). Runtime tasks (Linear sandbox, live run) still pending and need the developer's accounts.

**Decision: ADJUST** — the architecture is sound, but the per-stage agent mechanism and the repo-scoping model differ from what the design assumed. Specific changes below.

## Q1 — Per-stage command launch — CRITICAL

**Finding:** Symphony has exactly **one** global agent command, `codex.command` (default `codex app-server`, `config/schema.ex:166`). It launches the *same* command for every issue regardless of status (`codex/app_server.ex:189-210`, via `bash -lc`). It does **not** support per-status commands. Per-status *behavior* is achieved by the single agent reading `{{ issue.state }}` injected into its prompt (`prompt_builder.ex:18-24`) and branching internally — the shipped `WORKFLOW.md` is itself a status router ("Step 0: Determine current ticket state and route").

**Impact on design:** Our "codex for spec-review/plan, `claude -p` for review-pr (as separate launched commands)" is **not** how Symphony works. There is one agent (codex), and the WORKFLOW.md prompt routes by status.

**Adjustment:**
- The launched agent is always **codex**.
- `spec-review-codex` and `plan-to-dex` are codex flows already — they run natively.
- For the **review-pr** stage (status `Implemented`), the codex agent's prompt instructs it to **shell out to `claude -p "/review-pr <url>"`** as a subprocess (codex can run shell commands; sandbox must allow it). codex orchestrates, claude does the review. (Alternative: do the PR review natively in codex and drop the Claude skill — developer decision.)

## Q2 — Parked/handoff state semantics

**Finding (confirms design):** A Linear status in **neither** `active_states` nor `terminal_states` is never fetched or dispatched (`linear/client.ex:14,119-120`; `orchestrator.ex:842-856`). If a *running* issue transitions into a neither-state, Symphony stops the agent but **preserves** the workspace (`orchestrator.ex:413-433`, `cleanup_workspace=false`). Terminal states stop + clean the workspace.

**Impact:** `Human Review` and `Blocked / Needs Attention` as neither-states behave exactly as designed (parked, untouched, work-in-progress preserved). ✓ No change. **Note:** Symphony's internal in-memory "blocked" concept is separate from a Linear "Blocked" status — don't conflate.

## Q3 — Local operation, config, scoping

**Finding:**
- **Config lives in `WORKFLOW.md`**: YAML front matter (the full config schema) + a Markdown body that is the codex prompt (Solid/Liquid template). Not a separate config dir.
- **Run:** build an escript (`mix build` → `./bin/symphony`), then `./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md`. Optional `--port` enables a LiveView dashboard + JSON API.
- **Scoping is by Linear `tracker.project_slug`, NOT team.** There is **no `team` config key**. One `symphony` process runs **one** WORKFLOW.md = **one** project_slug.
- **Deps:** Elixir ~>1.19 / OTP (via `mise`), the **codex CLI on PATH** (`~/.codex/auth.json` for auth), `bash`, `LINEAR_API_KEY` env var.
- **`approval_policy`** defaults to *reject* approvals — for unattended operation it must be set to auto-approve (`never`), with an appropriate `thread_sandbox` (`read-only` | `workspace-write` | `danger-full-access`).
- **`agent.max_concurrent_agents_by_state`** allows per-state concurrency caps (e.g. cap the PR-creating state to 1).

**Impact on design — two corrections:**
1. **"One team per repo" → "one Linear *project* per repo (one project_slug), one Symphony process per repo."** Workflow *states* are defined at the Linear *team* level (one team can hold all repos' projects, or a team per repo — either works as long as the six states exist). Symphony filters work by project_slug.
2. **Multi-repo = multiple Symphony processes** (one per repo/WORKFLOW.md), each with its own concurrency cap, all on the dedicated host. (Earlier statement that a single instance polls all repos was wrong — corrected.)
3. The repo enters each per-issue workspace via the `hooks.after_create` shell hook (e.g. `git clone`/`git worktree`); branch checkout via `hooks.before_run`.

## Concurrency / gh-race note

Beyond scoping the gh token to the command (`GH_TOKEN=… gh pr create`), the PR-creating stage can be additionally serialized with `agent.max_concurrent_agents_by_state: {"spec reviewed": 1}` (plan-to-dex runs while status is `Spec Reviewed`).

## Remaining (need developer accounts / dedicated host)

- Create a sandbox Linear project + API key; write a real `WORKFLOW.md`; run the escript and confirm the loop, status routing, and the codex→claude shell-out end to end.
- Verify codex's sandbox permits the `claude -p` subprocess and `gh`/`git` network calls.
