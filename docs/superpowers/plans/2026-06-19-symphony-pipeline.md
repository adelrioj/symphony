# Plan B — Symphony Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Symphony locally as the autonomous pipeline that drives a Linear ticket from `Ready for Spec Review` to a PR at `Human Review`, one stage per poll tick.

**Architecture:** Symphony (Elixir) polls each per-repo Linear team. For a ticket in an active state it spawns one run; a single status-branching **workflow prompt** decides the stage, invokes the right agent (codex or `claude -p`), commits on the ticket's branch, and advances or parks the status. The ticket's branch (checked out in a persistent per-issue worktree) carries state between stages.

**Tech Stack:** Symphony (OpenAI, Elixir), Linear API, codex CLI, Claude Code CLI (`claude -p`), gh CLI, git.

> **Dependencies:** Execute after **Plan 0 (spike) = GO/ADJUST** and **Plan A (Linear migration)** complete. If the spike returned ADJUST, apply its recorded changes to Tasks 3–6 first. The per-stage launch mechanism used below assumes the spike confirmed Symphony can run arbitrary per-stage commands (codex *and* `claude -p`); if it confirmed codex-only, replace the `claude -p /review-pr` step in Task 6 with the spike's recorded fallback.

## Global Constraints

- Active states: `Ready for Spec Review`, `Spec Reviewed`, `Implemented`. Parked: `Human Review`, `Blocked / Needs Attention`. Terminal: `Done`, `Cancelled`.
- Branch convention: `TICKET-ID-short-description`; all stage commits land on it; PR opened from it.
- Commits/PRs follow `.claude/rules/GIT_RULES.md`: conventional commits, **no AI attribution footers**, PR uses `.github/pull_request_template.md`.
- **gh account:** `gh pr create` must run as `adelrio-trazadera`, not the default `adelrioj`. Use a **command-scoped credential** (`GH_TOKEN=<trazadera-token> gh pr create …`), NOT a global `gh auth switch` — a global switch mutates shared state and races when two stages create PRs concurrently.
- Secrets local only: `LINEAR_API_KEY`, codex auth, Vault token, SSH certs, GitHub token. Never committed.
- Symphony source of truth for config/CLI: `~/symphony-spike/SPEC.md` + `elixir/README.md`.

---

### Task 1: Production Symphony install + autostart

**Files:**
- Create: `~/symphony/` (production clone, separate from the spike), `~/Library/LaunchAgents/com.trazadera.symphony.plist`

- [ ] **Step 1: Clone + build a clean production copy**

```bash
git clone https://github.com/openai/symphony ~/symphony
cd ~/symphony/elixir && mix deps.get && mix compile
```
Expected: compiles cleanly.

- [ ] **Step 2: Create a launchd agent (autostart on login)**

Create `com.trazadera.symphony.plist` that runs the Symphony start command (from `elixir/README.md`) with the prod config path, `KeepAlive=true`, and `RunAtLoad=true`, sourcing the local env file for secrets.

- [ ] **Step 3: Load and verify it stays up**

Run: `launchctl load ~/Library/LaunchAgents/com.trazadera.symphony.plist && launchctl list | grep symphony`
Expected: the job is listed with a PID (running). Confirm it restarts after `kill <pid>` (KeepAlive).

- [ ] **Step 4: Commit the plist (template, secrets externalized)**

```bash
git add deploy/symphony/com.trazadera.symphony.plist
git commit -m "feat: add Symphony launchd autostart agent"
```

---

### Task 2: Per-team config pointing at each repo

**Files:**
- Create: `~/symphony/config/` with one workflow/config entry per team (format per SPEC.md)

**Interfaces:**
- Consumes: team IDs + state IDs from Plan A (`linear-ids.md`); local repo checkout paths.
- Produces: three configured pipelines (`trazadera-infra`, `modernaize`, `llm-broker`).

- [ ] **Step 1: Write shared tracker config**

Set: tracker = Linear with `LINEAR_API_KEY`; `tracker.active_states = ["Ready for Spec Review","Spec Reviewed","Implemented"]`; `tracker.terminal_states = ["Done","Cancelled"]`; `polling.interval_ms = 30000`; `agent.max_concurrent_agents = 2` (solo scale — small on purpose); `workspace.root = ~/symphony/workspaces`.

- [ ] **Step 2: One workflow per team**

For each team, set its repo path (`~/development/trazadera/<repo>`) and the shared workflow prompt (Task 3). Confirm `Human Review` and `Blocked / Needs Attention` are NOT in `active_states` (parked).

- [ ] **Step 3: Verify Symphony loads all three**

Restart Symphony; check logs.
Expected: logs show three teams polling, no config errors. A ticket created in `Backlog` is ignored (not active).

- [ ] **Step 4: Commit config templates**

```bash
git add deploy/symphony/config/
git commit -m "feat: add per-repo Symphony pipeline config"
```

---

### Task 3: The status-branching workflow prompt (the brain)

**Files:**
- Create: `deploy/symphony/workflow.md` (the prompt Symphony injects per run)

**Interfaces:**
- Produces: a prompt that, given the issue's current status, performs exactly one stage and sets exactly one next status. Stage logic filled in by Tasks 4–6.

- [ ] **Step 1: Write the skeleton prompt**

Prompt contents: read the issue's current status; the worktree is already checked out to branch `TICKET-ID-slug`; dispatch on status:
- `Ready for Spec Review` → run Task 4's stage
- `Spec Reviewed` → run Task 5's stage
- `Implemented` → run Task 6's stage
On any unrecoverable error in a stage: set status `Blocked / Needs Attention`, post a Linear comment with the error, and stop. On success: set the stage's next status. Always post a start/result comment to the Linear issue.

- [ ] **Step 2: Verify branch checkout convention**

With a sandbox ticket whose branch exists, confirm Symphony's per-issue worktree is on `TICKET-ID-slug` (use the `before_run` workspace hook to `git checkout` the branch if Symphony defaults to the repo's default branch).
Expected: `git -C <workspace> branch --show-current` prints `TICKET-ID-slug`.

- [ ] **Step 3: Commit**

```bash
git add deploy/symphony/workflow.md
git commit -m "feat: add Symphony status-branching workflow prompt"
```

---

### Task 4: Stage — spec-review-codex (`Ready for Spec Review` → `Spec Reviewed`)

- [ ] **Step 1: Add the stage to the workflow prompt**

For `Ready for Spec Review`: invoke **codex** to run the `spec-review-codex` flow against the design doc on the branch (`docs/superpowers/specs/*-design.md`); commit fixes with a conventional message; on success set `Spec Reviewed`.

- [ ] **Step 2: Test on a sandbox ticket**

Create a ticket with a deliberately flawed design doc on its branch; set `Ready for Spec Review`.
Expected: within a poll cycle, codex review runs, fixes are committed to the branch, status → `Spec Reviewed`, and a Linear comment summarizes the review.

- [ ] **Step 3: Test the failure path**

Force a failure (e.g. revoke codex auth temporarily).
Expected: status → `Blocked / Needs Attention`, Linear comment carries the error, no advance.

- [ ] **Step 4: Commit**

```bash
git add deploy/symphony/workflow.md
git commit -m "feat: add spec-review-codex pipeline stage"
```

---

### Task 5: Stage — plan-to-dex with PR (`Spec Reviewed` → `Implemented`)

- [ ] **Step 1: Add the stage**

For `Spec Reviewed`: invoke **codex** to run `plan-to-dex` (generate plan, implement on the branch, run the project's tests/build). Then create the PR.

- [ ] **Step 2: Create the PR with a command-scoped credential (concurrency-safe)**

Create the PR from `TICKET-ID-slug` using `.github/pull_request_template.md`, passing the trazadera token only to that command: `GH_TOKEN=<trazadera-token> gh pr create --base main --head TICKET-ID-slug --body-file <(...) ...`. Do **not** use `gh auth switch` — it mutates global gh state and races when two `plan-to-dex` stages create PRs at the same time (`max_concurrent_agents ≥ 2`). Source the token from the host's local env / Vault, never inline in the workflow file. Capture the PR URL, post it as a Linear comment, set `Implemented`.

- [ ] **Step 3: Test on a sandbox ticket**

Drive a `Spec Reviewed` ticket through.
Expected: code committed on branch, tests run, PR opened under `adelrio-trazadera`, PR URL in a Linear comment, status → `Implemented`.

- [ ] **Step 4: Test the failure path**

Use a spec whose implementation makes tests fail.
Expected: status → `Blocked / Needs Attention` with the failing test output in a Linear comment; no PR or a draft PR clearly marked blocked (pick one behavior and encode it explicitly in the prompt).

- [ ] **Step 5: Commit**

```bash
git add deploy/symphony/workflow.md
git commit -m "feat: add plan-to-dex pipeline stage with PR creation"
```

---

### Task 6: Stage — review-pr (`Implemented` → `Human Review` / `Blocked`)

> Uses `claude -p /review-pr`. If the spike found Symphony codex-only, substitute the recorded fallback here.
>
> Superseded by the per-stage agent backend work: `review-pr` should now run by setting
> `agent.backend_by_state: {implemented: claude}` so Symphony launches the Claude backend directly,
> rather than having Codex shell out to `claude -p`.

- [ ] **Step 1: Add the stage**

For `Implemented`: invoke **`claude -p "/review-pr <PR-URL>"`** in the worktree; post findings as PR comments. If review finds **blockers**: set `Blocked / Needs Attention` + Linear comment. If **clean**: set `Human Review` + Linear comment.

- [ ] **Step 2: Test the clean path**

Drive a clean `Implemented` ticket through.
Expected: review-pr posts comments on the GitHub PR, status → `Human Review`, Linear comment links the review. Symphony then leaves the ticket alone (parked — verified in spike Task 6).

- [ ] **Step 3: Test the blocker path**

Use a PR with an obvious defect.
Expected: status → `Blocked / Needs Attention`, blockers summarized in a Linear comment.

- [ ] **Step 4: Commit**

```bash
git add deploy/symphony/workflow.md
git commit -m "feat: add review-pr pipeline stage with handoff to Human Review"
```

---

### Task 7: End-to-end on a low-stakes real repo

- [ ] **Step 1: Pick the target**

Use `llm-broker` (lowest blast radius). Hand-write a small real design doc via `brainstorming`, commit to `LLM-<n>-slug`, create the Linear ticket, set `Ready for Spec Review`.

- [ ] **Step 2: Watch the full pipeline unattended**

Expected sequence (each within a poll cycle): `Ready for Spec Review` → (codex review) → `Spec Reviewed` → (plan-to-dex + PR) → `Implemented` → (review-pr) → `Human Review`, with a Linear comment at each transition and a PR open under `adelrio-trazadera`.

- [ ] **Step 3: Review and merge the PR by hand**

Confirm the human gate works: you review the real PR, approve, merge; manually set the ticket to `Done`.
Expected: Symphony cleans the per-issue worktree on terminal transition (verified in spike Task 4/6).

- [ ] **Step 4: Record the run + commit notes**

```bash
git add docs/superpowers/plans/symphony-e2e-notes.md
git commit -m "docs: record first end-to-end Symphony pipeline run"
```

- [ ] **Step 5: Roll out to the other two repos**

Repeat Step 1–2 once on `modernaize` and once on `trazadera-infra` (note: infra tickets need Vault/SSH — confirm the worktree has those available). Only then consider the pipeline live.

---

## Self-Review

- **Spec coverage:** local Symphony (Task 1), team-per-repo config (Task 2), one-stage-per-tick brain (Task 3), all three stages with success+failure paths (Tasks 4–6), gh-account PR gotcha (Task 5), Linear-comment audit trail (every stage), Human Review/Blocked parking (Tasks 3,6), end-to-end + rollout (Task 7). ✓
- **Placeholders:** none — config keys are real Symphony terms; exact CLI/format deferred to SPEC.md by reference, not invented; every stage has concrete success and failure verification. ✓
- **Type consistency:** status names, active/parked/terminal classification, and branch convention identical across Tasks 1–7 and to the design + Plan A. ✓
- **Assumption honesty:** per-stage `claude -p` launch (Task 6) explicitly gated on the spike result with a named fallback. ✓
