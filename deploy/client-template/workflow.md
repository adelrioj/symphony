---
# Your Symphony pipeline. Edit the marked lines; everything else is a working default.
# Symphony re-reads this file about once a second — saving it applies the change live.
# A broken edit is logged and ignored; the last valid version keeps running.
# Blank body below => Symphony's default Codex prompt template. Write a prompt body here
# to drive a custom pipeline.
tracker:
  kind: linear
  provider:
    project_slug: "REPLACE-with-your-linear-project-slug"   # <-- this project's Linear project
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
