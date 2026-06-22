# Plan A — Linear Migration & Workspace Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move ticket tracking from Jira to Linear and stand up the per-repo team structure and six-status workflow that the Symphony pipeline (Plan B) drives.

**Architecture:** One Linear team per repo (`trazadera-infra`, `modernaize`, `llm-broker`), each with the same six-status workflow. In-flight Jira issues are migrated; closed history stays in Jira (read-only). Most steps are ops/config — the "test" for each is a Linear API query confirming the resulting state.

**Tech Stack:** Linear (API + UI), Jira (export source), curl/GraphQL.

> **Dependency:** Execute only after **Plan 0 (Symphony spike)** returns **GO** or **ADJUST**. If ADJUST changed the status model, update the state lists below to match before starting.

## Global Constraints

- Six workflow states per team, names **verbatim**: `Ready for Spec Review`, `Spec Reviewed`, `Implemented`, `Human Review`, `Blocked / Needs Attention`, plus built-in `Backlog`/`Done`/`Cancelled`.
- Active states (Symphony-eligible): `Ready for Spec Review`, `Spec Reviewed`, `Implemented`. Parked: `Human Review`, `Blocked / Needs Attention`. Terminal: `Done`, `Cancelled`.
- Branch naming carried over from `.claude/rules/GIT_RULES.md`: `TICKET-ID-short-description`. Linear ticket IDs (e.g. `INF-123`) replace Jira keys in branch names going forward.
- Linear API key stored only in a local untracked env file; never committed.

---

### Task 1: Create the three teams with identical workflows

**Interfaces:**
- Produces: three Linear teams (`trazadera-infra`, `modernaize`, `llm-broker`), each with the six states; team IDs recorded for Plan B config.

- [ ] **Step 1: Create teams**

In Linear, create teams `Trazadera Infra`, `Modernaize`, `LLM Broker` (keys e.g. `INF`, `MDZ`, `LLM`).

- [ ] **Step 2: Define states on each team**

For each team, create the active/parked states under the correct Linear groups: `Ready for Spec Review`, `Spec Reviewed`, `Implemented` under **Started**; `Human Review` under **Started** (parked, but not Completed); `Blocked / Needs Attention` under **Started**. Keep built-in `Backlog`, `Done` (Completed), `Cancelled`.

- [ ] **Step 3: Verify all three teams match**

Run (per team name):
```bash
curl -s https://api.linear.app/graphql -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ teams { nodes { key name states { nodes { name type } } } } }"}'
```
Expected: each of the three teams lists the same six custom state names. Record each team's `id` and each state's `id`.

- [ ] **Step 4: Commit the recorded IDs**

```bash
git add docs/superpowers/plans/linear-ids.md
git commit -m "docs: record Linear team and state IDs"
```

---

### Task 2: Decide and document the Jira migration scope

**Files:**
- Create: `docs/superpowers/plans/jira-migration-scope.md`

- [ ] **Step 1: List in-flight Jira issues**

Export from Jira the open/in-progress issues per project (CSV or JQL export). In-flight = anything not Done/Closed.

- [ ] **Step 2: Decide the cut**

Record the rule: **migrate in-flight issues** to the matching Linear team; **leave closed issues in Jira** as read-only history (no bulk history migration). Map each Jira project → Linear team.

- [ ] **Step 3: Commit the scope doc**

```bash
git add docs/superpowers/plans/jira-migration-scope.md
git commit -m "docs: define Jira to Linear migration scope"
```

---

### Task 3: Migrate in-flight issues

**Interfaces:**
- Consumes: team/state IDs from Task 1; the scope from Task 2.

- [ ] **Step 1: Import via Linear's Jira importer**

Use Linear Settings → Import → Jira for each project (it maps assignees, titles, descriptions, comments). If the importer cannot scope to in-flight only, import all then archive the closed ones in Linear.

- [ ] **Step 2: Map statuses**

During import, map Jira statuses to the new Linear states (e.g. Jira "In Review" → `Human Review`; anything mid-pipeline → `Backlog` so you re-enter it deliberately). Default ambiguous issues to `Backlog`, not an active state — you do not want Symphony to grab a half-understood ticket on day one.

- [ ] **Step 2 (verify): Count parity**

Run a Linear query counting issues per team and compare to the in-flight Jira export count.
Expected: counts match the migration scope. Investigate any delta before proceeding.

- [ ] **Step 3: Commit a migration log**

```bash
git add docs/superpowers/plans/jira-migration-log.md
git commit -m "docs: log Jira to Linear issue migration results"
```

---

### Task 4: Port the Jira templates/rules to Linear

**Files:**
- Modify: `.claude/rules/JIRA_RULES.md` → add a note that Linear is now the tracker
- Create: `.claude/rules/LINEAR_RULES.md`
- Reference: `.claude/jira_ticket_template.md`, `.claude/jira_epic_template.md`

- [ ] **Step 1: Create Linear templates**

In Linear, create issue templates mirroring `jira_ticket_template.md` (story) and `jira_epic_template.md` (epic). Add a template field/section for **target branch** and **design-doc path** so the pipeline entry convention is captured at ticket creation.

- [ ] **Step 2: Write LINEAR_RULES.md**

Document: team-per-repo mapping, the six-status meaning, branch naming (`TICKET-ID-short-description`), and the entry convention (create ticket → brainstorm on branch → set `Ready for Spec Review`).

- [ ] **Step 3: Mark JIRA_RULES.md superseded**

Add a header line to `JIRA_RULES.md`: "Superseded by LINEAR_RULES.md — Jira retained read-only for closed history."

- [ ] **Step 4: Commit**

```bash
git add .claude/rules/LINEAR_RULES.md .claude/rules/JIRA_RULES.md
git commit -m "docs: migrate tracker rules and templates from Jira to Linear"
```

---

### Task 5: Update repo docs that reference Jira

**Files:**
- Modify: `CLAUDE.md` (the JIRA_RULES reference and any Jira mentions)

- [ ] **Step 1: Find Jira references**

Run: `grep -rin "jira" CLAUDE.md .claude/ docs/ | grep -v jira-migration`
Expected: a list of references to update.

- [ ] **Step 2: Update CLAUDE.md**

Point the tracker guidance at Linear/`LINEAR_RULES.md`, keeping a one-line note that closed history lives in Jira.

- [ ] **Step 3: Verify no stale active references**

Run: `grep -rin "create.*jira\|jira ticket" CLAUDE.md .claude/rules/`
Expected: only the "superseded/read-only history" notes remain.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: point CLAUDE.md tracker guidance at Linear"
```

---

## Self-Review

- **Spec coverage:** team-per-repo (Task 1), Linear-as-control-plane migration (Tasks 2–3), six-status workflow (Task 1), template/rules carry-over (Tasks 4–5). ✓
- **Placeholders:** none — every step has a concrete action and a verification query/grep with expected output. ✓
- **Type consistency:** state names and active/parked/terminal classification identical to the design and to Plan B's config. ✓
- **Dependency honesty:** gated on Plan 0 GO/ADJUST; ambiguous issues default to `Backlog`, not active. ✓
