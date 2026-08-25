---
# Your Symphony pipeline. Edit the marked lines; everything else is a working default.
# Symphony re-reads this file about once a second — saving it applies the change live.
# A broken edit is logged and ignored; the last valid version keeps running.
# Blank body below => Symphony's default Codex prompt template. Write a prompt body here
# to drive a custom pipeline.
tracker:
  kind: linear
  provider:
    # <-- the slug from your Linear project's URL, NOT its display name: the last path segment
    #     of https://linear.app/<workspace>/project/<project-name>-<id>, e.g.
    #     my-project-4c1a9f3b7e02. A wrong value fails silently: Linear returns zero issues,
    #     nothing is logged, and the container sits idle forever with a healthy dashboard.
    #     Startup preflight cannot help here — it does not resolve project slugs.
    project_slug: "REPLACE-with-your-linear-project-slug"
    # Or scope by team instead, so epics can come and go without a config change. Unlike a
    # project slug, a team key IS checked at startup: a wrong one fails the boot with a named
    # error instead of idling silently.
    # team_keys: ["REPLACE-with-your-team-key"]
    # current_cycle: true       # requires team_keys; the team's active sprint becomes the queue
    # At least one of project_slug / team_keys / current_cycle is required.
    # BEFORE you uncomment team_keys, prune the active_states / terminal_states lists below to
    # names that really exist in those teams — that check only runs once team_keys is set, and it
    # fails the boot rather than warning. The shipped lists will not survive it as-is: Merging and
    # Rework do not exist in a default workspace, and Cancelled / Canceled are two spellings of one
    # state, so at most one of them can resolve.
  required_labels: []
  # any_labels: []              # when non-empty, an issue needs at least one of these labels
  # active_states / terminal_states must match the workflow state names in YOUR Linear workspace
  # exactly. Merging and Rework do not exist in a default workspace, and Cancelled / Canceled are
  # two spellings of one state. With team_keys set, a state name that exists in no listed team
  # fails the boot with a named error; with only project_slug set there is nothing to check it
  # against, and it is silently never matched — the same idle-container symptom as a wrong slug.
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
server:
  host: "0.0.0.0"             # <-- bind all interfaces INSIDE the container; do NOT change.
                              #     Docker forwards the published port to the container's eth0
                              #     address, so a loopback bind here makes the dashboard
                              #     unreachable. Exposure is controlled on the host side, by the
                              #     ports: entry in docker-compose.yml: container binds all
                              #     interfaces, host publishes loopback only.
workspace:
  root: /workspaces            # <-- container volume; do NOT change (must match compose)
hooks:
  after_create: |
    git clone --depth 1 https://github.com/your-org/your-repo .   # <-- this project's repo
agent:
  max_concurrent_agents: 5
  max_turns: 20
  backend: codex
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---
