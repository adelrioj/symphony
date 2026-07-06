---
# Per-project config for one Symphony container. Edit the marked lines, copy this file
# to add more projects. Blank body below => Symphony's default Codex prompt template.
tracker:
  kind: linear
  project_slug: "REPLACE-with-linear-project-slug-a"   # <-- this project's Linear project
  required_labels: []
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
workspace:
  root: /workspaces            # <-- container volume; do NOT change (must match compose)
hooks:
  after_create: |
    git clone --depth 1 https://github.com/your-org/your-repo-a .   # <-- this project's repo
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
