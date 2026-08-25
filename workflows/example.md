---
# Sanitized example workflow — the only workflow kept in the product repo.
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
  host: "0.0.0.0"              # <-- bind all interfaces inside the container; a loopback bind
                               #     is unreachable from the published port. Host-side exposure
                               #     is controlled by the port mapping in compose. The 0.0.0.0
                               #     value is for the container only: when you run this workflow
                               #     from source, set 127.0.0.1: there is no --host flag, so
                               #     0.0.0.0 publishes the unauthenticated dashboard and JSON API
                               #     on every interface of your machine.
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
