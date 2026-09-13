---
# Sanitized workflow for importing one lane; live edits use the UI or lane API.
# Real client deployments live in their own private repos: copy deploy/client-template/.
# Blank body below => Symphony's default Codex prompt template.
tracker:
  kind: linear
  provider:
    project_slug: "REPLACE-with-your-linear-project-slug"   # <-- this project's Linear project
    # Or scope by team instead, so epics can come and go without a config change:
    # team_keys: ["REPLACE-with-your-team-key"]
    # current_cycle: true       # requires team_keys; the team's sprint becomes the queue
    # At least one of project_slug / team_keys / current_cycle is required.
    # BEFORE enabling team_keys, prune active_states / terminal_states below to names that really
    # exist in those teams: with team_keys set, startup preflight disables the lane on any state name
    # absent from every listed team. Merging and Rework do not exist in a default Linear workspace,
    # and Cancelled / Canceled are two spellings of one state — at most one of them can resolve.
  required_labels: []
  # any_labels: []              # when non-empty, an issue needs at least one of these
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
  host: "0.0.0.0"              # Legacy import example: server is ignored with a warning.
                               # Compose uses `serve --host 0.0.0.0` inside the container
                               # and publishes only host-side loopback. Source runs
                               # default to 127.0.0.1; use --host explicitly to change it.
workspace:
  root: /workspaces            # Container volume; use distinct subdirectories for additional lanes.
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
