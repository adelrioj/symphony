# Operator Console Design

**Status:** approved (layout B, "Live strip")
**Mockup:** https://claude.ai/artifact/BPavxMrwzps1cYJJe5tgPQ (open with `#b`)

## Goal

One page where an operator sees every lane's agents working, every ticket Symphony knows about, and
can act on a run without leaving the page.

## Layout (variant B)

- **Sidebar:** "All lanes" plus one entry per lane with a health dot (off / blocked / running /
  idle), its agent backend, and `running/max_concurrent_agents`. A "Needs attention" filter shows only
  blocked tickets. A link leads to lane management (the current lane card page, moved to `/lanes`).
- **Live strip** above the list: one group per lane in scope. Each running or blocked ticket is a
  tile (identifier, `T<turn>/<max_turns>` or "blocked", title, latest message or error). Free slots
  (`max_concurrent_agents - running`) render as one "N idle" tile, and a disabled lane as "Disabled".
- **Ticket list** with a group-by switch:
  - **Run status** (default): Running, Needs attention, Retry queue, Queued, Finished. Rows show
    tracker state.
  - **Tracker state:** each lane's `tracker.active_states`, then `agent.blocked_state`, then
    `tracker.terminal_states`, merged case-insensitively across lanes; tickets in states the config
    does not name go under "Other states"; finished runs go under "Finished runs" (their stored
    state is from dispatch time, so they are not placed into a tracker column). Empty groups are
    hidden. Rows show run status.
- **Detail panel** for the selected ticket: tracker state, run status, turns, tokens, blockers,
  error, latest agent message, attempt chips linking to `/runs/:attempt_id`, the latest attempt's
  last 50 events, and actions.

URL query carries `lane`, `group=tracker`, `attention=1` and `ticket=<lane>:<issue_id>` so views can
be linked.

## Actions

| Ticket status | Action | Effect |
|---|---|---|
| running | **Stop run** (inline confirm) | Orchestrator stops the task, records the attempt as `stopped`, releases the claim, keeps the workspace. The next poll may dispatch it again while it stays in an active state. |
| retrying | **Retry now** | Cancels the backoff timer and runs the retry immediately. |
| blocked | **Approve & resume** | Re-checks that the ticket is blocked (held blocked by the orchestrator, or in `agent.blocked_state` in the tracker; otherwise refuses with "it is no longer blocked"), moves it to the lane's first active state that is not `agent.blocked_state` through the `Tracker` behaviour, releases the orchestrator's block, then requests a refresh so the next poll starts a new attempt. |
| blocked | **Reply to agent** | Posts the message as a tracker comment, then does the same as Approve. The new attempt sees the comment only if its prompt or tools read comments. |

## Data the backend must add

- Ticket `title` and `labels` on running, blocked and retrying snapshot entries; `state` on retrying.
- A `queued` list: the last poll's candidates not running, claimed, blocked or retrying, in dispatch
  order, with blocker identifiers.
- `issue_title` on durable runs so finished tickets keep their title.
- `attempt_id` on running entries.

## Out of scope

HTTP API endpoints for the actions, a debounce for refreshes, dark mode, the mockup's rate-limit and
token-total cards, and the other layout variants.
