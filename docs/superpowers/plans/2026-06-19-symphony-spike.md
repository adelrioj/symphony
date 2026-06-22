# Plan 0 — Symphony Verification Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify the three unproven assumptions Symphony rests on — per-stage agent command, parked-state semantics, and local Elixir operation — before committing to the Linear migration.

**Architecture:** Stand up Symphony locally against a throwaway Linear team and a sandbox git repo, run controlled experiments, and record a go / no-go / adjust decision. This is a *spike*: the deliverable is verified knowledge plus a findings doc, not production code. Throwaway artifacts are deleted at the end (except the findings doc).

**Tech Stack:** Symphony (OpenAI, Elixir), Linear API, codex CLI, Claude Code CLI (`claude -p`), git.

## Global Constraints

- All work is local on the developer's Mac (darwin). No cloud.
- Throwaway Linear team and sandbox repo only — never touch `trazadera-infra`, `modernaize`, `llm-broker`, or the real Jira/Linear data in this spike.
- Symphony source of truth for config keys/CLI is its own `SPEC.md` and `elixir/README.md` — consult them; do not invent config syntax.
- Linear access from Symphony is via a **Linear API key**, not the claude.ai connector.

---

### Task 1: Local Symphony build

**Files:**
- Create: `~/symphony-spike/` (clone target, outside the infra repos)

- [ ] **Step 1: Install Elixir**

Run: `brew install elixir && elixir --version`
Expected: prints an Elixir version (e.g. `Elixir 1.x`). If Homebrew lacks it, use `asdf`/`mise` per Symphony's README.

- [ ] **Step 2: Clone Symphony**

Run: `git clone https://github.com/openai/symphony ~/symphony-spike && ls ~/symphony-spike/elixir`
Expected: directory listing includes `mix.exs`, `README.md`.

- [ ] **Step 3: Read the spec and README before building**

Read: `~/symphony-spike/SPEC.md` and `~/symphony-spike/elixir/README.md`.
Record in scratch notes: the exact run command, the config file location/format, and the workflow file format (front matter + prompt). These drive every later task.

- [ ] **Step 4: Fetch deps and compile**

Run: `cd ~/symphony-spike/elixir && mix deps.get && mix compile`
Expected: compiles with no errors (warnings acceptable).

- [ ] **Step 5: Commit findings notes (in the infra repo, not the spike clone)**

```bash
git add docs/superpowers/plans/spike-findings.md
git commit -m "docs: start Symphony spike findings notes"
```

---

### Task 2: Throwaway Linear team + statuses + API key

**Interfaces:**
- Produces: a Linear API key (env `LINEAR_API_KEY`), a team `Symphony Sandbox`, and six workflow states matching the design.

- [ ] **Step 1: Create the sandbox team**

In Linear: create a team named `Symphony Sandbox`.

- [ ] **Step 2: Define the six workflow states**

Create/rename states so the team has: `Backlog`, `Ready for Spec Review`, `Spec Reviewed`, `Implemented`, `Human Review`, `Blocked / Needs Attention`, plus the built-in `Done`/`Cancelled`. (Linear groups states under Backlog/Unstarted/Started/Completed/Cancelled — place the active ones under Started.)

- [ ] **Step 3: Create an API key**

Linear → Settings → API → create a personal API key. Store it: `export LINEAR_API_KEY=lin_api_...` in a local untracked env file.

- [ ] **Step 4: Verify the key and states via API**

Run:
```bash
curl -s https://api.linear.app/graphql -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ teams(filter:{name:{eq:\"Symphony Sandbox\"}}){ nodes { id states { nodes { name type } } } } }"}'
```
Expected: JSON listing the six states with their `type` (e.g. `started`, `completed`). Record the state names verbatim — Symphony config must match exactly.

---

### Task 3: Sandbox repo

**Files:**
- Create: `~/symphony-sandbox-repo/` (a trivial git repo with a README and a dummy test)

- [ ] **Step 1: Create the repo**

```bash
mkdir ~/symphony-sandbox-repo && cd ~/symphony-sandbox-repo && git init
printf '# sandbox\n' > README.md && git add . && git commit -m "chore: init sandbox"
```

- [ ] **Step 2: Push to a throwaway GitHub repo**

Run: `gh repo create symphony-sandbox-repo --private --source=. --push` (using the `adelrio-trazadera` gh account — see design's PR gotcha).
Expected: repo created and pushed. Confirm with `gh repo view symphony-sandbox-repo`.

---

### Task 4: Minimal Symphony config + no-op workflow (prove the loop)

**Files:**
- Create: Symphony config + a workflow file (paths/format per Task 1 Step 3 notes)

**Interfaces:**
- Consumes: `LINEAR_API_KEY`, team `Symphony Sandbox`, state names from Task 2.

- [ ] **Step 1: Write minimal config**

Configure: tracker = Linear (with `LINEAR_API_KEY` + team), `tracker.active_states = ["Ready for Spec Review"]`, `tracker.terminal_states = ["Done","Cancelled"]`, `polling.interval_ms = 30000`, `workspace.root = ~/symphony-spike/workspaces`, repo = the sandbox repo. Use the exact keys from `SPEC.md`.

- [ ] **Step 2: Write a no-op workflow**

Workflow prompt: "Do nothing except set this issue's status to `Spec Reviewed`." (Goal: prove dispatch + status write, nothing else.)

- [ ] **Step 3: Create a test ticket**

Create a ticket in `Symphony Sandbox`, status `Ready for Spec Review`.

- [ ] **Step 4: Run Symphony and watch one cycle**

Run Symphony (command per Task 1 notes). Within ~30s, observe it dispatch the ticket.
Expected: the ticket moves `Ready for Spec Review` → `Spec Reviewed`; a per-issue workspace dir appears under `workspace.root`.
**Pass criterion (open item #3 — local operation):** Symphony runs on the Mac, polls, and writes Linear status.

- [ ] **Step 5: Record result in findings doc and commit**

```bash
git add docs/superpowers/plans/spike-findings.md
git commit -m "docs: spike — confirm Symphony local loop + status write"
```

---

### Task 5: Per-stage command launch — codex AND claude (CRITICAL, open item #1)

**Interfaces:**
- Consumes: working Symphony from Task 4.

- [ ] **Step 1: Configure two active states with different commands**

Set `tracker.active_states = ["Ready for Spec Review","Implemented"]`. In the workflow, branch on status: for `Ready for Spec Review` invoke a **codex** command (e.g. `codex exec "echo codex-ran > codex.txt"`); for `Implemented` invoke a **claude** command (`claude -p "create a file claude.txt containing claude-ran"`). Use whatever launch mechanism `SPEC.md` exposes (workspace lifecycle hook `before_run`/`after_run`, or the agent command field).

- [ ] **Step 2: Drive a ticket through both**

Create a ticket at `Ready for Spec Review`; let Symphony run it; manually set it to `Implemented`; let Symphony run it again.

- [ ] **Step 3: Verify both agents executed**

Run: `ls ~/symphony-spike/workspaces/<ticket-id>/` and check for `codex.txt` and `claude.txt`.
Expected: **both files exist with the right contents.**
**Pass criterion:** Symphony's launch accepts per-stage arbitrary commands. **If only codex works,** record the constraint and the fallback (reimplement `review-pr` as a codex prompt, or have codex shell out to `claude -p`). This result decides whether the design holds as-is.

- [ ] **Step 4: Record result in findings doc and commit**

```bash
git add docs/superpowers/plans/spike-findings.md
git commit -m "docs: spike — per-stage command launch result"
```

---

### Task 6: Parked-state semantics (open item #2)

- [ ] **Step 1: Move a ticket to a non-active state**

With `active_states` NOT including `Human Review`, set a ticket to `Human Review`.

- [ ] **Step 2: Observe for two full poll cycles (~70s)**

Watch Symphony logs.
Expected: Symphony does **not** dispatch/re-run the `Human Review` ticket, and does not clean its workspace (it is not terminal).
**Pass criterion:** parked states sit outside `active_states` and are left untouched. Repeat for `Blocked / Needs Attention`.

- [ ] **Step 3: Record result in findings doc and commit**

```bash
git add docs/superpowers/plans/spike-findings.md
git commit -m "docs: spike — parked-state semantics result"
```

---

### Task 7: Findings + go/no-go decision

**Files:**
- Modify: `docs/superpowers/plans/spike-findings.md`

- [ ] **Step 1: Write the decision section**

For each open item, record: result, evidence (file/log), and impact on Plans A/B. End with one of: **GO** (design holds), **ADJUST** (list specific changes to Plan B), or **NO-GO** (architecture needs rethink — return to brainstorming).

- [ ] **Step 2: Tear down throwaway artifacts**

Delete the `Symphony Sandbox` Linear team, the GitHub `symphony-sandbox-repo`, and `~/symphony-spike/workspaces`. Keep `~/symphony-spike` (the Symphony clone) for Plan B.

- [ ] **Step 3: Commit final findings**

```bash
git add docs/superpowers/plans/spike-findings.md
git commit -m "docs: spike findings + go/no-go decision"
```

---

## Self-Review

- **Spec coverage:** addresses all three "Open items" from the design (per-stage command, parked-state semantics, local Elixir). ✓
- **Placeholders:** Symphony config keys reference real spec terms (`active_states`, `terminal_states`, `polling.interval_ms`, `workspace.root`, lifecycle hooks); exact CLI/format is gathered in Task 1 Step 3 rather than invented. ✓
- **Type consistency:** state names defined once in Task 2 and reused verbatim downstream. ✓
