# Live external end-to-end tests

Paged out of the root `CLAUDE.md`. Read this when running the opt-in live tests or
investigating the coverage gate.

Note `make coverage` runs the suite twice — the second pass sets `SYMPHONY_COVER_REVIEW_MODULES=1`.

Live external end-to-end tests are opt-in (they create real tracker resources and launch a real agent session). `make e2e` covers Linear only; the other adapters are gated by their own env var and must be run directly:

`make e2e` runs two Linear files. `live_e2e_test.exs` is the heavyweight one: it creates a real
project and issue and launches a real agent session. `linear_scope_live_e2e_test.exs` is read-only
and fast — it exists because the team/label scope queries can be valid GraphQL, shaped exactly as
the unit tests assert, and still be rejected live: Linear scores query complexity multiplicatively
across nested connections, so a nested page size can blow the budget while every stub-based test
stays green. That failure refuses every team-scoped boot, so it is worth catching in CI.

```bash
export LINEAR_API_KEY=...
make e2e        # SYMPHONY_RUN_LIVE_E2E=1; targets live_e2e_test.exs + linear_scope_live_e2e_test.exs

# per-tracker equivalents, all tagged :live_e2e
SYMPHONY_RUN_JIRA_LIVE_E2E=1   mix test test/symphony_elixir/jira_live_e2e_test.exs
# ...and likewise SYMPHONY_RUN_{ASANA,GITHUB,GITLAB}_LIVE_E2E
```
