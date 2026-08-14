# Live external end-to-end tests

Paged out of the root `CLAUDE.md`. Read this when running the opt-in live tests or
investigating the coverage gate.

Note `make coverage` runs the suite twice — the second pass sets `SYMPHONY_COVER_REVIEW_MODULES=1`.

Live external end-to-end tests are opt-in (they create real tracker resources and launch a real agent session). `make e2e` covers Linear only; the other adapters are gated by their own env var and must be run directly:

```bash
export LINEAR_API_KEY=...
make e2e        # SYMPHONY_RUN_LIVE_E2E=1; targets test/symphony_elixir/live_e2e_test.exs

# per-tracker equivalents, all tagged :live_e2e
SYMPHONY_RUN_JIRA_LIVE_E2E=1   mix test test/symphony_elixir/jira_live_e2e_test.exs
# ...and likewise SYMPHONY_RUN_{ASANA,GITHUB,GITLAB}_LIVE_E2E
```
