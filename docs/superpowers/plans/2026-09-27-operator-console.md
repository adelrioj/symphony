# Operator Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the lane card landing page with an operator console: each lane's live agents in a strip, one ticket list grouped by run status or tracker state, a run detail panel, and four operator actions (Stop, Retry now, Approve & resume, Reply).

**Architecture:** The orchestrator snapshot gains ticket titles, labels, attempt ids and a `queued` list taken from the last poll. A pure `SymphonyElixirWeb.Console` module turns lane snapshots plus durable run history into tickets, groups and strips. `ConsoleLive` (at `/`) renders them through `ConsoleComponents` and refreshes on the existing `observability:dashboard` broadcast. Actions go through a new `SymphonyElixir.OperatorActions` module: stop and retry are orchestrator calls, and resume goes through the `Tracker` behaviour (`create_comment`, `update_issue_state`) so the normal blocked-issue reconcile releases the ticket.

**Tech Stack:** Elixir 1.19 / OTP 28, Phoenix LiveView, Ecto + SQLite (`ecto_sqlite3`), ExUnit with `Phoenix.LiveViewTest`.

**Spec:** `docs/superpowers/specs/2026-09-27-operator-console-design.md` (mockup: https://claude.ai/artifact/BPavxMrwzps1cYJJe5tgPQ#b)

## Global Constraints

- Run every `mix` command from `elixir/`; prefix with `mise exec --` when the shell is not mise-activated.
- Every public `def` in `lib/` needs an adjacent `@spec` (`mix specs.check`); `defp` and `@impl` callbacks are exempt.
- Coverage threshold is 100%. Add tests; do not add modules to the ignore list in `mix.exs`.
- `mix format` uses `line_length: 200`.
- Tracker calls go through `SymphonyElixir.Tracker` (the behaviour facade), never an adapter module.
- Config reads go through `SymphonyElixir.Config` / `LaneStore`; the LiveView process must call `LaneContext.put/1` (via `Presenter.orchestrator_for/1`) before any `Config.settings!/0`.
- Logging: issue events include `issue_id` and `issue_identifier` (see `elixir/docs/logging.md`).
- Tracker links render only for `http`/`https` URLs with a host.
- Orchestrator retry, reconcile and cleanup semantics must not change for existing paths.
- Behaviour changes update `SPEC.md` 13.7, `README.md` and `elixir/README.md` in the same branch.
- Full gate before handoff: `make all` in `elixir/`.

## Review Focus

1. **A lane whose orchestrator is down, disabled, or has invalid settings (`entry.settings == nil`).** The console must still render: the lane shows only history, no tiles, and "Disabled" when disabled. Pinned in Task 4 (`Console` tests with `settings: nil` and an error payload).
2. **The same issue id in two lanes.** Ticket keys are `<lane slug>:<issue_id>`, so selection and DOM lookups never collide. Pinned in Task 4.
3. **A `ticket` query param that no longer matches anything** (a pruned run, a mistyped link). The detail panel shows its empty state and actions report "Select a ticket first." instead of crashing. Pinned in Task 6.
4. **An action on a ticket whose state changed in the meantime** (stop after the run ended, retry after the retry fired). The orchestrator answers `{:error, :not_running | :not_retrying}` and the operator sees a plain-language flash. Pinned in Tasks 3 and 6.
5. **A tracker failure part way through resume.** A failed comment must not move the ticket. Pinned in Task 3.

---

## File Structure

| File | Responsibility |
|---|---|
| `elixir/lib/symphony_elixir/repo/migrations.ex` (modify) | New `AddRunIssueTitle` migration module |
| `elixir/lib/symphony_elixir/repo.ex` (modify) | Register the migration |
| `elixir/lib/symphony_elixir/runs/run.ex` (modify) | `issue_title` field |
| `elixir/lib/symphony_elixir/runs.ex` (modify) | Record `issue_title`; `for_issue/3` |
| `elixir/lib/symphony_elixir/orchestrator.ex` (modify) | `candidates` state, snapshot fields, `queued`, operator calls |
| `elixir/lib/symphony_elixir_web/presenter.ex` (modify) | Expose new snapshot fields and `queued` |
| `elixir/lib/symphony_elixir/operator_actions.ex` (create) | Stop, retry now, resume |
| `elixir/lib/symphony_elixir_web/console.ex` (create) | Pure projections: tickets, groups, strip, event text, safe URLs |
| `elixir/lib/symphony_elixir_web/components/console_components.ex` (create) | Function components and `console_path/2` |
| `elixir/lib/symphony_elixir_web/live/console_live.ex` (create) | The page: params, loading, actions |
| `elixir/lib/symphony_elixir_web/live/run_live.ex`, `lane_live.ex` (modify) | Reuse `Console.describe_event/1` and `Console.external_url/1` |
| `elixir/lib/symphony_elixir_web/router.ex`, `components/layouts.ex` (modify) | `/` → console, `/lanes` → lane cards, nav |
| `elixir/priv/static/dashboard.css` (modify) | `console-*` styles |
| `SPEC.md`, `README.md`, `elixir/README.md` (modify) | Docs |

---

### Task 1: Durable ticket titles and per-issue attempt history

**Files:**
- Modify: `elixir/lib/symphony_elixir/repo/migrations.ex` (append a module)
- Modify: `elixir/lib/symphony_elixir/repo.ex:13-17` (`@migrations`)
- Modify: `elixir/lib/symphony_elixir/runs/run.ex` (schema + changeset cast list)
- Modify: `elixir/lib/symphony_elixir/runs.ex` (`started/1`, new `for_issue/3`)
- Test: `elixir/test/symphony_elixir/runs_test.exs`

**Interfaces:**
- Produces: `Run.issue_title :: String.t() | nil`; `Runs.for_issue(lane_id :: term(), issue_id :: String.t(), limit :: pos_integer()) :: [Run.t()]`, newest first.

- [ ] **Step 1: Write the failing test** (append inside `SymphonyElixir.RunsTest`)

```elixir
  test "attempts keep the ticket title and list newest first per issue" do
    lane_id = LaneContext.current!()
    issue = %Issue{id: "titled", identifier: "TT-1", title: "Keep my title", state: "Todo"}
    :ok = Runs.started(%{lane_id: lane_id, issue: issue, attempt_id: "titled-1", attempt: 1})
    :ok = Runs.finished("titled-1", "failed")
    :ok = Runs.started(%{lane_id: lane_id, issue: issue, attempt_id: "titled-2", attempt: 2})
    :ok = Runs.started(%{lane_id: lane_id, issue: %Issue{issue | id: "other", identifier: "TT-2"}, attempt_id: "other-1", attempt: 1})

    assert [%Run{attempt_id: "titled-2", issue_title: "Keep my title"}, %Run{attempt_id: "titled-1"}] = Runs.for_issue(lane_id, "titled", 10)
    assert [%Run{attempt_id: "titled-2"}] = Runs.for_issue(lane_id, "titled", 1)
    assert [] = Runs.for_issue(lane_id, "missing", 10)
  end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mix test test/symphony_elixir/runs_test.exs`
Expected: FAIL, `undefined function for_issue/3` (and no `issue_title` key).

- [ ] **Step 3: Add the migration** (append to `migrations.ex`)

```elixir
defmodule SymphonyElixir.Repo.Migrations.AddRunIssueTitle do
  @moduledoc false
  use Ecto.Migration

  @spec change() :: term()
  def change do
    alter table(:runs) do
      add(:issue_title, :string)
    end
  end
end
```

Register it in `repo.ex`:

```elixir
  @migrations [
    {20_260_912_000_001, SymphonyElixir.Repo.Migrations.CreateLanesAndRuns},
    {20_260_919_000_001, SymphonyElixir.Repo.Migrations.CreateHostLossAlarms},
    {20_260_920_000_001, SymphonyElixir.Repo.Migrations.AddExecutionProfiles},
    {20_260_927_000_001, SymphonyElixir.Repo.Migrations.AddRunIssueTitle}
  ]
```

- [ ] **Step 4: Add the field, cast it, record it, query it**

`run.ex`: add `field(:issue_title, :string)` after `field(:issue_identifier, :string)`, and add `:issue_title` after `:issue_identifier` in the `cast/3` list.

`runs.ex`, inside `started/1`'s map, after `issue_identifier: issue.identifier,`:

```elixir
         issue_title: issue.title,
```

`runs.ex`, after `list_for_lane/2`:

```elixir
  @spec for_issue(term(), String.t(), pos_integer()) :: [Run.t()]
  def for_issue(lane_id, issue_id, limit) when is_binary(issue_id) do
    flush()
    Repo.all(from(r in Run, where: r.lane_id == ^lane_id and r.issue_id == ^issue_id, order_by: [desc: r.started_at, desc: r.id], limit: ^limit))
  end
```

- [ ] **Step 5: Run the tests**

Run: `mix test test/symphony_elixir/runs_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/repo/migrations.ex elixir/lib/symphony_elixir/repo.ex elixir/lib/symphony_elixir/runs/run.ex elixir/lib/symphony_elixir/runs.ex elixir/test/symphony_elixir/runs_test.exs
git commit -m "feat(runs): keep ticket titles and list attempts per issue"
```

---

### Task 2: Snapshot titles, labels, attempt ids and the queued list

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex` (State defstruct ~line 47; `maybe_dispatch/1` ~line 492; `handle_call(:snapshot, ...)` ~line 2814; private helpers after `blocked_issue_url/1` ~line 2906)
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

**Interfaces:**
- Produces (snapshot): running entries gain `title`, `labels`, `attempt_id`; blocked entries gain `title`, `labels`; retrying entries gain `title`, `state`, `labels` (from the last poll, `nil`/`[]` when absent); new `queued: [%{issue_id, identifier, title, state, labels, issue_url, priority, blocked_by :: [String.t()]}]` in dispatch order.
- Produces (presenter payload): the same fields; `queued` entries use `issue_identifier` like every other payload list; `counts.queued`.

- [ ] **Step 1: Write the failing tests** (append inside `SymphonyElixir.OrchestratorStatusTest`)

```elixir
  test "snapshot lists undispatched candidates from the last poll and titles live entries" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", max_concurrent_agents: 1)
    running = %Issue{id: "q-run", identifier: "Q-1", title: "Runs now", state: "Todo", labels: ["api"], priority: 1, dispatchable: true}
    waiting = %Issue{id: "q-wait", identifier: "Q-2", title: "Waits", state: "Todo", priority: 2, dispatchable: true, blocked_by: [%{id: "q-0", identifier: "Q-0", state: "Todo"}, %{id: "no-identifier"}]}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [running, waiting])
    parent = self()

    runner = fn issue, _recipient, _opts ->
      send(parent, {:dispatched, issue.id})

      receive do
        :finish -> :ok
      end
    end

    {:ok, pid} = start_test_orchestrator(name: Module.concat(__MODULE__, QueuedSnapshot), runner_fun: runner)
    assert_receive {:dispatched, "q-run"}, 5_000
    snapshot = wait_for_snapshot(pid, &(&1.queued != []), 5_000)

    assert [%{issue_id: "q-run", title: "Runs now", labels: ["api"], attempt_id: attempt_id}] = snapshot.running
    assert is_binary(attempt_id)
    assert [%{issue_id: "q-wait", identifier: "Q-2", title: "Waits", state: "Todo", priority: 2, blocked_by: ["Q-0"]}] = snapshot.queued

    payload = Presenter.state_payload(pid, 1_000)
    assert payload.counts.queued == 1
    assert [%{issue_identifier: "Q-2", title: "Waits", blocked_by: ["Q-0"]}] = payload.queued
    assert [%{title: "Runs now", labels: ["api"], attempt_id: ^attempt_id}] = payload.running
  end

  test "blocked and retrying snapshot entries carry ticket titles when known" do
    # The default fixture lane is Linear, so background polls fail and never overwrite `candidates`.
    {:ok, pid} = start_test_orchestrator(name: Module.concat(__MODULE__, TitledEntries))
    blocked_issue = %Issue{id: "b-1", identifier: "B-1", title: "Needs approval", state: "Blocked / Needs Attention", labels: ["db"]}
    retry_issue = %Issue{id: "r-1", identifier: "R-1", title: "Try again", state: "Todo", labels: []}
    due = System.monotonic_time(:millisecond) + 60_000

    :sys.replace_state(pid, fn state ->
      %{
        state
        | blocked: %{"b-1" => %{identifier: "B-1", issue: blocked_issue, blocked_at: DateTime.utc_now()}, "b-2" => %{identifier: "B-2"}},
          retry_attempts: %{"r-1" => %{attempt: 2, due_at_ms: due, identifier: "R-1"}, "r-2" => %{attempt: 1, due_at_ms: due, identifier: "R-2"}},
          candidates: [retry_issue]
      }
    end)

    snapshot = GenServer.call(pid, :snapshot)
    assert [%{issue_id: "b-1", title: "Needs approval", labels: ["db"]}, %{issue_id: "b-2", title: nil, labels: []}] = Enum.sort_by(snapshot.blocked, & &1.issue_id)
    assert [%{issue_id: "r-1", title: "Try again", state: "Todo"}, %{issue_id: "r-2", title: nil, state: nil, labels: []}] = Enum.sort_by(snapshot.retrying, & &1.issue_id)
    assert snapshot.queued == []

    payload = Presenter.state_payload(pid, 1_000)
    assert [%{title: "Try again", state: "Todo", labels: []} | _] = Enum.sort_by(payload.retrying, & &1.issue_id)
    assert [%{title: "Needs approval", labels: ["db"]} | _] = Enum.sort_by(payload.blocked, & &1.issue_id)
  end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mix test test/symphony_elixir/orchestrator_status_test.exs`
Expected: FAIL with `KeyError` for `:queued` / `:candidates`.

- [ ] **Step 3: Remember the last poll's candidates**

Add to the `State` defstruct, after `turn_exhaustions: %{},`:

```elixir
      candidates: [],
```

In `maybe_dispatch/1`, replace the `with` head and body (keep every `else` clause as is):

```elixir
    with true <- managed_dispatch_ready?(state),
         :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_issues_by_states(Config.settings!().tracker.active_states) do
      state = %{state | candidates: issues}
      if available_slots(state) > 0, do: choose_issues(issues, state), else: state
    else
```

The old `true <- available_slots(state) > 0` step moves into the body; its `false -> state` result is unchanged, and the `false` clause still serves `managed_dispatch_ready?/1`.

- [ ] **Step 4: Add the snapshot fields**

In `handle_call(:snapshot, ...)`, running map: add after `state: metadata.issue.state,`:

```elixir
          title: metadata.issue.title,
          labels: metadata.issue.labels,
          attempt_id: Map.get(metadata, :attempt_id),
```

Retrying map: add after `identifier: Map.get(retry, :identifier),`:

```elixir
          title: candidate_field(state.candidates, issue_id, :title),
          state: candidate_field(state.candidates, issue_id, :state),
          labels: candidate_field(state.candidates, issue_id, :labels) || [],
```

Blocked map: add after `state: blocked_issue_state(metadata),`:

```elixir
          title: blocked_issue_field(metadata, :title),
          labels: blocked_issue_field(metadata, :labels) || [],
```

Before the `{:reply, ...}`, build the queued list:

```elixir
    taken = state.claimed |> MapSet.union(MapSet.new(Map.keys(state.running) ++ Map.keys(state.blocked) ++ Map.keys(state.retry_attempts)))

    queued =
      for %Issue{id: id} = issue <- sort_issues_for_dispatch(state.candidates), not MapSet.member?(taken, id) do
        %{
          issue_id: id,
          identifier: issue.identifier,
          title: issue.title,
          state: issue.state,
          labels: issue.labels,
          issue_url: issue.url,
          priority: issue.priority,
          blocked_by: blocker_identifiers(issue.blocked_by)
        }
      end
```

and add `queued: queued,` after `blocked: blocked,` in the reply map.

Helpers, after `blocked_issue_url/1`:

```elixir
  defp blocked_issue_field(%{issue: %Issue{} = issue}, field), do: Map.fetch!(issue, field)
  defp blocked_issue_field(_metadata, _field), do: nil

  defp candidate_field(candidates, issue_id, field) do
    case Enum.find(candidates, &(&1.id == issue_id)) do
      %Issue{} = issue -> Map.fetch!(issue, field)
      nil -> nil
    end
  end

  defp blocker_identifiers(blockers) do
    Enum.flat_map(blockers, fn
      %{identifier: identifier} when is_binary(identifier) -> [identifier]
      _ -> []
    end)
  end
```

- [ ] **Step 5: Expose them in the presenter**

In `state_payload/2`, add `queued: length(Map.get(snapshot, :queued, []))` to `counts`, and after the `blocked:` line:

```elixir
          queued: Enum.map(Map.get(snapshot, :queued, []), &queued_entry_payload/1),
```

In `running_entry_payload/1` add after `state: entry.state,`:

```elixir
      title: Map.get(entry, :title),
      labels: Map.get(entry, :labels) || [],
      attempt_id: Map.get(entry, :attempt_id),
```

In `retry_entry_payload/1` add after `issue_url: ...`:

```elixir
      title: Map.get(entry, :title),
      state: Map.get(entry, :state),
      labels: Map.get(entry, :labels) || [],
```

In `blocked_entry_payload/1` add after `state: entry.state,`:

```elixir
      title: Map.get(entry, :title),
      labels: Map.get(entry, :labels) || [],
```

New private function next to the other payload builders:

```elixir
  defp queued_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: entry.title,
      state: entry.state,
      labels: entry.labels,
      issue_url: entry.issue_url,
      priority: entry.priority,
      blocked_by: entry.blocked_by
    }
  end
```

- [ ] **Step 6: Run the file, then the orchestrator suites**

Run: `mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/orchestrator_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/managed_orchestrator_test.exs`
Expected: PASS. If an existing test pattern-matches the whole snapshot or payload map exactly, add the new keys to its expectation; do not remove keys.

- [ ] **Step 7: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/lib/symphony_elixir_web/presenter.ex elixir/test/symphony_elixir/orchestrator_status_test.exs
git commit -m "feat(orchestrator): expose ticket titles and the queued list in snapshots"
```

---

### Task 3: Operator actions

**Files:**
- Create: `elixir/lib/symphony_elixir/operator_actions.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex` (two `handle_call` clauses next to `handle_call(:request_refresh, ...)`)
- Test: `elixir/test/symphony_elixir/operator_actions_test.exs`

**Interfaces:**
- Produces:
  - `OperatorActions.stop(GenServer.server(), String.t()) :: :ok | {:error, :not_running | :unavailable}`
  - `OperatorActions.retry_now(GenServer.server(), String.t()) :: :ok | {:error, :not_retrying | :unavailable}`
  - `OperatorActions.resume(GenServer.server(), String.t(), String.t() | nil) :: :ok | {:error, term()}`. The caller must already be in the lane's `LaneContext`.
  - Orchestrator calls `{:operator_stop, issue_id}` and `{:operator_retry_now, issue_id}`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule SymphonyElixir.OperatorActionsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{OperatorActions, Runs}
  alias SymphonyElixir.Runs.Run
  alias SymphonyElixir.Tracker.Memory

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", max_concurrent_agents: 1)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    :ok
  end

  test "stop ends a running attempt as stopped and releases the ticket" do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%Issue{id: "op-run", identifier: "OP-1", title: "Stop me", state: "Todo", dispatchable: true}])
    {:ok, pid} = start_test_orchestrator(name: Module.concat(__MODULE__, Stop), runner_fun: blocking_runner())
    assert_receive {:dispatched, "op-run"}, 5_000
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    %{running: [%{attempt_id: attempt_id}]} = GenServer.call(pid, :snapshot)

    assert :ok = OperatorActions.stop(pid, "op-run")
    assert %{running: [], claimed: 0} = GenServer.call(pid, :snapshot)
    assert %Run{status: "stopped"} = Runs.get_by_attempt(attempt_id)
    assert {:error, :not_running} = OperatorActions.stop(pid, "op-run")
  end

  test "retry now runs a pending retry immediately" do
    {:ok, pid} = start_test_orchestrator(name: Module.concat(__MODULE__, RetryNow), runner_fun: blocking_runner())
    wait_for_first_poll(pid)
    token = make_ref()
    timer = Process.send_after(self(), :unused_timer, 60_000)

    :sys.replace_state(pid, fn state ->
      %{state | retry_attempts: %{"op-retry" => %{attempt: 1, timer_ref: timer, retry_token: token, due_at_ms: System.monotonic_time(:millisecond) + 60_000, identifier: "OP-2"}}}
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%Issue{id: "op-retry", identifier: "OP-2", title: "Retry me", state: "Todo", dispatchable: true}])
    assert :ok = OperatorActions.retry_now(pid, "op-retry")
    assert_receive {:dispatched, "op-retry"}, 5_000
    assert Process.read_timer(timer) == false
    assert {:error, :not_retrying} = OperatorActions.retry_now(pid, "op-retry")
  end

  test "resume comments, then moves the ticket to the first active state that is not the blocked state" do
    {:ok, pid} = start_test_orchestrator(name: Module.concat(__MODULE__, Resume))
    assert :ok = OperatorActions.resume(pid, "op-blocked", "Tokens are in design/dark.json")
    assert_receive {:memory_tracker_comment, "op-blocked", "Tokens are in design/dark.json"}
    assert_receive {:memory_tracker_state_update, "op-blocked", "Todo"}

    assert :ok = OperatorActions.resume(pid, "op-blocked", "  ")
    refute_receive {:memory_tracker_comment, _, _}, 50
    assert_receive {:memory_tracker_state_update, "op-blocked", "Todo"}
  end

  test "resume skips the blocked state and refuses when no other active state exists" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["Blocked / Needs Attention", "In Progress"])
    assert :ok = OperatorActions.resume(:missing_orchestrator, "op-blocked", nil)
    assert_receive {:memory_tracker_state_update, "op-blocked", "In Progress"}

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_active_states: ["Blocked / Needs Attention"])
    assert {:error, :no_active_state} = OperatorActions.resume(:missing_orchestrator, "op-blocked", nil)
  end

  test "resume stops at the first tracker failure" do
    Memory.fail(:create_comment)
    assert {:error, {:memory_tracker_failed, :create_comment}} = OperatorActions.resume(:missing_orchestrator, "op-blocked", "hello")
    refute_receive {:memory_tracker_state_update, _, _}, 50
  end

  test "stop and retry report an unavailable lane" do
    assert {:error, :unavailable} = OperatorActions.stop(:missing_orchestrator, "x")
    assert {:error, :unavailable} = OperatorActions.retry_now(:missing_orchestrator, "x")
  end

  defp blocking_runner do
    parent = self()

    fn issue, _recipient, _opts ->
      send(parent, {:dispatched, issue.id})

      receive do
        :finish -> :ok
      end
    end
  end

  defp wait_for_first_poll(pid, attempts \\ 200) do
    %{polling: polling} = GenServer.call(pid, :snapshot)

    cond do
      not polling.checking? and polling.next_poll_in_ms > 1_000 -> :ok
      attempts == 0 -> flunk("orchestrator never finished its first poll")
      true -> Process.sleep(10) && wait_for_first_poll(pid, attempts - 1)
    end
  end
end
```

`write_workflow_file!` publishes the lane config that `Config.settings!/0` reads in the test process. If the second `write_workflow_file!` in a test is not picked up, check how `core_test.exs` rewrites the workflow mid-test and use the same reload call.

- [ ] **Step 2: Run them and watch them fail**

Run: `mix test test/symphony_elixir/operator_actions_test.exs`
Expected: FAIL, `SymphonyElixir.OperatorActions is not available`.

- [ ] **Step 3: Write the module**

```elixir
defmodule SymphonyElixir.OperatorActions do
  @moduledoc """
  Operator controls for one lane's tickets. Stop and retry act on the lane orchestrator. Resuming a
  blocked ticket goes through the `Tracker` behaviour, so the normal blocked-issue reconcile releases it
  and a new attempt starts. Callers must already be in the lane's `LaneContext`.
  """

  alias SymphonyElixir.{Config, Orchestrator, Tracker}

  @spec stop(GenServer.server(), String.t()) :: :ok | {:error, :not_running | :unavailable}
  def stop(orchestrator, issue_id) when is_binary(issue_id), do: call(orchestrator, {:operator_stop, issue_id})

  @spec retry_now(GenServer.server(), String.t()) :: :ok | {:error, :not_retrying | :unavailable}
  def retry_now(orchestrator, issue_id) when is_binary(issue_id), do: call(orchestrator, {:operator_retry_now, issue_id})

  @spec resume(GenServer.server(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def resume(orchestrator, issue_id, message) when is_binary(issue_id) do
    with {:ok, target} <- resume_state(),
         :ok <- comment(issue_id, message),
         :ok <- Tracker.update_issue_state(issue_id, target) do
      _ = Orchestrator.request_refresh(orchestrator)
      :ok
    end
  end

  defp resume_state do
    settings = Config.settings!()

    case Enum.reject(settings.tracker.active_states, &(&1 == settings.agent.blocked_state)) do
      [target | _] -> {:ok, target}
      [] -> {:error, :no_active_state}
    end
  end

  defp comment(issue_id, message) when is_binary(message) do
    case String.trim(message) do
      "" -> :ok
      body -> Tracker.create_comment(issue_id, body)
    end
  end

  defp comment(_issue_id, nil), do: :ok

  defp call(orchestrator, message) do
    GenServer.call(orchestrator, message)
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
```

- [ ] **Step 4: Add the orchestrator calls** (after `handle_call(:request_refresh, ...)`)

```elixir
  def handle_call({:operator_stop, issue_id}, _from, state) do
    case Map.get(state.running, issue_id) do
      nil ->
        {:reply, {:error, :not_running}, state}

      entry ->
        Logger.info("Operator stopped issue_id=#{issue_id} issue_identifier=#{entry.identifier}")
        state = terminate_running_issue(state, issue_id, false)
        notify_dashboard()
        {:reply, :ok, state}
    end
  end

  def handle_call({:operator_retry_now, issue_id}, _from, state) do
    case Map.get(state.retry_attempts, issue_id) do
      %{retry_token: token} = retry ->
        if is_reference(retry[:timer_ref]), do: Process.cancel_timer(retry.timer_ref)
        Logger.info("Operator requested immediate retry issue_id=#{issue_id} issue_identifier=#{retry[:identifier]}")
        send(self(), {:retry_issue, issue_id, token})
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :not_retrying}, state}
    end
  end
```

`terminate_running_issue/3` already records the attempt as `stopped`, releases the claim and keeps the workspace when `cleanup_workspace` is `false`. The `{:retry_issue, id, token}` message takes the same path as a fired timer, so retry semantics do not change.

- [ ] **Step 5: Run the tests**

Run: `mix test test/symphony_elixir/operator_actions_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/operator_actions.ex elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/operator_actions_test.exs
git commit -m "feat: add operator stop, retry-now and resume actions"
```

---

### Task 4: Console projections

**Files:**
- Create: `elixir/lib/symphony_elixir_web/console.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/run_live.ex` (use `Console.describe_event/1`, delete its `describe/1` clauses)
- Modify: `elixir/lib/symphony_elixir_web/live/lane_live.ex` (use `Console.external_url/1`, delete `external_issue_url/1`)
- Test: `elixir/test/symphony_elixir_web/console_test.exs`

**Interfaces:**
- Consumes: presenter payload lists (Task 2) and `Run.issue_title` (Task 1).
- Produces:
  - `@type lane_view :: %{entry: Entry.t(), payload: map(), runs: [Run.t()]}`
  - `Console.tickets([lane_view]) :: [ticket]`, where a ticket is a map with keys `key` (`"<slug>:<issue_id>"`), `lane`, `issue_id`, `identifier`, `title`, `tracker_state`, `status`, `labels`, `url`, `blocked_by`, `attempt`, `turn_count`, `last_message`, `error`, `due_at`, `started_at`, `tokens`
  - `Console.groups([ticket], :status | :tracker, [Entry.t()]) :: [%{key, label, icon, category, tickets}]`
  - `Console.strip(Entry.t(), [ticket]) :: %{agents: [ticket], idle: non_neg_integer(), max: non_neg_integer()}`
  - `Console.agent_setting(Entry.t(), atom(), term()) :: term()`
  - `Console.describe_event(map()) :: String.t()`
  - `Console.external_url(term()) :: String.t() | nil`

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule SymphonyElixirWeb.ConsoleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LaneStore.Entry
  alias SymphonyElixir.Runs.Run
  alias SymphonyElixirWeb.Console

  @settings %{
    tracker: %{active_states: ["Todo", "In Progress"], terminal_states: ["Done"]},
    agent: %{max_concurrent_agents: 3, max_turns: 20, backend: "codex", blocked_state: "Blocked"}
  }

  test "flattens live entries and finished history into lane-scoped tickets" do
    runs = [run("i5", "A-5", "done"), run("i5", "A-5", "failed"), run("i1", "A-1", "done"), run("i6", "A-6", "running")]
    tickets = Console.tickets([%{entry: entry("main"), payload: payload(), runs: runs}])

    assert Enum.map(tickets, &{&1.identifier, &1.status}) == [{"A-1", "running"}, {"A-2", "blocked"}, {"A-3", "retrying"}, {"A-4", "queued"}, {"A-5", "done"}]
    assert %{key: "main:i1", lane: "main", labels: ["api"], turn_count: 4, url: "https://linear.app/a/A-1"} = hd(tickets)
    assert %{key: "main:i4", blocked_by: ["A-1"], url: nil} = Enum.at(tickets, 3)
    assert %{title: "Old A-5", tokens: %{total_tokens: 6}, started_at: "2026-09-27T09:00:00Z"} = List.last(tickets)
  end

  test "keys stay unique across lanes, and unavailable lanes contribute only history" do
    unavailable = %{error: %{code: "snapshot_unavailable"}}

    tickets =
      Console.tickets([
        %{entry: entry("main"), payload: payload(), runs: []},
        %{entry: entry("other", settings: nil), payload: unavailable, runs: [run("i1", "A-1", "done")]}
      ])

    keys = Enum.map(tickets, & &1.key)
    assert "main:i1" in keys and "other:i1" in keys
    assert length(keys) == length(Enum.uniq(keys))
  end

  test "run-status groups keep a fixed order and keep empty groups" do
    tickets = Console.tickets([%{entry: entry("main"), payload: payload(), runs: [run("i5", "A-5", "turns_exhausted")]}])

    assert Enum.map(Console.groups(tickets, :status, [entry("main")]), &{&1.key, length(&1.tickets)}) ==
             [{"running", 1}, {"blocked", 1}, {"retrying", 1}, {"queued", 1}, {"finished", 1}]

    assert Enum.map(Console.groups([], :status, []), &length(&1.tickets)) == [0, 0, 0, 0, 0]
  end

  test "tracker-state groups follow lane config, merge spellings, and keep history apart" do
    github = entry("mobile", settings: %{tracker: %{active_states: ["todo"], terminal_states: nil}, agent: %{max_concurrent_agents: 1, max_turns: 30, backend: "claude", blocked_state: "Blocked"}})

    tickets =
      Console.tickets([
        %{entry: entry("main"), payload: payload(), runs: [run("i5", "A-5", "done")]},
        %{entry: github, payload: %{queued: [%{issue_id: "g1", issue_identifier: "#1", state: "triage"}]}, runs: []}
      ])

    groups = Console.groups(tickets, :tracker, [entry("main"), github, entry("broken", settings: nil)])

    assert Enum.map(groups, &{&1.label, &1.category, Enum.map(&1.tickets, fn t -> t.identifier end)}) == [
             {"Todo", "active", ["A-3", "A-4"]},
             {"In Progress", "active", ["A-1"]},
             {"Blocked", "blocked", ["A-2"]},
             {"Other states", nil, ["#1"]},
             {"Finished runs", nil, ["A-5"]}
           ]
  end

  test "strip shows running and blocked agents and counts idle slots from running only" do
    tickets = Console.tickets([%{entry: entry("main"), payload: payload(), runs: []}])
    assert %{agents: [%{identifier: "A-1"}, %{identifier: "A-2"}], idle: 2, max: 3} = Console.strip(entry("main"), tickets)
    assert %{agents: [], idle: 0, max: 0} = Console.strip(entry("off", enabled: false), tickets)
    assert %{idle: 0, max: 0} = Console.strip(entry("broken", settings: nil), [])
    assert Console.agent_setting(entry("main"), :backend, "codex") == "codex"
    assert Console.agent_setting(entry("broken", settings: nil), :backend, "codex") == "codex"
  end

  test "describes stored event payloads and keeps only web tracker links" do
    assert Console.describe_event(%{"message" => "hello"}) == "hello"
    assert Console.describe_event(%{"total_tokens" => 7, "input_tokens" => 3, "output_tokens" => 4}) == "in 3 / out 4 / cached 0 / total 7"
    assert Console.describe_event(%{"event" => "turn_started"}) == "turn_started"
    assert Console.describe_event(%{"other" => 1}) == ~s({"other":1})

    assert Console.external_url(" https://linear.app/a/A-1 ") == "https://linear.app/a/A-1"
    assert Console.external_url("javascript:alert(1)") == nil
    assert Console.external_url("https://") == nil
    assert Console.external_url(nil) == nil
  end

  defp entry(slug, opts \\ []) do
    %Entry{lane_id: slug, slug: slug, name: String.capitalize(slug), enabled: Keyword.get(opts, :enabled, true), settings: Keyword.get(opts, :settings, @settings)}
  end

  defp payload do
    %{
      running: [
        %{
          issue_id: "i1",
          issue_identifier: "A-1",
          issue_url: "https://linear.app/a/A-1",
          title: "Run",
          state: "In Progress",
          labels: ["api"],
          turn_count: 4,
          last_message: "working",
          tokens: %{input_tokens: 10, output_tokens: 2, total_tokens: 12},
          started_at: "2026-09-27T10:00:00Z"
        }
      ],
      blocked: [%{issue_id: "i2", issue_identifier: "A-2", title: nil, state: "Blocked", error: "approval_required"}],
      retrying: [%{issue_id: "i3", issue_identifier: "A-3", title: "Again", state: "todo", attempt: 2, due_at: "2026-09-27T10:05:00Z", error: "turn_failed"}],
      queued: [%{issue_id: "i4", issue_identifier: "A-4", title: "Next", state: "Todo", labels: [], issue_url: "file:///etc/passwd", blocked_by: ["A-1"]}]
    }
  end

  defp run(issue_id, identifier, status) do
    %Run{
      issue_id: issue_id,
      issue_identifier: identifier,
      issue_title: "Old " <> identifier,
      issue_state: "Todo",
      status: status,
      attempt_id: "#{identifier}-#{status}",
      attempt: 1,
      turns: 3,
      input_tokens: 5,
      output_tokens: 1,
      started_at: ~U[2026-09-27 09:00:00Z]
    }
  end
end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mix test test/symphony_elixir_web/console_test.exs`
Expected: FAIL, `SymphonyElixirWeb.Console is not available`.

- [ ] **Step 3: Write the module**

```elixir
defmodule SymphonyElixirWeb.Console do
  @moduledoc """
  Pure projections for the operator console. Flattens lane snapshots and durable run history into
  tickets, groups them by run status or tracker state, and sizes each lane's agent strip.
  """

  alias SymphonyElixir.LaneStore.Entry
  alias SymphonyElixir.Runs.Run

  @type lane_view :: %{entry: Entry.t(), payload: map(), runs: [Run.t()]}
  @type ticket :: map()
  @type group :: %{key: String.t(), label: String.t(), icon: String.t(), category: String.t() | nil, tickets: [ticket()]}

  @finished_limit 20
  @live_statuses ~w(running blocked retrying queued)
  @status_groups [
    {"running", "Running", ["running"]},
    {"blocked", "Needs attention", ["blocked"]},
    {"retrying", "Retry queue", ["retrying"]},
    {"queued", "Queued", ["queued"]},
    {"finished", "Finished", ~w(done failed turns_exhausted stopped)}
  ]
  @category_order %{"active" => 0, "blocked" => 1, "terminal" => 2}

  @spec tickets([lane_view()]) :: [ticket()]
  def tickets(views), do: Enum.flat_map(views, &lane_tickets/1)

  @spec groups([ticket()], :status | :tracker, [Entry.t()]) :: [group()]
  def groups(tickets, :status, _entries) do
    for {key, label, statuses} <- @status_groups do
      %{key: key, label: label, icon: key, category: nil, tickets: Enum.filter(tickets, &(&1.status in statuses))}
    end
  end

  def groups(tickets, :tracker, entries) do
    {live, finished} = Enum.split_with(tickets, &(&1.status in @live_statuses))

    {state_groups, other} =
      Enum.map_reduce(tracker_states(entries), live, fn {state, category}, remaining ->
        {mine, rest} = Enum.split_with(remaining, &same_state?(&1.tracker_state, state))
        {%{key: "state:" <> state, label: state, icon: category, category: category, tickets: mine}, rest}
      end)

    Enum.reject(
      state_groups ++
        [
          %{key: "other", label: "Other states", icon: "queued", category: nil, tickets: other},
          %{key: "finished", label: "Finished runs", icon: "finished", category: nil, tickets: finished}
        ],
      &(&1.tickets == [])
    )
  end

  @spec strip(Entry.t(), [ticket()]) :: %{agents: [ticket()], idle: non_neg_integer(), max: non_neg_integer()}
  def strip(%Entry{} = entry, tickets) do
    agents = Enum.filter(tickets, &(&1.lane == entry.slug and &1.status in ["running", "blocked"]))
    max = if entry.enabled, do: agent_setting(entry, :max_concurrent_agents, 0), else: 0
    running = Enum.count(agents, &(&1.status == "running"))
    %{agents: agents, idle: max(max - running, 0), max: max}
  end

  @spec agent_setting(Entry.t(), atom(), term()) :: term()
  def agent_setting(%Entry{settings: %{agent: agent}}, key, _default), do: Map.get(agent, key)
  def agent_setting(_entry, _key, default), do: default

  @spec describe_event(map()) :: String.t()
  def describe_event(%{"message" => message}) when is_binary(message) and message != "", do: message
  def describe_event(%{"total_tokens" => total} = payload), do: "in #{payload["input_tokens"]} / out #{payload["output_tokens"]} / cached #{payload["cached_tokens"] || 0} / total #{total}"
  def describe_event(%{"event" => event}) when is_binary(event), do: event
  def describe_event(payload), do: Jason.encode!(payload)

  @spec external_url(term()) :: String.t() | nil
  def external_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" -> url
      _ -> nil
    end
  end

  def external_url(_url), do: nil

  defp lane_tickets(%{entry: entry, payload: payload, runs: runs}) do
    live =
      Enum.flat_map(@live_statuses, fn status ->
        payload |> Map.get(String.to_existing_atom(status), []) |> Enum.map(&live_ticket(entry, status, &1))
      end)

    live_ids = MapSet.new(live, & &1.issue_id)

    finished =
      runs
      |> Enum.reject(&(&1.status == "running" or MapSet.member?(live_ids, &1.issue_id)))
      |> Enum.uniq_by(& &1.issue_id)
      |> Enum.take(@finished_limit)
      |> Enum.map(&run_ticket(entry, &1))

    live ++ finished
  end

  defp live_ticket(entry, status, item) do
    %{
      key: entry.slug <> ":" <> item.issue_id,
      lane: entry.slug,
      issue_id: item.issue_id,
      identifier: item.issue_identifier,
      title: Map.get(item, :title),
      tracker_state: Map.get(item, :state),
      status: status,
      labels: Map.get(item, :labels) || [],
      url: external_url(Map.get(item, :issue_url)),
      blocked_by: Map.get(item, :blocked_by, []),
      attempt: Map.get(item, :attempt),
      turn_count: Map.get(item, :turn_count),
      last_message: Map.get(item, :last_message),
      error: Map.get(item, :error),
      due_at: Map.get(item, :due_at),
      started_at: Map.get(item, :started_at),
      tokens: Map.get(item, :tokens)
    }
  end

  defp run_ticket(entry, %Run{} = run) do
    %{
      key: entry.slug <> ":" <> run.issue_id,
      lane: entry.slug,
      issue_id: run.issue_id,
      identifier: run.issue_identifier,
      title: run.issue_title,
      tracker_state: run.issue_state,
      status: run.status,
      labels: [],
      url: nil,
      blocked_by: [],
      attempt: run.attempt,
      turn_count: run.turns,
      last_message: nil,
      error: nil,
      due_at: nil,
      started_at: DateTime.to_iso8601(run.started_at),
      tokens: %{input_tokens: run.input_tokens, output_tokens: run.output_tokens, total_tokens: run.input_tokens + run.output_tokens}
    }
  end

  # Merged case-insensitively in category order; the first spelling seen names the group.
  defp tracker_states(entries) do
    entries
    |> Enum.flat_map(fn
      %Entry{settings: %{tracker: tracker, agent: agent}} ->
        Enum.map(tracker.active_states || [], &{&1, "active"}) ++ [{agent.blocked_state, "blocked"}] ++ Enum.map(tracker.terminal_states || [], &{&1, "terminal"})

      _entry ->
        []
    end)
    |> Enum.sort_by(fn {_state, category} -> Map.fetch!(@category_order, category) end)
    |> Enum.uniq_by(fn {state, _category} -> String.downcase(state) end)
  end

  defp same_state?(state, group_state) when is_binary(state), do: String.downcase(state) == String.downcase(group_state)
  defp same_state?(_state, _group_state), do: false
end
```

`String.to_existing_atom/1` is safe here because `@live_statuses` only names the payload keys `:running`, `:blocked`, `:retrying` and `:queued`.

- [ ] **Step 4: Point RunLive and LaneLive at the shared helpers**

`run_live.ex`: add `alias SymphonyElixirWeb.Console`, change `{describe(event.payload)}` to `{Console.describe_event(event.payload)}`, and delete the four `defp describe/1` clauses.

`lane_live.ex`: add `Console` to the `SymphonyElixirWeb` alias, change `external_issue_url(assigns.url)` to `Console.external_url(assigns.url)`, and delete both `defp external_issue_url/1` clauses.

- [ ] **Step 5: Run the tests**

Run: `mix test test/symphony_elixir_web/console_test.exs test/symphony_elixir_web/run_live_test.exs test/symphony_elixir_web/lane_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir_web/console.ex elixir/lib/symphony_elixir_web/live/run_live.ex elixir/lib/symphony_elixir_web/live/lane_live.ex elixir/test/symphony_elixir_web/console_test.exs
git commit -m "feat(web): add console projections for tickets, groups and agent strips"
```

---

### Task 5: Console page (strip, list, routes, styles)

**Files:**
- Create: `elixir/lib/symphony_elixir_web/components/console_components.ex`
- Create: `elixir/lib/symphony_elixir_web/live/console_live.ex`
- Modify: `elixir/lib/symphony_elixir_web/router.ex`, `elixir/lib/symphony_elixir_web/components/layouts.ex`
- Modify: `elixir/priv/static/dashboard.css` (append)
- Modify: `elixir/test/symphony_elixir_web/lanes_live_test.exs` (`"/"` → `"/lanes"`)
- Test: `elixir/test/symphony_elixir_web/console_live_test.exs`

**Interfaces:**
- Consumes: `Console.*` (Task 4), `Presenter.lane_payload/2`, `Runs.list_for_lane/2`, `Runs.for_issue/3`, `Runs.events/1`.
- Produces: `ConsoleComponents.console_path(nav :: map(), overrides :: keyword()) :: String.t()`, where `nav` is `%{lane: String.t() | nil, group: :status | :tracker, attention: boolean(), selected: String.t() | nil}`. Also produces the `ConsoleLive` assigns `nav`, `entries`, `tickets`, `strips`, `groups`, `ticket`, `detail`, `panel`, which Task 6 extends.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule SymphonyElixirWeb.ConsoleLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.{ExecutionProfiles, Lanes, LaneStore, Runs}

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeOrchestrator do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}
    def handle_call(:request_refresh, _from, state), do: {:reply, %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: []}, state}

    def handle_call(message, _from, state) do
      send(state.parent, {:orchestrator_call, message})
      {:reply, state.reply, state}
    end
  end

  setup context do
    {:ok, fake} = FakeOrchestrator.start_link(%{snapshot: snapshot(), parent: self(), reply: Map.get(context, :reply, :ok)})
    previous = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, Keyword.merge(previous, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: fake))
    on_exit(fn -> Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous) end)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    {:ok, profile} = ExecutionProfiles.create(%{name: "Console #{System.unique_integer([:positive])}", workspace_base: Path.join(System.tmp_dir!(), "console-#{System.unique_integer([:positive])}"), worker: %{}})

    {:ok, lane} =
      Lanes.create(%{
        slug: "ops",
        name: "Ops",
        execution_profile_id: profile.id,
        config: %{"tracker" => %{"kind" => "memory", "active_states" => ["Todo", "In Progress"]}, "agent" => %{"max_concurrent_agents" => 2}}
      })

    {:ok, entry} = LaneStore.lookup(lane.id)
    :ok = LaneStore.put_entry(%{entry | enabled: true})
    {:ok, conn: Plug.Test.init_test_session(build_conn(), %{"operator" => true}), lane: lane}
  end

  test "strip, grouped list and history render from lane snapshots", %{conn: conn, lane: lane} do
    {:ok, view, _html} = live(conn, "/?lane=ops")
    assert has_element?(view, "#strip-ops [data-ticket='ops:run-1']", "Cache deps in CI")
    assert has_element?(view, "#strip-ops [data-ticket='ops:blk-1']", "blocked")
    assert has_element?(view, "#strip-ops .console-tile--idle", "1 idle")
    assert has_element?(view, "#console-list [data-group='running'] [data-ticket='ops:run-1']", "In Progress")
    assert has_element?(view, "#console-list [data-group='queued'] [data-ticket='ops:q-1']", "⊘ OPS-1")
    assert has_element?(view, "#console-detail", "Select a ticket")
    assert has_element?(view, "#lane-nav-ops", "1/2")

    issue = %Issue{id: "old-1", identifier: "OPS-9", title: "Old work", state: "Done"}
    :ok = Runs.started(%{lane_id: lane.id, issue: issue, attempt_id: "old-att", attempt: 1})
    :ok = Runs.finished("old-att", "done")
    :ok = Runs.flush()
    send(view.pid, :observability_updated)
    assert has_element?(view, "#console-list [data-group='finished'] [data-ticket='ops:old-1']", "Old work")
  end

  test "tracker grouping, attention filter and selection live in the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops")
    view |> element("#group-tracker") |> render_click()
    assert_patch(view, "/?lane=ops&group=tracker")
    assert has_element?(view, "#console-list [data-group='state:In Progress'] [data-ticket='ops:run-1']", "running")

    view |> element("#attention-toggle") |> render_click()
    assert_patch(view, "/?lane=ops&group=tracker&attention=1")
    refute has_element?(view, "#console-list [data-ticket='ops:run-1']")

    view |> element("#console-list [data-ticket='ops:blk-1']") |> render_click()
    assert_patch(view, "/?lane=ops&group=tracker&attention=1&ticket=ops%3Ablk-1")
    assert has_element?(view, "#console-detail h2", "Rotate deploy key")

    view |> element("#group-status") |> render_click()
    assert_patch(view, "/?lane=ops&attention=1&ticket=ops%3Ablk-1")
  end

  test "the all-lanes view tags rows with their lane and links lane management", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#console-list [data-ticket='ops:run-1'] .console-lane-tag", "ops")
    assert has_element?(view, "a[href='/lanes']", "Manage lanes")
    view |> element("#lane-nav-ops") |> render_click()
    assert_patch(view, "/?lane=ops")
  end

  test "lane cards moved to /lanes", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/lanes")
    assert has_element?(view, "#lane-ops")
  end

  defp snapshot do
    now = DateTime.utc_now()

    %{
      running: [
        %{
          issue_id: "run-1",
          identifier: "OPS-1",
          title: "Cache deps in CI",
          labels: ["ci"],
          attempt_id: "att-1",
          state: "In Progress",
          session_id: "s1",
          turn_count: 3,
          last_codex_event: :notification,
          last_codex_message: nil,
          started_at: now,
          last_codex_timestamp: now,
          codex_input_tokens: 10,
          codex_output_tokens: 2,
          codex_total_tokens: 12
        }
      ],
      blocked: [
        %{
          issue_id: "blk-1",
          identifier: "OPS-2",
          title: "Rotate deploy key",
          labels: [],
          state: "Blocked / Needs Attention",
          error: "approval_required: needs a human",
          session_id: "s2",
          blocked_at: now,
          last_codex_event: :approval_required,
          last_codex_message: nil,
          last_codex_timestamp: now
        }
      ],
      retrying: [%{issue_id: "rty-1", identifier: "OPS-3", title: "Pin OTP", state: "Todo", labels: [], attempt: 2, due_in_ms: 60_000, error: "turn_failed"}],
      queued: [%{issue_id: "q-1", identifier: "OPS-4", title: "Backups", state: "Todo", labels: [], issue_url: nil, priority: nil, blocked_by: ["OPS-1"]}],
      claimed: 0,
      codex_totals: %{},
      rate_limits: nil
    }
  end
end
```

Every lane in `LaneStore` shares the fake orchestrator, including the fixture lane `TestSupport` creates. That is why most tests scope to `?lane=ops` and assert on `ops:`-prefixed keys.

- [ ] **Step 2: Run them and watch them fail**

Run: `mix test test/symphony_elixir_web/console_live_test.exs`
Expected: FAIL (`/` still renders `LanesLive`; there is no `/lanes` route yet).

- [ ] **Step 3: Routes and navigation**

`router.ex`, in `live_session :operator`, replace `live("/", LanesLive, :index)` with:

```elixir
      live("/", ConsoleLive, :index)
      live("/lanes", LanesLive, :index)
```

Keep `/lanes` above `live("/lanes/new", ...)`. The routes do not collide, but reading top-down stays clear.

`layouts.ex`, in `app/1`, replace the two nav links with:

```elixir
        <a class="issue-link" href="/">Console</a>
        <a class="issue-link" href="/lanes">Lanes</a>
        <a class="issue-link" href="/execution-profiles">Execution profiles</a>
```

In `lanes_live_test.exs`, replace every `live(conn, "/")` with `live(conn, "/lanes")`:

```bash
sed -i '' 's|live(conn, "/")|live(conn, "/lanes")|g' elixir/test/symphony_elixir_web/lanes_live_test.exs
```

(`sed -i ''` is the macOS form; on Linux use `sed -i`.) Redirects to `"/"` after deletes elsewhere stay as they are: they now land on the console.

- [ ] **Step 4: Components**

```elixir
defmodule SymphonyElixirWeb.ConsoleComponents do
  @moduledoc "Function components for the operator console."

  use Phoenix.Component

  alias SymphonyElixirWeb.Console

  @doc "Builds a console URL from the current view, applying `overrides` (lane, group, attention, selected)."
  @spec console_path(map(), keyword()) :: String.t()
  def console_path(nav, overrides \\ []) do
    nav = Map.merge(nav, Map.new(overrides))

    query =
      Enum.reject(
        [lane: nav.lane, group: if(nav.group in [:tracker, "tracker"], do: "tracker"), attention: if(nav.attention, do: "1"), ticket: nav.selected],
        fn {_key, value} -> is_nil(value) end
      )

    if query == [], do: "/", else: "/?" <> URI.encode_query(query)
  end

  @spec lane_nav(map()) :: Phoenix.LiveView.Rendered.t()
  def lane_nav(assigns) do
    ~H"""
    <nav class="console-lanes" aria-label="Lanes">
      <.link patch={console_path(@nav, lane: nil)} class="console-lane" aria-current={to_string(is_nil(@nav.lane))}>
        All lanes <span class="console-count">{length(@tickets)}</span>
      </.link>
      <.link
        :for={entry <- @entries}
        id={"lane-nav-#{entry.slug}"}
        patch={console_path(@nav, lane: entry.slug)}
        class="console-lane"
        aria-current={to_string(@nav.lane == entry.slug)}
      >
        <span class={"console-dot console-dot--#{lane_health(entry, @tickets)}"}></span>
        {entry.name}
        <span class="console-backend">{Console.agent_setting(entry, :backend, "codex")}</span>
        <span class="console-count">{count(@tickets, entry.slug, "running")}/{Console.agent_setting(entry, :max_concurrent_agents, 0)}</span>
      </.link>
      <.link
        id="attention-toggle"
        patch={console_path(@nav, attention: not @nav.attention)}
        class="console-lane"
        aria-current={to_string(@nav.attention)}
      >
        Needs attention <span class="console-count">{Enum.count(@tickets, &(&1.status == "blocked"))}</span>
      </.link>
      <a class="console-lane console-lane--manage" href="/lanes">Manage lanes</a>
    </nav>
    """
  end

  @spec strip(map()) :: Phoenix.LiveView.Rendered.t()
  def strip(assigns) do
    ~H"""
    <section class="console-strip" aria-label="Live agents">
      <div :for={{entry, strip} <- @strips} class="console-strip-lane" id={"strip-#{entry.slug}"}>
        <p class="console-strip-head">
          <span class={"console-dot console-dot--#{lane_health(entry, @tickets)}"}></span>
          {entry.name}
          <span class="console-backend">{Console.agent_setting(entry, :backend, "codex")}</span>
        </p>
        <div class="console-tiles">
          <.link
            :for={ticket <- strip.agents}
            patch={console_path(@nav, selected: ticket.key)}
            class={"console-tile console-tile--#{ticket.status}"}
            data-ticket={ticket.key}
          >
            <span class="console-tile-head">
              <span class="mono">{ticket.identifier}</span>
              <span :if={ticket.status == "running"} class="mono muted">T{ticket.turn_count}/{Console.agent_setting(entry, :max_turns, 0)}</span>
              <span :if={ticket.status == "blocked"} class="console-pill console-pill--blocked">blocked</span>
            </span>
            <span class="console-tile-title">{ticket.title || ticket.identifier}</span>
            <span class="console-tile-msg">{ticket.error || ticket.last_message}</span>
          </.link>
          <span :if={strip.idle > 0} class="console-tile console-tile--idle">{strip.idle} idle</span>
          <span :if={not entry.enabled} class="console-tile console-tile--idle">Disabled</span>
        </div>
      </div>
    </section>
    """
  end

  @spec ticket_list(map()) :: Phoenix.LiveView.Rendered.t()
  def ticket_list(assigns) do
    ~H"""
    <div class="console-list" id="console-list" role="listbox" aria-label="Tickets">
      <p :if={@groups == []} class="empty-state">No tickets match.</p>
      <section :for={group <- @groups} class="console-group" data-group={group.key}>
        <h2 class="console-group-head">
          <span class={"console-st console-st--#{group.icon}"}></span>
          {group.label}
          <span :if={group.category} class="console-cat">{group.category}</span>
          <span class="console-count">{length(group.tickets)}</span>
        </h2>
        <p :if={group.tickets == []} class="console-empty">Nothing here.</p>
        <.link
          :for={ticket <- group.tickets}
          patch={console_path(@nav, selected: ticket.key)}
          class="console-row"
          role="option"
          data-ticket={ticket.key}
          aria-selected={to_string(@nav.selected == ticket.key)}
        >
          <span class="console-id mono">{ticket.identifier}</span>
          <span class={"console-st console-st--#{ticket.status}"}></span>
          <span class="console-title">
            {ticket.title || ticket.identifier}
            <span :for={blocker <- ticket.blocked_by} class="console-chip">⊘ {blocker}</span>
          </span>
          <span class="console-meta">
            <span :if={ticket.attempt && ticket.attempt > 1} class="mono muted">attempt {ticket.attempt}</span>
            <span class="console-chip">{if @nav.group == :status, do: ticket.tracker_state, else: ticket.status}</span>
            <span :if={is_nil(@nav.lane)} class="console-lane-tag">{ticket.lane}</span>
          </span>
          <span :if={ticket.status == "running"} class="console-sub">
            <span class="console-live"></span>Turn {ticket.turn_count} · {ticket.last_message}
          </span>
          <span :if={ticket.status in ["blocked", "retrying"]} class="console-sub console-sub--warn">
            {ticket.error}{if ticket.due_at, do: " · next attempt #{ticket.due_at}"}
          </span>
        </.link>
      </section>
    </div>
    """
  end

  defp count(tickets, slug, status), do: Enum.count(tickets, &(&1.lane == slug and &1.status == status))

  defp lane_health(entry, tickets) do
    cond do
      not entry.enabled -> "off"
      count(tickets, entry.slug, "blocked") > 0 -> "warn"
      count(tickets, entry.slug, "running") > 0 -> "on"
      true -> "idle"
    end
  end
end
```

- [ ] **Step 5: The LiveView (read-only for now)**

```elixir
defmodule SymphonyElixirWeb.ConsoleLive do
  @moduledoc "Operator console: each lane's live agents above one ticket list, with a run panel."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  import SymphonyElixirWeb.ConsoleComponents

  alias SymphonyElixir.{LaneStore, Runs}
  alias SymphonyElixirWeb.{Console, ObservabilityPubSub, Presenter}

  @snapshot_timeout_ms 2_000
  @history_limit 20
  @event_limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()
    {:ok, assign(socket, :panel, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    nav = %{
      lane: blank_to_nil(params["lane"]),
      group: if(params["group"] == "tracker", do: :tracker, else: :status),
      attention: params["attention"] == "1",
      selected: blank_to_nil(params["ticket"])
    }

    {:noreply, socket |> assign(nav: nav, panel: nil) |> load()}
  end

  @impl true
  # ponytail: reloads every lane on each broadcast; debounce here if many lanes make this slow.
  def handle_info(:observability_updated, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="console" id="console">
      <aside class="console-side">
        <.lane_nav nav={@nav} entries={@entries} tickets={@tickets} />
      </aside>
      <section class="console-main">
        <header class="console-top">
          <h1 class="console-heading">Tickets</h1>
          <div class="console-seg" role="group" aria-label="Group by">
            <.link id="group-status" patch={console_path(@nav, group: :status)} aria-current={to_string(@nav.group == :status)}>Run status</.link>
            <.link id="group-tracker" patch={console_path(@nav, group: :tracker)} aria-current={to_string(@nav.group == :tracker)}>Tracker state</.link>
          </div>
        </header>
        <.strip nav={@nav} strips={@strips} tickets={@tickets} />
        <.ticket_list nav={@nav} groups={@groups} />
      </section>
      <aside class="console-detail" id="console-detail" aria-label="Ticket detail">
        <p :if={is_nil(@ticket)} class="empty-state">Select a ticket or agent to see its run.</p>
        <div :if={@ticket} class="console-detail-body">
          <p class="console-detail-head">
            <span class="muted">{@ticket.lane}</span> › <strong class="mono">{@ticket.identifier}</strong>
            <a :if={@ticket.url} class="subtle-button" href={@ticket.url} target="_blank" rel="noopener noreferrer">Open in tracker</a>
          </p>
          <h2 class="console-detail-title">{@ticket.title || @ticket.identifier}</h2>
          <p :if={@ticket.labels != []}><span :for={label <- @ticket.labels} class="console-chip">{label}</span></p>
          <dl class="console-kv">
            <dt>Tracker state</dt>
            <dd>{@ticket.tracker_state || "unknown"}</dd>
            <dt>Run status</dt>
            <dd><span class={"console-pill console-pill--#{@ticket.status}"}>{@ticket.status}</span></dd>
            <dt :if={@ticket.turn_count}>Turns</dt>
            <dd :if={@ticket.turn_count}>{@ticket.turn_count} / {Console.agent_setting(@detail.entry, :max_turns, 0)}</dd>
            <dt :if={@ticket.tokens}>Tokens</dt>
            <dd :if={@ticket.tokens} class="mono">{@ticket.tokens.input_tokens} in · {@ticket.tokens.output_tokens} out</dd>
            <dt :if={@ticket.blocked_by != []}>Blocked by</dt>
            <dd :if={@ticket.blocked_by != []}>{Enum.join(@ticket.blocked_by, ", ")}</dd>
          </dl>
          <p :if={@ticket.error} class="error-copy">{@ticket.error}</p>
          <section :if={@ticket.last_message}>
            <h3 class="console-h">Latest agent message</h3>
            <p class="console-msg">{@ticket.last_message}</p>
          </section>
          <section :if={@detail.attempts != []}>
            <h3 class="console-h">Attempts</h3>
            <a :for={run <- @detail.attempts} class="console-chip" href={"/runs/#{run.attempt_id}"}>attempt {run.attempt || 1} · {run.status}</a>
          </section>
          <section :if={@detail.events != []}>
            <h3 class="console-h">Activity</h3>
            <ol class="console-events">
              <li :for={event <- @detail.events}>
                <time class="mono muted" datetime={DateTime.to_iso8601(event.at)}>{Calendar.strftime(event.at, "%H:%M:%S")}</time>
                <span class={"console-k console-k--#{event.kind}"}></span>
                <strong>{event.kind}</strong>
                <span>{Console.describe_event(event.payload)}</span>
              </li>
            </ol>
          </section>
          <footer class="console-actions">
            <a :if={@detail.attempts != []} class="subtle-button" href={"/runs/#{hd(@detail.attempts).attempt_id}"}>Full run log</a>
          </footer>
        </div>
      </aside>
    </section>
    """
  end

  defp load(socket) do
    %{nav: nav} = socket.assigns
    entries = LaneStore.list()
    views = Enum.map(entries, &%{entry: &1, payload: Presenter.lane_payload(&1, @snapshot_timeout_ms), runs: Runs.list_for_lane(&1.lane_id, @history_limit)})
    tickets = Console.tickets(views)
    scoped = Enum.filter(entries, &(is_nil(nav.lane) or &1.slug == nav.lane))
    visible = Enum.filter(tickets, &((is_nil(nav.lane) or &1.lane == nav.lane) and (not nav.attention or &1.status == "blocked")))
    ticket = Enum.find(tickets, &(&1.key == nav.selected))

    assign(socket,
      entries: entries,
      tickets: tickets,
      strips: Enum.map(scoped, &{&1, Console.strip(&1, tickets)}),
      groups: Console.groups(visible, nav.group, scoped),
      ticket: ticket,
      detail: detail(ticket, entries)
    )
  end

  defp detail(nil, _entries), do: nil

  defp detail(ticket, entries) do
    entry = Enum.find(entries, &(&1.slug == ticket.lane))
    attempts = Runs.for_issue(entry.lane_id, ticket.issue_id, @history_limit)

    events =
      case attempts do
        [latest | _] -> latest.id |> Runs.events() |> Enum.take(-@event_limit)
        [] -> []
      end

    %{entry: entry, attempts: attempts, events: events}
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
```

- [ ] **Step 6: Styles** (append to `dashboard.css`; these reuse the existing tokens)

```css
/* Operator console */
.console { display: grid; grid-template-columns: 230px minmax(0, 1fr) 420px; min-height: calc(100vh - 4rem); max-width: 1800px; margin: 0 auto; border: 1px solid var(--line-strong); border-radius: 12px; background: var(--card); overflow: hidden; }
.console-side { border-right: 1px solid var(--line); background: var(--page-soft); padding: 0.75rem 0.5rem; }
.console-lanes { display: grid; gap: 2px; }
.console-lane { display: flex; align-items: center; gap: 0.5rem; padding: 0.4rem 0.5rem; border-radius: 6px; color: var(--ink); text-decoration: none; }
.console-lane:hover { background: var(--card-muted); }
.console-lane[aria-current="true"] { background: var(--page-deep); font-weight: 600; }
.console-lane--manage { margin-top: 0.75rem; color: var(--muted); }
.console-count { margin-left: auto; color: var(--muted); font-family: "SFMono-Regular", Consolas, monospace; font-size: 0.75rem; font-variant-numeric: tabular-nums; }
.console-backend { font-family: "SFMono-Regular", Consolas, monospace; font-size: 0.7rem; border: 1px solid var(--line-strong); border-radius: 4px; padding: 0 0.3rem; color: var(--muted); }
.console-dot { width: 7px; height: 7px; border-radius: 50%; flex: none; background: var(--line-strong); }
.console-dot--on { background: var(--accent); }
.console-dot--warn { background: var(--danger); }
.console-dot--off { background: transparent; border: 1.5px solid var(--muted); }
.console-main { display: flex; flex-direction: column; min-width: 0; }
.console-top { display: flex; align-items: center; gap: 0.75rem; padding: 0.75rem 1rem; border-bottom: 1px solid var(--line); flex-wrap: wrap; }
.console-heading { margin: 0; font-size: 1rem; }
.console-seg { display: inline-flex; border: 1px solid var(--line-strong); border-radius: 7px; overflow: hidden; }
.console-seg a { padding: 0.25rem 0.7rem; font-size: 0.8rem; color: var(--muted); text-decoration: none; }
.console-seg a[aria-current="true"] { background: var(--card-muted); color: var(--ink); font-weight: 600; }
.console-strip { display: flex; gap: 1.1rem; overflow-x: auto; padding: 0.75rem 1rem; border-bottom: 1px solid var(--line); background: var(--page-soft); }
.console-strip-lane { display: grid; gap: 0.4rem; flex: none; }
.console-strip-head { display: flex; align-items: center; gap: 0.4rem; margin: 0; font-size: 0.75rem; color: var(--muted); }
.console-tiles { display: flex; gap: 0.5rem; }
.console-tile { width: 220px; display: grid; gap: 0.25rem; padding: 0.5rem; border: 1px solid var(--line); border-radius: 8px; background: var(--card); color: var(--ink); text-decoration: none; font-size: 0.8rem; }
.console-tile:hover { border-color: var(--line-strong); }
.console-tile--blocked { border-color: var(--danger); }
.console-tile--idle { width: 90px; place-content: center; text-align: center; border-style: dashed; color: var(--muted); background: transparent; }
.console-tile-head { display: flex; justify-content: space-between; gap: 0.4rem; }
.console-tile-title { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.console-tile-msg { color: var(--muted); display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.console-list { overflow: auto; flex: 1; }
.console-group-head { display: flex; align-items: center; gap: 0.5rem; margin: 0; padding: 0.5rem 1rem; font-size: 0.85rem; background: var(--card-muted); border-bottom: 1px solid var(--line); position: sticky; top: 0; }
.console-cat { font-weight: 400; font-size: 0.7rem; border: 1px solid var(--line-strong); border-radius: 4px; padding: 0 0.3rem; color: var(--muted); }
.console-empty { margin: 0; padding: 0.75rem 1rem; color: var(--muted); font-size: 0.8rem; }
.console-row { display: grid; grid-template-columns: 64px 16px minmax(0, 1fr) auto; column-gap: 0.6rem; row-gap: 2px; align-items: center; padding: 0.5rem 1rem; border-bottom: 1px solid var(--line); color: var(--ink); text-decoration: none; }
.console-row:hover { background: var(--page-soft); }
.console-row[aria-selected="true"] { background: var(--accent-soft); }
.console-id { color: var(--muted); font-size: 0.75rem; }
.console-title { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.console-meta { display: flex; gap: 0.4rem; align-items: center; }
.console-sub { grid-column: 2 / -1; font-size: 0.75rem; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.console-sub--warn { color: var(--danger); }
.console-chip { display: inline-flex; gap: 0.25rem; padding: 0 0.4rem; border: 1px solid var(--line-strong); border-radius: 5px; font-size: 0.7rem; color: var(--muted); margin-left: 0.3rem; text-decoration: none; }
.console-lane-tag { font-size: 0.75rem; color: var(--muted); min-width: 60px; text-align: right; }
.console-st { width: 12px; height: 12px; border-radius: 50%; flex: none; border: 2px solid var(--line-strong); }
.console-st--running, .console-st--active { border-color: #d97706; background: conic-gradient(#d97706 0 50%, transparent 0); }
.console-st--blocked, .console-st--failed, .console-st--turns_exhausted { border-color: var(--danger); background: var(--danger); }
.console-st--retrying { border-color: #2563eb; border-style: dashed; }
.console-st--queued { border-style: dotted; }
.console-st--done, .console-st--finished, .console-st--terminal { border-color: var(--accent); background: var(--accent); }
.console-live { display: inline-block; width: 6px; height: 6px; border-radius: 50%; background: #d97706; margin-right: 0.35rem; animation: console-pulse 1.4s infinite; }
@keyframes console-pulse { 50% { opacity: 0.25; } }
@media (prefers-reduced-motion: reduce) { .console-live { animation: none; } }
.console-pill { font-size: 0.7rem; padding: 0 0.45rem; border-radius: 9px; background: var(--card-muted); color: var(--muted); }
.console-pill--running { background: #fef3e2; color: #b45309; }
.console-pill--blocked, .console-pill--failed, .console-pill--turns_exhausted { background: var(--danger-soft); color: var(--danger); }
.console-pill--done { background: var(--accent-soft); color: var(--accent-ink); }
.console-detail { border-left: 1px solid var(--line); overflow: auto; }
.console-detail-body { display: grid; gap: 1rem; padding: 1rem; align-content: start; }
.console-detail-head { display: flex; align-items: center; gap: 0.4rem; margin: 0; }
.console-detail-head .subtle-button { margin-left: auto; }
.console-detail-title { margin: 0; font-size: 1.1rem; text-wrap: balance; }
.console-kv { display: grid; grid-template-columns: 110px minmax(0, 1fr); gap: 0.4rem 0.75rem; margin: 0; font-size: 0.85rem; }
.console-kv dt { color: var(--muted); }
.console-kv dd { margin: 0; overflow-wrap: anywhere; }
.console-h { margin: 0 0 0.4rem; font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
.console-msg { margin: 0; padding: 0.6rem 0.75rem; border-radius: 8px; background: var(--card-muted); white-space: pre-wrap; font-size: 0.85rem; }
.console-events { list-style: none; margin: 0; padding: 0; display: grid; gap: 0.25rem; font-size: 0.8rem; }
.console-events li { display: grid; grid-template-columns: 64px 10px auto minmax(0, 1fr); gap: 0.5rem; align-items: baseline; }
.console-k { width: 7px; height: 7px; border-radius: 50%; background: var(--muted); align-self: center; }
.console-k--turn_started, .console-k--turn_finished { background: var(--accent); }
.console-k--blocked, .console-k--error { background: var(--danger); }
.console-k--agent_message { background: #d97706; }
.console-actions { display: flex; flex-wrap: wrap; gap: 0.5rem; border-top: 1px solid var(--line); padding-top: 0.75rem; }
.console-confirm, .console-reply { display: grid; gap: 0.5rem; width: 100%; }
.console-confirm { border: 1px solid var(--danger); background: var(--danger-soft); border-radius: 8px; padding: 0.75rem; }
.console-reply textarea { width: 100%; min-height: 5rem; border: 1px solid var(--line-strong); border-radius: 8px; padding: 0.5rem; font: inherit; }
@media (max-width: 1250px) { .console { grid-template-columns: 210px minmax(0, 1fr); } .console-detail { grid-column: 1 / -1; border-left: 0; border-top: 1px solid var(--line); } }
@media (max-width: 760px) { .console { grid-template-columns: 1fr; } .console-side { border-right: 0; border-bottom: 1px solid var(--line); } .console-lanes { grid-auto-flow: column; overflow-x: auto; } .console-row { grid-template-columns: 56px 14px minmax(0, 1fr); } .console-meta { grid-column: 2 / -1; } }
```

- [ ] **Step 7: Run the web suite**

Run: `mix test test/symphony_elixir_web`
Expected: PASS. Check `auth_test.exs:72` and `:106`, which hit `/`: they must still pass with the console there. If one asserts lane-card markup, point it at `/lanes`.

- [ ] **Step 8: Look at it once in a browser**

Run the service the way `elixir/README.md` describes (import a lane, `mix symphony serve`), sign in, and open `/`, `/?group=tracker` and a narrow window. Check that the strip scrolls sideways, no text is clipped, and the detail panel stacks under 1250px.

- [ ] **Step 9: Commit**

```bash
git add elixir/lib/symphony_elixir_web/components/console_components.ex elixir/lib/symphony_elixir_web/live/console_live.ex elixir/lib/symphony_elixir_web/router.ex elixir/lib/symphony_elixir_web/components/layouts.ex elixir/priv/static/dashboard.css elixir/test/symphony_elixir_web/console_live_test.exs elixir/test/symphony_elixir_web/lanes_live_test.exs
git commit -m "feat(web): add the operator console at / and move lane cards to /lanes"
```

---

### Task 6: Detail panel activity and actions

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/live/console_live.ex`
- Test: `elixir/test/symphony_elixir_web/console_live_test.exs`

**Interfaces:**
- Consumes: `OperatorActions.stop/2`, `retry_now/2`, `resume/3` (Task 3); `Presenter.orchestrator_for/1`.
- Produces: LiveView events `"panel"` (`%{"panel" => "stop" | "reply"}`), `"cancel"`, `"stop"`, `"retry_now"`, `"approve"`, `"reply"` (`%{"message" => String.t()}`).

- [ ] **Step 1: Write the failing tests** (append inside `ConsoleLiveTest`)

```elixir
  test "the detail panel shows attempts and the latest activity", %{conn: conn, lane: lane} do
    issue = %Issue{id: "run-1", identifier: "OPS-1", title: "Cache deps in CI", state: "In Progress"}
    :ok = Runs.started(%{lane_id: lane.id, issue: issue, attempt_id: "att-1", attempt: 1})
    :ok = Runs.event("att-1", %{event: :notification, message: "Reading make-all.yml"}, %{}, 1)
    :ok = Runs.flush()

    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Arun-1")
    assert has_element?(view, "#console-detail a[href='/runs/att-1']", "Full run log")
    assert has_element?(view, "#console-detail a[href='/runs/att-1']", "attempt 1 · running")
    assert has_element?(view, "#console-detail .console-events", "Reading make-all.yml")
    assert has_element?(view, "#console-detail", "3 / 20")
  end

  test "stop asks for confirmation, then calls the lane orchestrator", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Arun-1")
    view |> element("#console-detail button", "Stop run") |> render_click()
    assert has_element?(view, "#stop-confirm")
    view |> element("#stop-confirm button", "Keep running") |> render_click()
    refute has_element?(view, "#stop-confirm")

    view |> element("#console-detail button", "Stop run") |> render_click()
    view |> element("#stop-confirm button", "Stop run") |> render_click()
    assert_receive {:orchestrator_call, {:operator_stop, "run-1"}}
    assert has_element?(view, "#flash-info", "OPS-1 stopped.")
  end

  @tag reply: {:error, :not_retrying}
  test "a stale action explains why nothing changed", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Arty-1")
    view |> element("#console-detail button", "Retry now") |> render_click()
    assert_receive {:orchestrator_call, {:operator_retry_now, "rty-1"}}
    assert has_element?(view, "#flash-error", "OPS-3 was not changed: it is no longer waiting to retry.")
  end

  test "approve and reply resume a blocked ticket through the tracker", %{conn: conn} do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Ablk-1")

    view |> element("#console-detail button", "Approve") |> render_click()
    assert_receive {:memory_tracker_state_update, "blk-1", "Todo"}
    assert has_element?(view, "#flash-info", "OPS-2 resumed.")

    view |> element("#console-detail button", "Reply to agent") |> render_click()
    view |> element("#reply-form button", "Cancel") |> render_click()
    refute has_element?(view, "#reply-form")

    view |> element("#console-detail button", "Reply to agent") |> render_click()
    view |> form("#reply-form", message: "Palette is in tokens/dark.json") |> render_submit()
    assert_receive {:memory_tracker_comment, "blk-1", "Palette is in tokens/dark.json"}
    assert has_element?(view, "#flash-info", "OPS-2 resumed with your reply.")
  end

  @tag reply: {:error, :unavailable}
  test "unknown tickets show the empty panel and actions need a selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?ticket=ops%3Agone")
    assert has_element?(view, "#console-detail", "Select a ticket")
    assert render_hook(view, "approve", %{}) =~ "Select a ticket first."

    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Arun-1")
    view |> element("#console-detail button", "Stop run") |> render_click()
    view |> element("#stop-confirm button", "Stop run") |> render_click()
    assert has_element?(view, "#flash-error", "OPS-1 was not changed: the lane is not running.")
  end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mix test test/symphony_elixir_web/console_live_test.exs`
Expected: the activity test passes (Task 5 already renders it); the action tests FAIL because the buttons are missing.

- [ ] **Step 3: Add the actions**

Add `OperatorActions` to the `SymphonyElixir` alias in `console_live.ex`. Replace the `<footer class="console-actions">…</footer>` block with:

```heex
          <footer class="console-actions">
            <div :if={@panel == "stop"} class="console-confirm" id="stop-confirm">
              <p>
                <strong>Stop this run?</strong>
                The agent session ends now and the workspace is kept. The ticket stays in “{@ticket.tracker_state}” and is dispatched again on the next poll unless you move it.
              </p>
              <p>
                <button type="button" class="subtle-button" phx-click="cancel">Keep running</button>
                <button type="button" class="danger-button" phx-click="stop">Stop run</button>
              </p>
            </div>
            <form :if={@panel == "reply"} id="reply-form" class="console-reply" phx-submit="reply">
              <label for="reply-message">Message to the agent. It is posted on the ticket, and the ticket moves back to an active state.</label>
              <textarea id="reply-message" name="message" required></textarea>
              <p>
                <button type="button" class="subtle-button" phx-click="cancel">Cancel</button>
                <button type="submit">Send and resume</button>
              </p>
            </form>
            <button :if={is_nil(@panel) and @ticket.status == "blocked"} type="button" phx-click="approve">Approve &amp; resume</button>
            <button :if={is_nil(@panel) and @ticket.status == "blocked"} type="button" class="subtle-button" phx-click="panel" phx-value-panel="reply">Reply to agent</button>
            <button :if={is_nil(@panel) and @ticket.status == "retrying"} type="button" phx-click="retry_now">Retry now</button>
            <button :if={is_nil(@panel) and @ticket.status == "running"} type="button" class="danger-button" phx-click="panel" phx-value-panel="stop">Stop run</button>
            <a :if={is_nil(@panel) and @detail.attempts != []} class="subtle-button" href={"/runs/#{hd(@detail.attempts).attempt_id}"}>Full run log</a>
          </footer>
```

Add the event handlers after `handle_info/2`:

```elixir
  @impl true
  def handle_event("panel", %{"panel" => panel}, socket) when panel in ["stop", "reply"], do: {:noreply, assign(socket, :panel, panel)}
  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :panel, nil)}
  def handle_event("stop", _params, socket), do: act(socket, "stopped", &OperatorActions.stop/2)
  def handle_event("retry_now", _params, socket), do: act(socket, "dispatched", &OperatorActions.retry_now/2)
  def handle_event("approve", _params, socket), do: act(socket, "resumed", &OperatorActions.resume(&1, &2, nil))
  def handle_event("reply", %{"message" => message}, socket), do: act(socket, "resumed with your reply", &OperatorActions.resume(&1, &2, message))
```

And the private helpers:

```elixir
  defp act(%{assigns: %{ticket: %{} = ticket, detail: %{entry: entry}}} = socket, verb, action) do
    socket =
      case action.(Presenter.orchestrator_for(entry), ticket.issue_id) do
        :ok -> put_flash(socket, :info, "#{ticket.identifier} #{verb}.")
        {:error, reason} -> put_flash(socket, :error, "#{ticket.identifier} was not changed: #{reason_text(reason)}.")
      end

    {:noreply, socket |> assign(:panel, nil) |> load()}
  end

  defp act(socket, _verb, _action), do: {:noreply, put_flash(socket, :error, "Select a ticket first.")}

  defp reason_text(:not_running), do: "its run already ended"
  defp reason_text(:not_retrying), do: "it is no longer waiting to retry"
  defp reason_text(:unavailable), do: "the lane is not running"
  defp reason_text(:no_active_state), do: "the lane has no active state to move it to"
  defp reason_text(reason), do: "the tracker returned #{inspect(reason)}"
```

`Presenter.orchestrator_for/1` also runs `LaneContext.put/1`, which `OperatorActions.resume/3` needs before it reads `Config.settings!/0`.

- [ ] **Step 4: Cover the last reason clauses**

`reason_text(:not_running)`, `(:no_active_state)` and the fallback are not reached by the tests above. Add:

```elixir
  @tag reply: {:error, :not_running}
  test "stopping a finished run says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Arun-1")
    view |> element("#console-detail button", "Stop run") |> render_click()
    view |> element("#stop-confirm button", "Stop run") |> render_click()
    assert has_element?(view, "#flash-error", "its run already ended")
  end

  test "resume failures name the cause", %{conn: conn} do
    SymphonyElixir.Tracker.Memory.fail(:update_issue_state)
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Ablk-1")
    view |> element("#console-detail button", "Approve") |> render_click()
    assert has_element?(view, "#flash-error", "the tracker returned {:memory_tracker_failed, :update_issue_state}")
  end

  test "a lane without another active state cannot resume", %{conn: conn, lane: lane} do
    {:ok, _} = Lanes.update(lane, %{config: %{"tracker" => %{"kind" => "memory", "active_states" => ["Blocked / Needs Attention"]}}})
    {:ok, entry} = LaneStore.lookup(lane.id)
    :ok = LaneStore.put_entry(%{entry | enabled: true})
    {:ok, view, _html} = live(conn, "/?lane=ops&ticket=ops%3Ablk-1")
    view |> element("#console-detail button", "Approve") |> render_click()
    assert has_element?(view, "#flash-error", "the lane has no active state to move it to")
  end
```

`Lanes.update/2` republishes the lane from its stored (disabled) row, which is why the test marks the entry enabled again.

- [ ] **Step 5: Run the web suite**

Run: `mix test test/symphony_elixir_web`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir_web/live/console_live.ex elixir/test/symphony_elixir_web/console_live_test.exs
git commit -m "feat(web): add stop, retry, approve and reply to the console detail panel"
```

---

### Task 7: Docs and the full gate

**Files:**
- Modify: `SPEC.md` (13.7.1, 13.7.2)
- Modify: `README.md:43`
- Modify: `elixir/README.md:1117-1128` (route table)

- [ ] **Step 1: SPEC 13.7.1**

Replace the first bullet of 13.7.1 with:

```markdown
- Host the operator console at `/`: live agents per lane, one ticket list grouped by run status or
  tracker state, and a run detail panel. Host the lane list at `/lanes`, execution profiles at
  `/execution-profiles` with creation at `/execution-profiles/new`, per-lane creation at
  `/lanes/new`, per-lane runtime at `/lanes/:slug`, editing at `/lanes/:slug/edit`, versions at
  `/lanes/:slug/versions`, attempt details at `/runs/:attempt_id`, and login at `/login`.
- The console MAY offer operator actions: stop a running attempt (recorded as `stopped`, claim
  released, workspace kept), run a pending retry immediately, and resume a blocked ticket by
  optionally commenting and moving it to the first active state other than the blocked state,
  through the tracker adapter. Resuming MUST NOT bypass normal reconciliation; the next attempt is
  dispatched by the usual poll.
```

- [ ] **Step 2: SPEC 13.7.2**

Under `GET /api/v1/state`, after the sentence about each lane element, add:

```markdown
  - Implementations MAY add a `queued` list: the last poll's candidates that are not running,
    claimed, blocked or retrying, in dispatch order, with blocker identifiers. Live entries MAY carry
    the ticket `title` and `labels`.
```

- [ ] **Step 3: READMEs**

`README.md:43`: change to `Open <http://localhost:4000>, sign in with the operator token, and enable \`main\` from **Lanes**. The console at \`/\` then shows its agents and tickets.`

`elixir/README.md`, route table: replace the `/` row and add `/lanes`:

```markdown
| `/` | Operator console: live agents per lane, tickets by run status or tracker state, run detail, Stop / Retry now / Approve / Reply |
| `/lanes` | Lane list, health, enable/disable controls |
```

Add one sentence below the table: `Approve and Reply move a blocked ticket back to the lane's first non-blocked active state through the tracker (Reply posts a comment first); the next attempt sees the comment only if its prompt or tools read comments.`

- [ ] **Step 4: The full gate**

Run (from `elixir/`): `make all`
Expected: format check, `specs.check`, `credo --strict`, 100% coverage and dialyzer all pass. If coverage names an uncovered line, add a test for it in the owning task's test file; do not extend the ignore list.

- [ ] **Step 5: Commit**

```bash
git add SPEC.md README.md elixir/README.md
git commit -m "docs: describe the operator console and its actions"
```
