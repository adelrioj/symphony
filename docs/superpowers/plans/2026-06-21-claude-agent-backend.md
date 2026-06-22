# Per-stage Claude Agent Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Symphony select codex *or* `claude -p` as a first-class agent backend per Linear issue state, with the Claude path reaching full parity (live tokens, blocked detection, `linear_graphql` access).

**Architecture:** A `SymphonyElixir.Agent` behaviour with three session-aware callbacks (`start_session/2`, `run_turn/4`, `stop_session/1`) — matching the existing `Codex.AppServer` shape — behind which `Agent.Codex` (wraps today's AppServer, behavior-preserving) and `Agent.Claude` (launches `claude -p --output-format stream-json`) live. The orchestrator resolves the backend at dispatch (before claim); `AgentRunner` owns the multi-turn continuation loop and the blocked-state Linear writes. Claude gets `linear_graphql` via a standalone MCP server (`symphony --linear-mcp --workflow <abs>`) reusing the stateless `Codex.DynamicTool` logic.

**Tech Stack:** Elixir 1.19 / OTP 28, Ecto embedded schemas (config), Ports (`Port.open`), JSON (`Jason`), the Codex app-server JSON-RPC client, Claude Code CLI (`claude -p`), MCP stdio.

## Global Constraints

- Run all `mix` commands from `elixir/`. Toolchain pinned via `mise`; prefix `mise exec --` if not in a mise shell.
- Every public function (`def`) in `elixir/lib/` needs an adjacent `@spec`. `defp`/`@impl` exempt. Enforced by `mix specs.check`.
- Coverage threshold is **100%** (`mix test --cover`). Add tests, don't expand `mix.exs` `ignore_modules`.
- `mix format` line length is **200**. Run `mix format` before every commit.
- Config access goes through `SymphonyElixir.Config` only — never ad-hoc env reads.
- Logging follows `elixir/docs/logging.md`: include `issue_id` + `issue_identifier` for issue events and `session_id` for agent lifecycle events.
- The codex path must stay **behavior-preserving**: existing tests green, orchestrator message shapes unchanged.
- Source of truth: `docs/superpowers/specs/2026-06-21-claude-agent-backend-design.md`.
- Full quality gate before handoff: `make all` (setup, build, fmt-check, lint, coverage, dialyzer).

> **Decision (refines spec "AgentRunner translates `%Agent.Event{}`"):** Both adapters call the `on_message` callback with the **existing orchestrator update map** shape `%{event: atom, timestamp: integer, session_id: String.t() | nil, usage: %{input_tokens: int, output_tokens: int, total_tokens: int}}`. `Agent.Codex` passes the codex-native maps through unchanged (zero codex behavior change); `Agent.Claude` builds that map from an adapter-internal `%Agent.Event{}`. The orchestrator handler (`orchestrator.ex:159`) and codex path are untouched.

---

### Task 1: `Agent` behaviour + `Result` + `Event` structs

**Files:**
- Create: `elixir/lib/symphony_elixir/agent.ex`
- Create: `elixir/lib/symphony_elixir/agent/result.ex`
- Create: `elixir/lib/symphony_elixir/agent/event.ex`
- Test: `elixir/test/symphony_elixir/agent/result_test.exs`
- Test: `elixir/test/symphony_elixir/agent/event_test.exs`

**Interfaces:**
- Produces:
  - `SymphonyElixir.Agent` behaviour with `@callback start_session(workspace :: Path.t(), opts :: keyword()) :: {:ok, term()} | {:error, term()}`, `@callback run_turn(session :: term(), prompt :: String.t(), issue :: map(), opts :: keyword()) :: {:ok, SymphonyElixir.Agent.Result.t()} | {:error, term()}`, `@callback stop_session(session :: term()) :: :ok`.
  - `SymphonyElixir.Agent.Result.t()` struct: `status` (`:done | :blocked`), `session_id` (`String.t() | nil`), `tokens` (`%{input: non_neg_integer, output: non_neg_integer, total: non_neg_integer}`), `seconds_running` (`non_neg_integer`), `summary` (`String.t() | nil`), `blocked_action` (`String.t() | nil`).
  - `SymphonyElixir.Agent.Result.new/1` building a struct from a keyword/map with token defaults of 0.
  - `SymphonyElixir.Agent.Event.t()` struct: `kind` (`:session_started | :usage_updated | :blocked | :completed | :error`), `session_id`, `tokens` (`map | nil`), `seconds_running` (`non_neg_integer | nil`), `detail` (`map`).
  - `SymphonyElixir.Agent.Event.to_worker_update/1` converting an event to the orchestrator update map `%{event:, timestamp:, session_id:, usage:}` (timestamp via `System.monotonic_time(:millisecond)`).

- [ ] **Step 1: Write the failing test for `Result.new/1`**

```elixir
# elixir/test/symphony_elixir/agent/result_test.exs
defmodule SymphonyElixir.Agent.ResultTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Agent.Result

  test "new/1 fills token defaults and required fields" do
    result = Result.new(status: :done, session_id: "t-1", seconds_running: 5)

    assert result.status == :done
    assert result.session_id == "t-1"
    assert result.seconds_running == 5
    assert result.tokens == %{input: 0, output: 0, total: 0}
    assert result.summary == nil
    assert result.blocked_action == nil
  end

  test "new/1 keeps a blocked_action for blocked results" do
    result = Result.new(status: :blocked, blocked_action: "approve shell write", summary: "needs approval")

    assert result.status == :blocked
    assert result.blocked_action == "approve shell write"
    assert result.summary == "needs approval"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/symphony_elixir/agent/result_test.exs`
Expected: FAIL — module `SymphonyElixir.Agent.Result` is not available.

- [ ] **Step 3: Implement `Agent.Result`**

```elixir
# elixir/lib/symphony_elixir/agent/result.ex
defmodule SymphonyElixir.Agent.Result do
  @moduledoc """
  Normalized outcome of a single agent turn, backend-agnostic.
  """

  @enforce_keys [:status]
  defstruct status: nil,
            session_id: nil,
            tokens: %{input: 0, output: 0, total: 0},
            seconds_running: 0,
            summary: nil,
            blocked_action: nil

  @type t :: %__MODULE__{
          status: :done | :blocked,
          session_id: String.t() | nil,
          tokens: %{input: non_neg_integer(), output: non_neg_integer(), total: non_neg_integer()},
          seconds_running: non_neg_integer(),
          summary: String.t() | nil,
          blocked_action: String.t() | nil
        }

  @spec new(keyword() | map()) :: t()
  def new(fields) do
    attrs = Map.new(fields)
    tokens = Map.get(attrs, :tokens) || %{input: 0, output: 0, total: 0}

    %__MODULE__{
      status: Map.fetch!(attrs, :status),
      session_id: Map.get(attrs, :session_id),
      tokens: Map.merge(%{input: 0, output: 0, total: 0}, tokens),
      seconds_running: Map.get(attrs, :seconds_running, 0),
      summary: Map.get(attrs, :summary),
      blocked_action: Map.get(attrs, :blocked_action)
    }
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- mix test test/symphony_elixir/agent/result_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the failing test for `Event.to_worker_update/1`**

```elixir
# elixir/test/symphony_elixir/agent/event_test.exs
defmodule SymphonyElixir.Agent.EventTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Agent.Event

  test "to_worker_update/1 maps tokens to codex-style usage keys" do
    event = %Event{
      kind: :usage_updated,
      session_id: "t-1",
      tokens: %{input: 3, output: 5, total: 8},
      seconds_running: 2,
      detail: %{}
    }

    update = Event.to_worker_update(event)

    assert update.event == :usage_updated
    assert update.session_id == "t-1"
    assert update.usage == %{input_tokens: 3, output_tokens: 5, total_tokens: 8}
    assert is_integer(update.timestamp)
  end

  test "to_worker_update/1 omits usage when tokens are nil" do
    event = %Event{kind: :session_started, session_id: "t-1", tokens: nil, seconds_running: nil, detail: %{}}

    update = Event.to_worker_update(event)

    assert update.event == :session_started
    assert update.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end
end
```

- [ ] **Step 6: Run it to verify it fails**

Run: `mise exec -- mix test test/symphony_elixir/agent/event_test.exs`
Expected: FAIL — `SymphonyElixir.Agent.Event` not available.

- [ ] **Step 7: Implement `Agent.Event`**

```elixir
# elixir/lib/symphony_elixir/agent/event.ex
defmodule SymphonyElixir.Agent.Event do
  @moduledoc """
  Adapter-internal normalized progress event. Adapters build these, then convert
  to the orchestrator's existing worker-update map via `to_worker_update/1`.
  """

  @enforce_keys [:kind]
  defstruct kind: nil, session_id: nil, tokens: nil, seconds_running: nil, detail: %{}

  @type t :: %__MODULE__{
          kind: :session_started | :usage_updated | :blocked | :completed | :error,
          session_id: String.t() | nil,
          tokens: %{input: non_neg_integer(), output: non_neg_integer(), total: non_neg_integer()} | nil,
          seconds_running: non_neg_integer() | nil,
          detail: map()
        }

  @spec to_worker_update(t()) :: %{
          event: atom(),
          timestamp: integer(),
          session_id: String.t() | nil,
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer(), total_tokens: non_neg_integer()}
        }
  def to_worker_update(%__MODULE__{} = event) do
    tokens = event.tokens || %{input: 0, output: 0, total: 0}

    %{
      event: event.kind,
      timestamp: System.monotonic_time(:millisecond),
      session_id: event.session_id,
      usage: %{
        input_tokens: Map.get(tokens, :input, 0),
        output_tokens: Map.get(tokens, :output, 0),
        total_tokens: Map.get(tokens, :total, 0)
      }
    }
  end
end
```

- [ ] **Step 8: Implement the `Agent` behaviour**

```elixir
# elixir/lib/symphony_elixir/agent.ex
defmodule SymphonyElixir.Agent do
  @moduledoc """
  Behaviour for a coding-agent backend. Session-aware to match the existing
  `Codex.AppServer` shape; `AgentRunner` owns the multi-turn continuation loop.
  """

  alias SymphonyElixir.Agent.Result

  @type session :: term()
  @type on_message :: (SymphonyElixir.Agent.Event.t() -> any())

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @callback run_turn(session :: session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, Result.t()} | {:error, term()}

  @callback stop_session(session :: session()) :: :ok

  @doc """
  Resolve a backend module name to its adapter module.
  """
  @spec module_for(String.t()) :: {:ok, module()} | {:error, {:invalid_agent_backend, String.t()}}
  def module_for("codex"), do: {:ok, SymphonyElixir.Agent.Codex}
  def module_for("claude"), do: {:ok, SymphonyElixir.Agent.Claude}
  def module_for(other), do: {:error, {:invalid_agent_backend, other}}
end
```

- [ ] **Step 9: Run the agent tests + format**

Run: `mise exec -- mix test test/symphony_elixir/agent/ && mise exec -- mix format`
Expected: PASS. (`module_for/1` is covered indirectly in Task 3/5 selection tests; if `mix test --cover` later flags the `module_for("claude")` clause before Task 7 exists, add a direct unit test asserting `{:ok, SymphonyElixir.Agent.Claude}`.)

- [ ] **Step 10: Commit**

```bash
cd elixir && git add lib/symphony_elixir/agent.ex lib/symphony_elixir/agent/ test/symphony_elixir/agent/
git commit -m "feat(agent): add Agent behaviour, Result and Event structs"
```

---

### Task 2: `Agent.Codex` adapter (behavior-preserving wrap)

**Files:**
- Create: `elixir/lib/symphony_elixir/agent/codex.ex`
- Test: `elixir/test/symphony_elixir/agent/codex_test.exs`

**Interfaces:**
- Consumes: `SymphonyElixir.Codex.AppServer.start_session/2`, `run_turn/4` (returns `{:ok, %{result: map, session_id: String.t(), thread_id: _, turn_id: _}}`), `stop_session/1`; `SymphonyElixir.Agent.Result`.
- Produces: `SymphonyElixir.Agent.Codex` implementing `SymphonyElixir.Agent`. `run_turn/4` returns `{:ok, %Result{status: :done, session_id: <id>, tokens: <from result>, summary: <assistant text>}}` or `{:error, reason}`. It passes `opts[:on_message]` straight through to `AppServer.run_turn` (codex keeps emitting its native update maps).

- [ ] **Step 1: Write the failing test (mapping a codex turn result to `:done`)**

```elixir
# elixir/test/symphony_elixir/agent/codex_test.exs
defmodule SymphonyElixir.Agent.CodexTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Agent.Codex
  alias SymphonyElixir.Agent.Result

  test "to_result/1 maps a codex turn map to a done Result" do
    turn = %{
      result: %{"usage" => %{"input_tokens" => 4, "output_tokens" => 6, "total_tokens" => 10}, "summary" => "did the thing"},
      session_id: "thread-1-turn-1",
      thread_id: "thread-1",
      turn_id: "turn-1"
    }

    assert {:ok, %Result{} = result} = Codex.to_result(turn)
    assert result.status == :done
    assert result.session_id == "thread-1-turn-1"
    assert result.tokens == %{input: 4, output: 6, total: 10}
    assert result.summary == "did the thing"
  end

  test "to_result/1 defaults tokens to zero when usage absent" do
    assert {:ok, %Result{tokens: %{input: 0, output: 0, total: 0}}} =
             Codex.to_result(%{result: %{}, session_id: "s", thread_id: "t", turn_id: "u"})
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/symphony_elixir/agent/codex_test.exs`
Expected: FAIL — `SymphonyElixir.Agent.Codex` not available.

- [ ] **Step 3: Implement `Agent.Codex`**

```elixir
# elixir/lib/symphony_elixir/agent/codex.ex
defmodule SymphonyElixir.Agent.Codex do
  @moduledoc """
  Agent backend that drives the Codex app-server. Thin wrapper over
  `Codex.AppServer` that normalizes turn results to `Agent.Result`. Codex keeps
  emitting its native worker-update maps via `opts[:on_message]`, so the codex
  path is behavior-preserving.
  """

  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Agent.Result
  alias SymphonyElixir.Codex.AppServer

  @impl true
  def start_session(workspace, opts) do
    AppServer.start_session(workspace, Keyword.take(opts, [:worker_host]))
  end

  @impl true
  def run_turn(session, prompt, issue, opts) do
    on_message = Keyword.get(opts, :on_message)

    run_opts =
      case on_message do
        nil -> []
        handler when is_function(handler, 1) -> [on_message: handler]
      end

    case AppServer.run_turn(session, prompt, issue, run_opts) do
      {:ok, turn} -> to_result(turn)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def stop_session(session) do
    AppServer.stop_session(session)
  end

  @doc false
  @spec to_result(map()) :: {:ok, Result.t()}
  def to_result(turn) do
    result_map = Map.get(turn, :result, %{})
    usage = Map.get(result_map, "usage", %{})

    {:ok,
     Result.new(
       status: :done,
       session_id: Map.get(turn, :session_id),
       tokens: %{
         input: Map.get(usage, "input_tokens", 0),
         output: Map.get(usage, "output_tokens", 0),
         total: Map.get(usage, "total_tokens", 0)
       },
       summary: Map.get(result_map, "summary")
     )}
  end
end
```

> **Note:** `opts[:on_message]` here receives the codex-native handler from `AgentRunner` (see Task 4); for codex it is the existing message handler, so no translation happens. Confirm the real `AppServer.run_turn` result map keys (`"usage"`, `"summary"`) against `elixir/lib/symphony_elixir/codex/app_server.ex` during implementation; if the codex `result` payload nests usage differently, adjust `to_result/1` and its test together.

- [ ] **Step 4: Run the test + format**

Run: `mise exec -- mix test test/symphony_elixir/agent/codex_test.exs && mise exec -- mix format`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/agent/codex.ex test/symphony_elixir/agent/codex_test.exs
git commit -m "feat(agent): add behavior-preserving Agent.Codex adapter"
```

---

### Task 3: Config — `agent.backend*`, `claude.*`, and `agent_backend_for_state/1`

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex` (Agent module ~line 128; add `Claude` module; top-level embeds ~line 270-279)
- Modify: `elixir/lib/symphony_elixir/config.ex` (add `agent_backend_for_state/1`)
- Test: `elixir/test/symphony_elixir/config_test.exs` (extend) or `elixir/test/symphony_elixir/config/schema_test.exs`

**Interfaces:**
- Consumes: existing `Schema.normalize_issue_state/1`, `Config.settings!/0`.
- Produces:
  - `settings.agent.backend :: String.t()` (default `"codex"`), `settings.agent.backend_by_state :: map()` (default `%{}`, keys normalized), `settings.agent.blocked_state :: String.t()` (default `"Blocked / Needs Attention"`).
  - `settings.claude` struct: `command` (default `"claude"`), `args` (`[String.t()]`, default `[]`), `linear_mcp_command` (`String.t() | nil`), `linear_mcp_args` (`[String.t()]`, default `[]`), `allowed_tools` (`[String.t()] | nil`).
  - `Config.agent_backend_for_state/1 :: ({:ok, "codex" | "claude"} | {:error, {:invalid_agent_backend, state :: String.t(), value :: String.t()}})`.

- [ ] **Step 1: Write the failing test for `agent_backend_for_state/1`**

```elixir
# add to elixir/test/symphony_elixir/config_test.exs (inside the existing module)
describe "agent_backend_for_state/1" do
  test "returns the global default when no per-state override" do
    write_workflow!("""
    ---
    tracker: {kind: memory}
    agent: {backend: codex}
    ---
    body
    """)

    assert SymphonyElixir.Config.agent_backend_for_state("Implemented") == {:ok, "codex"}
  end

  test "per-state override wins and is case/space-insensitive" do
    write_workflow!("""
    ---
    tracker: {kind: memory}
    agent:
      backend: codex
      backend_by_state: {"implemented": claude}
    ---
    body
    """)

    assert SymphonyElixir.Config.agent_backend_for_state("  Implemented ") == {:ok, "claude"}
  end

  test "unknown backend value returns an invalid_agent_backend error" do
    write_workflow!("""
    ---
    tracker: {kind: memory}
    agent:
      backend: codex
      backend_by_state: {"implemented": gemini}
    ---
    body
    """)

    assert SymphonyElixir.Config.agent_backend_for_state("Implemented") ==
             {:error, {:invalid_agent_backend, "Implemented", "gemini"}}
  end
end
```

> `write_workflow!/1` is the existing test helper that writes a temp `WORKFLOW.md` and points `Workflow` at it. If the suite uses a different helper name, match the existing pattern in `config_test.exs`.

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/symphony_elixir/config_test.exs`
Expected: FAIL — `agent_backend_for_state/1` undefined (and schema fields missing).

- [ ] **Step 3: Add the new `Agent` schema fields**

In `elixir/lib/symphony_elixir/config/schema.ex`, the `Agent` `embedded_schema` (currently lines 136-141) becomes:

```elixir
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
      field(:backend, :string, default: "codex")
      field(:backend_by_state, :map, default: %{})
      field(:blocked_state, :string, default: "Blocked / Needs Attention")
    end
```

And extend its `changeset/2` cast list to include `:backend, :backend_by_state, :blocked_state`, normalizing the map keys the same way `max_concurrent_agents_by_state` is normalized (reuse `Schema.normalize_state_limits/1`'s key-normalization or add `normalize_state_backends/1` mirroring it — keys via `normalize_issue_state/1`, values passed through as strings). Do **not** enumerate-validate values (structural only).

- [ ] **Step 4: Add the `Claude` schema module + top-level embed**

Add after the `Codex` module in `schema.ex`:

```elixir
  defmodule Claude do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "claude")
      field(:args, {:array, :string}, default: [])
      field(:linear_mcp_command, :string)
      field(:linear_mcp_args, {:array, :string}, default: [])
      field(:allowed_tools, {:array, :string})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      cast(schema, attrs, [:command, :args, :linear_mcp_command, :linear_mcp_args, :allowed_tools], empty_values: [])
    end
  end
```

Add to the top-level `embedded_schema` (after the `codex` embed, line ~276):

```elixir
    embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
```

And add `:claude` to the top-level `cast_embed` list wherever the other embeds are cast (mirror the `codex` embed handling in the top-level `changeset/2`).

- [ ] **Step 5: Implement `Config.agent_backend_for_state/1`**

```elixir
# elixir/lib/symphony_elixir/config.ex
  @spec agent_backend_for_state(term()) ::
          {:ok, String.t()} | {:error, {:invalid_agent_backend, String.t(), String.t()}}
  def agent_backend_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    value =
      Map.get(
        config.agent.backend_by_state,
        Schema.normalize_issue_state(state_name),
        config.agent.backend
      )

    case value do
      backend when backend in ["codex", "claude"] -> {:ok, backend}
      other -> {:error, {:invalid_agent_backend, state_name, to_string(other)}}
    end
  end

  def agent_backend_for_state(_state_name), do: {:ok, settings!().agent.backend}
```

Ensure `Schema.normalize_issue_state/1` is public (it is used by `max_concurrent_agents_for_state/1` already).

- [ ] **Step 6: Run the test + format**

Run: `mise exec -- mix test test/symphony_elixir/config_test.exs && mise exec -- mix format`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd elixir && git add lib/symphony_elixir/config/schema.ex lib/symphony_elixir/config.ex test/symphony_elixir/config_test.exs
git commit -m "feat(config): add agent.backend* and claude.* settings + agent_backend_for_state/1"
```

---

### Task 4: Generalize `AgentRunner` over the `Agent` behaviour

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Test: `elixir/test/symphony_elixir/agent_runner_test.exs` (extend)

**Interfaces:**
- Consumes: `SymphonyElixir.Agent` behaviour modules (`Agent.Codex` from Task 2); `opts[:backend_module]` injected by the orchestrator (Task 5).
- Produces: `AgentRunner.run/3` accepting `opts[:backend_module]` (default `SymphonyElixir.Agent.Codex`); the turn loop calls `backend.start_session/2`, `backend.run_turn/4`, `backend.stop_session/1`. `run_turn` now returns `{:ok, %Agent.Result{}}`; the loop inspects `result.status` (Task 9 adds blocked handling — for this task, `:done` continues/stops as today; `:blocked` is treated as run-complete and returns `:ok`).

- [ ] **Step 1: Write the failing test (backend module is honored, loop calls the behaviour)**

```elixir
# add to elixir/test/symphony_elixir/agent_runner_test.exs
defmodule SymphonyElixir.AgentRunnerStubBackend do
  @behaviour SymphonyElixir.Agent
  alias SymphonyElixir.Agent.Result

  @impl true
  def start_session(_workspace, _opts), do: {:ok, %{turns: 0}}

  @impl true
  def run_turn(_session, _prompt, _issue, opts) do
    if pid = opts[:test_pid], do: send(pid, :stub_turn_ran)
    {:ok, Result.new(status: :done, session_id: "stub-1")}
  end

  @impl true
  def stop_session(_session), do: :ok
end

test "run/3 drives the injected backend module" do
  # Arrange an issue whose refreshed state is terminal so the loop runs exactly one turn.
  issue = build_issue(state: "Done")

  SymphonyElixir.AgentRunner.run(
    issue,
    nil,
    backend_module: SymphonyElixir.AgentRunnerStubBackend,
    worker_host: nil,
    issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
    test_pid: self()
  )

  assert_received :stub_turn_ran
end
```

> Reuse the test's existing issue-builder/workspace stubbing. If `AgentRunner.run` requires a real workspace, follow the existing test setup (the suite already exercises `run_codex_turns` via `continue_with_issue_for_test`/stubs — mirror that). The key assertion is that `run_turn` of the injected module is invoked.

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/symphony_elixir/agent_runner_test.exs`
Expected: FAIL — `backend_module` is ignored / `AppServer` still hard-wired.

- [ ] **Step 3: Generalize the loop**

In `agent_runner.ex`, replace the direct `AppServer` calls in `run_codex_turns/5` and `do_run_codex_turns/8` with the injected backend. Change `run_codex_turns/5`:

```elixir
  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    backend = Keyword.get(opts, :backend_module, SymphonyElixir.Agent.Codex)

    with {:ok, session} <- backend.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_agent_turns(backend, session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        backend.stop_session(session)
      end
    end
  end
```

Rename `do_run_codex_turns/8` to `do_run_agent_turns/9` (adds the leading `backend` arg) and replace the `AppServer.run_turn(...)` call with:

```elixir
    with {:ok, %SymphonyElixir.Agent.Result{} = result} <-
           backend.run_turn(session, prompt, issue,
             on_message: agent_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{result.session_id} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      handle_turn_result(backend, session, result, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns)
    end
```

Add a `handle_turn_result/11` that, for `:done`, runs the existing `continue_with_issue?/2` branching (continue/stop) and recurses via `do_run_agent_turns/9`; for `:blocked`, returns `{:blocked, result}` (Task 9 consumes this). For this task, map `{:blocked, _}` to `:ok` so the run completes without raising:

```elixir
  defp handle_turn_result(backend, session, %{status: :done}, workspace, issue, recipient, opts, fetcher, turn_number, max_turns) do
    case continue_with_issue?(issue, fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        do_run_agent_turns(backend, session, workspace, refreshed_issue, recipient, opts, fetcher, turn_number + 1, max_turns)

      {:continue, _refreshed_issue} ->
        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_turn_result(_backend, _session, %{status: :blocked} = result, _workspace, _issue, _recipient, _opts, _fetcher, _turn_number, _max_turns) do
    {:blocked, result}
  end
```

Add `agent_message_handler/2` that converts an `%Agent.Event{}` to a worker-update map and forwards it (codex passes native handler — but to keep one path, the codex adapter calls this handler with… see Decision). For codex, keep the existing native handler; so define:

```elixir
  defp agent_message_handler(recipient, issue) do
    fn message -> send_codex_update(recipient, issue, normalize_agent_message(message)) end
  end

  defp normalize_agent_message(%SymphonyElixir.Agent.Event{} = event), do: SymphonyElixir.Agent.Event.to_worker_update(event)
  defp normalize_agent_message(message), do: message
```

This makes the handler accept **either** a codex-native update map (passed through) **or** an `%Agent.Event{}` (converted) — so `Agent.Codex` keeps sending native maps and `Agent.Claude` sends events. Update `run/2` `run_on_worker_host` chain so a `{:blocked, result}` return from `run_codex_turns` is propagated up to `run/3` (Task 9 acts on it; for now `run/3` treats both `:ok` and `{:blocked, _}` as success — do not raise).

In `run/3`, broaden the success match:

```elixir
    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok -> :ok
      {:blocked, _result} -> :ok
      {:error, reason} -> raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
```

- [ ] **Step 4: Run the targeted test + the full AgentRunner suite (codex path must stay green)**

Run: `mise exec -- mix test test/symphony_elixir/agent_runner_test.exs`
Expected: PASS, including pre-existing codex-path tests (behavior preserved).

- [ ] **Step 5: Format + commit**

```bash
cd elixir && mise exec -- mix format
git add lib/symphony_elixir/agent_runner.ex test/symphony_elixir/agent_runner_test.exs
git commit -m "feat(agent_runner): drive turns through the Agent behaviour with injectable backend"
```

---

### Task 5: Resolve the backend at orchestrator dispatch (skip on invalid)

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex` (`dispatch_issue/4` ~line 909, `spawn_issue_on_worker_host/5` ~line 942)
- Test: `elixir/test/symphony_elixir/orchestrator_test.exs` (extend)

**Interfaces:**
- Consumes: `Config.agent_backend_for_state/1` (Task 3); `Agent.module_for/1` (Task 1).
- Produces: dispatch resolves the backend module **before** claiming; passes `backend_module:` into `AgentRunner.run/3`. On `{:error, {:invalid_agent_backend, …}}` it logs (with `issue_id`/`issue_identifier`) and does **not** claim/spawn the issue.

- [ ] **Step 1: Write the failing test (invalid backend → not dispatched, no claim)**

```elixir
# add to elixir/test/symphony_elixir/orchestrator_test.exs
test "an issue whose state maps to an unknown backend is logged and not claimed" do
  # memory tracker issue in a state configured to an invalid backend
  configure_workflow!(agent: %{backend: "codex", backend_by_state: %{"implemented" => "gemini"}})
  issue = put_memory_issue!(state: "Implemented")

  log = capture_log(fn -> run_one_poll_cycle!() end)

  assert log =~ "invalid_agent_backend"
  assert log =~ issue.identifier
  refute issue_claimed?(issue.id)
end
```

> Match the existing orchestrator test harness names (the suite already drives poll cycles against the `memory` tracker — reuse those helpers; `capture_log/1` is `ExUnit.CaptureLog`).

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/symphony_elixir/orchestrator_test.exs`
Expected: FAIL — invalid backend currently still dispatches.

- [ ] **Step 3: Resolve backend before claim in `dispatch_issue/4`**

At the top of `dispatch_issue/4`, resolve the backend from the issue's state and short-circuit on error:

```elixir
  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case Config.agent_backend_for_state(issue.state) do
      {:ok, backend_name} ->
        {:ok, backend_module} = SymphonyElixir.Agent.module_for(backend_name)
        # ... existing recipient/worker-host resolution ...
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, backend_module)

      {:error, {:invalid_agent_backend, _state, value}} ->
        Logger.error("Skipping dispatch: invalid_agent_backend value=#{value} issue_id=#{issue.id} issue_identifier=#{issue.identifier}")
        state
    end
  end
```

Thread `backend_module` through `spawn_issue_on_worker_host/6` and into the `AgentRunner.run/3` call:

```elixir
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host, backend_module: backend_module)
         end) do
```

Returning `state` unchanged on the invalid branch means no claim is added (claims are added only on the spawn-success path, ~line 978), satisfying "not claimed".

- [ ] **Step 4: Run the test + full orchestrator suite**

Run: `mise exec -- mix test test/symphony_elixir/orchestrator_test.exs`
Expected: PASS, existing dispatch tests green (valid backends still dispatch with `backend_module: Agent.Codex`).

- [ ] **Step 5: Format + commit**

```bash
cd elixir && mise exec -- mix format
git add lib/symphony_elixir/orchestrator.ex test/symphony_elixir/orchestrator_test.exs
git commit -m "feat(orchestrator): resolve agent backend at dispatch; skip invalid backends"
```

---

### Task 6: `linear_graphql` MCP server escript mode

**Files:**
- Create: `elixir/lib/symphony_elixir/mcp/linear_server.ex`
- Modify: `elixir/lib/symphony_elixir/cli.ex` (add `--linear-mcp` + `--workflow` handling)
- Test: `elixir/test/symphony_elixir/mcp/linear_server_test.exs`

**Interfaces:**
- Consumes: `SymphonyElixir.Codex.DynamicTool.tool_specs/0` and `DynamicTool.execute/3`; `SymphonyElixir.Workflow.set_workflow_file_path/1`; `SymphonyElixir.Config`.
- Produces: `SymphonyElixir.MCP.LinearServer.handle_request/1` mapping a decoded MCP JSON-RPC request map to a response map; exposes tools `linear_graphql` (delegates to `DynamicTool.execute("linear_graphql", args)`) and `approval_prompt` (always denies). CLI: `symphony --linear-mcp --workflow <abs path>` boots config from the workflow and serves MCP over stdio.

- [ ] **Step 1: Write the failing test (tools/list + tools/call routing, approval denies)**

```elixir
# elixir/test/symphony_elixir/mcp/linear_server_test.exs
defmodule SymphonyElixir.MCP.LinearServerTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.MCP.LinearServer

  test "tools/list returns linear_graphql and approval_prompt" do
    response = LinearServer.handle_request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})

    names = response["result"]["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["approval_prompt", "linear_graphql"]
  end

  test "approval_prompt always denies" do
    response =
      LinearServer.handle_request(%{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "approval_prompt", "arguments" => %{"action" => "write file"}}
      })

    text = response["result"]["content"] |> hd() |> Map.get("text")
    assert response["result"]["isError"] == true
    assert text =~ "denied"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/symphony_elixir/mcp/linear_server_test.exs`
Expected: FAIL — `SymphonyElixir.MCP.LinearServer` not available.

- [ ] **Step 3: Implement the MCP request handler**

```elixir
# elixir/lib/symphony_elixir/mcp/linear_server.ex
defmodule SymphonyElixir.MCP.LinearServer do
  @moduledoc """
  Minimal MCP stdio server exposing `linear_graphql` (delegating to the existing
  stateless DynamicTool logic) and a deny-by-default `approval_prompt` tool.
  Launched as `symphony --linear-mcp --workflow <abs path>`.
  """

  alias SymphonyElixir.Codex.DynamicTool

  @approval_tool %{
    "name" => "approval_prompt",
    "description" => "Permission prompt. Non-interactive Symphony session: always denies.",
    "inputSchema" => %{"type" => "object", "additionalProperties" => true, "properties" => %{}}
  }

  @spec tool_specs() :: [map()]
  def tool_specs do
    DynamicTool.tool_specs() ++ [@approval_tool]
  end

  @spec handle_request(map()) :: map()
  def handle_request(%{"method" => "tools/list", "id" => id}) do
    result(id, %{"tools" => tool_specs()})
  end

  def handle_request(%{"method" => "tools/call", "id" => id, "params" => %{"name" => "approval_prompt"}}) do
    result(id, %{"isError" => true, "content" => [%{"type" => "text", "text" => "Permission denied: non-interactive Symphony session."}]})
  end

  def handle_request(%{"method" => "tools/call", "id" => id, "params" => %{"name" => "linear_graphql", "arguments" => args}}) do
    tool_result = DynamicTool.execute("linear_graphql", args)

    result(id, %{
      "isError" => not Map.get(tool_result, "success", false),
      "content" => [%{"type" => "text", "text" => Map.get(tool_result, "output", "")}]
    })
  end

  def handle_request(%{"id" => id, "params" => %{"name" => name}}) do
    error(id, -32601, "Unknown tool: #{name}")
  end

  def handle_request(%{"id" => id}) do
    error(id, -32600, "Unsupported MCP request")
  end

  defp result(id, payload), do: %{"jsonrpc" => "2.0", "id" => id, "result" => payload}
  defp error(id, code, message), do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
end
```

- [ ] **Step 4: Run the handler test**

Run: `mise exec -- mix test test/symphony_elixir/mcp/linear_server_test.exs`
Expected: PASS.

- [ ] **Step 5: Add the stdio loop + CLI wiring (failing test for CLI parse first)**

```elixir
# add to elixir/test/symphony_elixir/cli_test.exs
test "evaluate/2 with --linear-mcp loads the workflow and enters mcp mode" do
  test_pid = self()

  deps = %{
    file_regular?: fn _ -> true end,
    set_workflow_file_path: fn path -> send(test_pid, {:workflow, path}); :ok end,
    set_logs_root: fn _ -> :ok end,
    set_server_port_override: fn _ -> :ok end,
    ensure_all_started: fn -> {:ok, []} end,
    serve_linear_mcp: fn -> send(test_pid, :served); :ok end
  }

  assert :ok = SymphonyElixir.CLI.evaluate(["--linear-mcp", "--workflow", "/abs/WORKFLOW.md"], deps)
  assert_received {:workflow, "/abs/WORKFLOW.md"}
  assert_received :served
end
```

Run: `mise exec -- mix test test/symphony_elixir/cli_test.exs` → Expected: FAIL.

- [ ] **Step 6: Implement CLI `--linear-mcp` mode**

In `cli.ex`: add switches `linear_mcp: :boolean, workflow: :string` to `@switches`; add `serve_linear_mcp` to the `deps` type and `runtime_deps/0` (a function that runs `SymphonyElixir.MCP.LinearServer` stdio loop). In `evaluate/2`, add a clause that, when `--linear-mcp` is present, requires `--workflow`, calls `deps.set_workflow_file_path.(Path.expand(workflow))`, then `deps.serve_linear_mcp.()` (no guardrails banner — this is a child tool process, not the daemon). The stdio loop reads newline-delimited JSON from stdin, calls `LinearServer.handle_request/1`, writes the JSON response + newline to stdout, until EOF.

```elixir
  defp serve_linear_mcp do
    serve_linear_mcp_loop()
  end

  defp serve_linear_mcp_loop do
    case IO.read(:stdio, :line) do
      :eof -> :ok
      {:error, _reason} -> :ok
      line ->
        line
        |> String.trim()
        |> decode_and_respond()

        serve_linear_mcp_loop()
    end
  end

  defp decode_and_respond(""), do: :ok
  defp decode_and_respond(line) do
    case Jason.decode(line) do
      {:ok, request} ->
        response = SymphonyElixir.MCP.LinearServer.handle_request(request)
        IO.puts(Jason.encode!(response))

      {:error, _} ->
        :ok
    end
  end
```

> Confirm the exact MCP stdio framing expected by the Claude CLI during implementation (Open item #1 in the spec). If Claude requires Content-Length headers rather than newline-delimited JSON, adjust the loop and the framing test together. Keep `handle_request/1` (pure) unchanged — only the transport loop changes.

- [ ] **Step 7: Run CLI + MCP tests, format**

Run: `mise exec -- mix test test/symphony_elixir/cli_test.exs test/symphony_elixir/mcp/linear_server_test.exs && mise exec -- mix format`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
cd elixir && git add lib/symphony_elixir/mcp/ lib/symphony_elixir/cli.ex test/symphony_elixir/mcp/ test/symphony_elixir/cli_test.exs
git commit -m "feat(mcp): add linear_graphql MCP server escript mode (symphony --linear-mcp)"
```

---

### Task 7: `Agent.Claude` adapter — local launch, stream-json parsing, blocked precedence

**Files:**
- Create: `elixir/lib/symphony_elixir/agent/claude.ex`
- Create: `elixir/lib/symphony_elixir/agent/claude/stream.ex` (pure stream folder)
- Test: `elixir/test/symphony_elixir/agent/claude/stream_test.exs`
- Test fixtures: `elixir/test/fixtures/claude/{success,max_turns,blocked,truncated}.jsonl`

**Interfaces:**
- Consumes: `SymphonyElixir.Agent.Result`, `SymphonyElixir.Agent.Event`, `Config.settings!().claude`, `Config.codex_runtime_settings/2` timeouts (`turn_timeout_ms`, `stall_timeout_ms`).
- Produces:
  - `SymphonyElixir.Agent.Claude.Stream.fold(events :: [map()], exit_status :: integer() | nil) :: {:ok, Result.t()} | {:error, term()}` — pure: folds parsed stream-json events + the process exit status into a `Result` (or error), applying blocked-wins precedence.
  - `SymphonyElixir.Agent.Claude` implementing `SymphonyElixir.Agent` (launch + drive a turn; `start_session/2` writes the MCP config temp file, `run_turn/4` launches `claude -p` and folds the stream, `stop_session/1` deletes the temp file).

- [ ] **Step 1: Create fixtures (recorded stream-json lines)**

Create `elixir/test/fixtures/claude/success.jsonl`:

```json
{"type":"system","subtype":"init","session_id":"sess-1"}
{"type":"assistant","message":{"content":[{"type":"text","text":"working"}],"usage":{"input_tokens":10,"output_tokens":4}}}
{"type":"result","subtype":"success","is_error":false,"duration_ms":1200,"usage":{"input_tokens":10,"output_tokens":20,"total_tokens":30},"result":"done summary"}
```

`elixir/test/fixtures/claude/max_turns.jsonl`:

```json
{"type":"system","subtype":"init","session_id":"sess-2"}
{"type":"result","subtype":"error_max_turns","is_error":true,"duration_ms":900,"usage":{"input_tokens":5,"output_tokens":5,"total_tokens":10}}
```

`elixir/test/fixtures/claude/blocked.jsonl`:

```json
{"type":"system","subtype":"init","session_id":"sess-3"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__symphony__approval_prompt","input":{"action":"write outside workspace"}}]}}
{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":700,"usage":{"input_tokens":7,"output_tokens":2,"total_tokens":9}}
```

`elixir/test/fixtures/claude/truncated.jsonl`:

```json
{"type":"system","subtype":"init","session_id":"sess-4"}
{"type":"assistant","message":{"content":[{"type":"text","text":"partial
```

- [ ] **Step 2: Write the failing test for `Stream.fold/2`**

```elixir
# elixir/test/symphony_elixir/agent/claude/stream_test.exs
defmodule SymphonyElixir.Agent.Claude.StreamTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Agent.Claude.Stream
  alias SymphonyElixir.Agent.Result

  defp load(name) do
    Path.join([__DIR__, "..", "..", "..", "fixtures", "claude", name])
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  test "success stream folds to a done result with tokens and summary" do
    assert {:ok, %Result{} = result} = Stream.fold(load("success.jsonl"), 0)
    assert result.status == :done
    assert result.session_id == "sess-1"
    assert result.tokens == %{input: 10, output: 20, total: 30}
    assert result.seconds_running == 1
    assert result.summary == "done summary"
  end

  test "max_turns stream folds to an error" do
    assert {:error, {:claude_error, "error_max_turns"}} = Stream.fold(load("max_turns.jsonl"), 1)
  end

  test "blocked-wins: approval_prompt then nonzero exit still yields blocked" do
    assert {:ok, %Result{status: :blocked, blocked_action: action}} = Stream.fold(load("blocked.jsonl"), 1)
    assert action =~ "write outside workspace"
  end

  test "truncated stream with no result and nonzero exit is a stream error" do
    # blocked event never seen, so this is a genuine failure
    assert {:error, {:claude_stream, _}} = Stream.fold([%{"type" => "system", "subtype" => "init", "session_id" => "sess-4"}], 1)
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `mise exec -- mix test test/symphony_elixir/agent/claude/stream_test.exs`
Expected: FAIL — `SymphonyElixir.Agent.Claude.Stream` not available.

- [ ] **Step 4: Implement the pure stream folder**

```elixir
# elixir/lib/symphony_elixir/agent/claude/stream.ex
defmodule SymphonyElixir.Agent.Claude.Stream do
  @moduledoc """
  Pure folder: turns a list of decoded Claude stream-json events plus the process
  exit status into an Agent.Result (or error). Encodes blocked-wins precedence.
  """

  alias SymphonyElixir.Agent.Result

  @approval_tool "mcp__symphony__approval_prompt"

  defstruct session_id: nil, tokens: %{input: 0, output: 0, total: 0}, seconds_running: 0, summary: nil, blocked_action: nil, saw_result: false, result_status: nil

  @spec fold([map()], integer() | nil) :: {:ok, Result.t()} | {:error, term()}
  def fold(events, exit_status) do
    acc = Enum.reduce(events, %__MODULE__{}, &apply_event/2)
    finalize(acc, exit_status)
  end

  defp apply_event(%{"type" => "system", "subtype" => "init"} = e, acc) do
    %{acc | session_id: Map.get(e, "session_id", acc.session_id)}
  end

  defp apply_event(%{"type" => type, "message" => message}, acc) when type in ["assistant", "user"] do
    acc
    |> apply_usage(Map.get(message, "usage"))
    |> apply_content(Map.get(message, "content", []))
  end

  defp apply_event(%{"type" => "result"} = e, acc) do
    %{
      acc
      | saw_result: true,
        seconds_running: div(Map.get(e, "duration_ms", acc.seconds_running * 1000), 1000),
        tokens: merge_tokens(acc.tokens, Map.get(e, "usage")),
        summary: Map.get(e, "result", acc.summary),
        result_status: result_status(e)
    }
  end

  defp apply_event(_other, acc), do: acc

  defp apply_content(acc, content) when is_list(content) do
    Enum.reduce(content, acc, fn
      %{"type" => "tool_use", "name" => @approval_tool, "input" => input}, inner ->
        %{inner | blocked_action: blocked_action_text(input)}

      %{"type" => "text", "text" => text}, inner ->
        %{inner | summary: append_text(inner.summary, text)}

      _, inner ->
        inner
    end)
  end

  defp apply_content(acc, _), do: acc

  defp apply_usage(acc, nil), do: acc
  defp apply_usage(acc, usage), do: %{acc | tokens: merge_tokens(acc.tokens, usage)}

  defp merge_tokens(current, nil), do: current

  defp merge_tokens(current, usage) do
    input = Map.get(usage, "input_tokens", current.input)
    output = Map.get(usage, "output_tokens", current.output)
    total = Map.get(usage, "total_tokens", input + output)
    %{input: input, output: output, total: total}
  end

  defp result_status(%{"is_error" => false, "subtype" => "success"}), do: :done
  defp result_status(%{"subtype" => subtype}), do: {:error, subtype}
  defp result_status(%{"is_error" => true}), do: {:error, "error"}
  defp result_status(_), do: :done

  defp append_text(nil, text), do: text
  defp append_text(existing, text), do: existing <> text

  defp blocked_action_text(input) when is_map(input), do: Map.get(input, "action") || Jason.encode!(input)
  defp blocked_action_text(input), do: to_string(input)

  # Blocked-wins precedence: a fully-parsed approval event beats a later nonzero exit / missing result.
  defp finalize(%__MODULE__{blocked_action: action} = acc, _exit_status) when is_binary(action) do
    {:ok, Result.new(status: :blocked, session_id: acc.session_id, tokens: acc.tokens, seconds_running: acc.seconds_running, summary: acc.summary, blocked_action: action)}
  end

  defp finalize(%__MODULE__{saw_result: true, result_status: :done} = acc, _exit_status) do
    {:ok, Result.new(status: :done, session_id: acc.session_id, tokens: acc.tokens, seconds_running: acc.seconds_running, summary: acc.summary)}
  end

  defp finalize(%__MODULE__{saw_result: true, result_status: {:error, subtype}}, _exit_status) do
    {:error, {:claude_error, subtype}}
  end

  defp finalize(%__MODULE__{saw_result: false}, exit_status) when exit_status in [0, nil] do
    {:error, {:claude_stream, "stream ended without a result event"}}
  end

  defp finalize(%__MODULE__{saw_result: false}, _exit_status) do
    {:error, {:claude_stream, "nonzero exit without a result event"}}
  end
end
```

- [ ] **Step 5: Run the stream test**

Run: `mise exec -- mix test test/symphony_elixir/agent/claude/stream_test.exs`
Expected: PASS (all four cases, including blocked-wins and truncated-error).

- [ ] **Step 6: Implement `Agent.Claude` (launch + drive)**

```elixir
# elixir/lib/symphony_elixir/agent/claude.ex
defmodule SymphonyElixir.Agent.Claude do
  @moduledoc """
  Agent backend that runs Claude Code (`claude -p`) per turn, parsing
  `--output-format stream-json` into an Agent.Result. Stateless per turn.
  """

  @behaviour SymphonyElixir.Agent

  require Logger
  alias SymphonyElixir.Agent.Claude.Stream
  alias SymphonyElixir.{Config, Agent.Event}

  @default_allowed_tools ["mcp__symphony__linear_graphql", "Read", "Grep", "Glob", "Bash", "Edit", "Write"]
  @port_line_bytes 1_048_576

  @impl true
  def start_session(workspace, opts) do
    case write_mcp_config() do
      {:ok, mcp_config_path} ->
        {:ok, %{workspace: workspace, worker_host: Keyword.get(opts, :worker_host), mcp_config_path: mcp_config_path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def run_turn(%{workspace: workspace} = session, prompt, _issue, opts) do
    on_message = Keyword.get(opts, :on_message)
    {events, exit_status} = run_claude(session, workspace, prompt, on_message)
    Stream.fold(events, exit_status)
  end

  @impl true
  def stop_session(%{mcp_config_path: path}) do
    _ = File.rm(path)
    :ok
  end

  defp write_mcp_config do
    claude = Config.settings!().claude
    mcp_command = claude.linear_mcp_command || default_mcp_command()
    workflow_path = SymphonyElixir.Workflow.current_path()

    config = %{
      "mcpServers" => %{
        "symphony" => %{
          "command" => mcp_command,
          "args" => claude.linear_mcp_args ++ ["--linear-mcp", "--workflow", workflow_path]
          # LINEAR_API_KEY is inherited from this process's environment, NOT written here.
        }
      }
    }

    path = Path.join(System.tmp_dir!(), "symphony-claude-mcp-#{System.unique_integer([:positive])}.json")

    with :ok <- File.write(path, Jason.encode!(config)),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    end
  end

  defp default_mcp_command, do: List.to_string(:escript.script_name())

  defp run_claude(%{worker_host: nil}, workspace, prompt, on_message) do
    claude = Config.settings!().claude
    executable = expand_executable(claude.command)
    argv = claude.args ++ base_flags() ++ ["--mcp-config", "PLACEHOLDER"] ++ [prompt]
    # NOTE: argv is illustrative; the real mcp-config path comes from the session. See Step 7.
    drive_port(executable, argv, workspace, on_message)
  end

  defp run_claude(%{worker_host: host}, workspace, prompt, on_message) when is_binary(host) do
    # SSH path implemented in Task 8.
    drive_ssh(host, workspace, prompt, on_message)
  end

  defp base_flags do
    claude = Config.settings!().claude
    allowed = claude.allowed_tools || @default_allowed_tools

    ["-p", "--output-format", "stream-json", "--verbose", "--permission-prompt-tool", "mcp__symphony__approval_prompt", "--allowedTools", Enum.join(allowed, ",")]
  end

  defp expand_executable(command), do: command |> Path.expand()

  defp drive_port(executable, argv, workspace, on_message) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(argv, &String.to_charlist/1),
        cd: String.to_charlist(workspace),
        line: @port_line_bytes
      ])

    collect_stream(port, on_message, [], nil)
  end

  defp collect_stream(port, on_message, events, _exit_status) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, event} ->
            maybe_emit(on_message, event)
            collect_stream(port, on_message, [event | events], nil)

          {:error, _} ->
            collect_stream(port, on_message, events, nil)
        end

      {^port, {:data, {:noeol, _partial}}} ->
        collect_stream(port, on_message, events, nil)

      {^port, {:exit_status, status}} ->
        {Enum.reverse(events), status}
    end
  end

  defp maybe_emit(nil, _event), do: :ok

  defp maybe_emit(on_message, event) when is_function(on_message, 1) do
    on_message.(event_to_agent_event(event))
  end

  defp event_to_agent_event(%{"type" => "system", "subtype" => "init", "session_id" => sid}),
    do: %Event{kind: :session_started, session_id: sid, detail: %{}}

  defp event_to_agent_event(%{"type" => "result"} = e),
    do: %Event{kind: :completed, tokens: tokens_from(Map.get(e, "usage")), seconds_running: div(Map.get(e, "duration_ms", 0), 1000), detail: %{}}

  defp event_to_agent_event(%{"message" => %{"usage" => usage}}) when is_map(usage),
    do: %Event{kind: :usage_updated, tokens: tokens_from(usage), detail: %{}}

  defp event_to_agent_event(_event), do: %Event{kind: :usage_updated, detail: %{}}

  defp tokens_from(nil), do: nil
  defp tokens_from(usage),
    do: %{input: Map.get(usage, "input_tokens", 0), output: Map.get(usage, "output_tokens", 0), total: Map.get(usage, "total_tokens", Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0))}
end
```

- [ ] **Step 7: Resolve the real `--mcp-config` path into argv + add `Workflow.current_path/0`**

The `--mcp-config` value must be `session.mcp_config_path`. Thread the session into `run_claude/4` argv construction (replace the `"PLACEHOLDER"` with `session.mcp_config_path`). Add `SymphonyElixir.Workflow.current_path/0` returning the absolute path the orchestrator loaded (it already stores the workflow path — expose it; if absent, add a `@spec current_path() :: String.t()` reading the stored path). Write a focused test:

```elixir
# add to elixir/test/symphony_elixir/agent/claude_test.exs
test "start_session writes a 0600 mcp config outside the workspace and stop_session removes it" do
  {:ok, session} = SymphonyElixir.Agent.Claude.start_session("/tmp/some-workspace", [])
  assert File.exists?(session.mcp_config_path)
  refute String.starts_with?(session.mcp_config_path, "/tmp/some-workspace")
  assert {:ok, %File.Stat{mode: mode}} = File.stat(session.mcp_config_path)
  assert Bitwise.band(mode, 0o777) == 0o600
  config = session.mcp_config_path |> File.read!() |> Jason.decode!()
  refute Jason.encode!(config) =~ "LINEAR_API_KEY"
  assert :ok = SymphonyElixir.Agent.Claude.stop_session(session)
  refute File.exists?(session.mcp_config_path)
end
```

> Requires a loaded workflow in the test (use the existing `write_workflow!/1` helper to set one with `claude: {}`). Confirm `claude` CLI flag names against the installed CLI (spec Open item #1) and adjust `base_flags/0` if needed — keep the test for config-file safety stable regardless of flag spelling.

- [ ] **Step 8: Run the Claude adapter tests, format**

Run: `mise exec -- mix test test/symphony_elixir/agent/claude_test.exs test/symphony_elixir/agent/claude/stream_test.exs && mise exec -- mix format`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
cd elixir && git add lib/symphony_elixir/agent/claude.ex lib/symphony_elixir/agent/claude/ test/symphony_elixir/agent/claude_test.exs test/symphony_elixir/agent/claude/ test/fixtures/claude/
git commit -m "feat(agent): add Agent.Claude adapter with stream-json parsing and blocked precedence"
```

---

### Task 8: `Agent.Claude` SSH launch (stdin prompt delivery)

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent/claude.ex` (`run_claude/4` SSH clause, `drive_ssh/4`)
- Modify: `elixir/lib/symphony_elixir/ssh.ex` (if needed, add a stdin-write helper)
- Test: `elixir/test/symphony_elixir/agent/claude_ssh_test.exs`

**Interfaces:**
- Consumes: `SymphonyElixir.SSH.start_port/3` (existing), `claude.linear_mcp_command` (worker-side absolute path).
- Produces: `drive_ssh/4` that builds a remote command string containing **only fixed flags** (no prompt text), opens the SSH port, writes the prompt bytes to the port's stdin, closes stdin, and folds the stream identically to local.

- [ ] **Step 1: Write the failing test (prompt absent from remote command string)**

```elixir
# elixir/test/symphony_elixir/agent/claude_ssh_test.exs
defmodule SymphonyElixir.Agent.ClaudeSSHTest do
  use ExUnit.Case, async: true

  test "remote_command/2 never contains the prompt text" do
    prompt = ~s|"; rm -rf / ; echo $(whoami) `id`|
    command = SymphonyElixir.Agent.Claude.remote_command("/work/dir", prompt)

    refute command =~ "rm -rf"
    refute command =~ "whoami"
    assert command =~ "claude"
    assert command =~ "--output-format stream-json"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/symphony_elixir/agent/claude_ssh_test.exs`
Expected: FAIL — `remote_command/2` undefined.

- [ ] **Step 3: Implement `remote_command/2` + `drive_ssh/4`**

```elixir
  @doc false
  @spec remote_command(String.t(), String.t()) :: String.t()
  def remote_command(workspace, _prompt) do
    claude = Config.settings!().claude
    allowed = claude.allowed_tools || @default_allowed_tools
    # Prompt is delivered via stdin (claude -p reads the prompt from stdin when no positional prompt is given).
    flags = ["-p", "--output-format", "stream-json", "--verbose", "--permission-prompt-tool", "mcp__symphony__approval_prompt", "--allowedTools", Enum.join(allowed, ","), "--mcp-config", remote_mcp_config_path()]
    "cd #{shell_escape(workspace)} && #{claude.command} #{Enum.map_join(flags, " ", &shell_escape/1)}"
  end

  defp drive_ssh(host, workspace, prompt, on_message) do
    {:ok, port} = SymphonyElixir.SSH.start_port(host, remote_command(workspace, prompt), line: @port_line_bytes)
    Port.command(port, prompt <> "\n")
    # Signal EOF on stdin so claude starts processing. SSH.start_port must open the port with stdin writable.
    _ = Port.command(port, <<4>>)
    collect_stream(port, on_message, [], nil)
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
  end

  defp remote_mcp_config_path do
    # On SSH workers the MCP config + secret handling is provisioned worker-side; see spec Open item #3.
    Config.settings!().claude.linear_mcp_args |> List.first() || "~/.symphony/claude-mcp.json"
  end
```

> **Important (spec Open items #1 and #3):** Confirm (a) that `claude -p` reads the prompt from stdin when no positional prompt arg is given — if it does not, write the prompt to a worker-side temp file (mode `0600`, outside the checkout) and pass its path, keeping it out of the command string; and (b) how the worker-side MCP config + `LINEAR_API_KEY` are provisioned. Adjust `drive_ssh/4`/`remote_command/2` and this test together. The invariant the test pins — **prompt text never appears in the remote command string** — must hold regardless.

- [ ] **Step 4: Run the SSH test, format**

Run: `mise exec -- mix test test/symphony_elixir/agent/claude_ssh_test.exs && mise exec -- mix format`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd elixir && git add lib/symphony_elixir/agent/claude.ex lib/symphony_elixir/ssh.ex test/symphony_elixir/agent/claude_ssh_test.exs
git commit -m "feat(agent): add Agent.Claude SSH launch with stdin prompt delivery"
```

---

### Task 9: Blocked-write ownership in `AgentRunner`

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Test: `elixir/test/symphony_elixir/agent_runner_test.exs` (extend)

**Interfaces:**
- Consumes: `Tracker.create_comment/2`, `Tracker.update_issue_state/2`, `Config.settings!().agent.blocked_state`, the `{:blocked, %Result{}}` return from the turn loop (Task 4).
- Produces: when a run ends `{:blocked, result}`, `AgentRunner` calls `create_comment` (with the deterministic body) **then** `update_issue_state(blocked_state)`. Comment failure ⇒ skip state update, return `:ok` (issue stays active → retried). State-update failure after a successful comment ⇒ log, return `:ok`.

- [ ] **Step 1: Write the failing tests (ordering + partial failure)**

```elixir
# add to elixir/test/symphony_elixir/agent_runner_test.exs
test "blocked result posts a comment then sets the blocked state, in order" do
  issue = build_issue(state: "Implemented")
  # memory tracker records calls in order; assert comment precedes state update
  run_blocked!(issue, blocked_action: "approve write")

  assert MemoryTracker.calls() == [
           {:create_comment, issue.id},
           {:update_issue_state, issue.id, "Blocked / Needs Attention"}
         ]
end

test "when create_comment fails, the state is NOT updated and run returns ok" do
  issue = build_issue(state: "Implemented")
  MemoryTracker.fail(:create_comment)

  assert :ok = run_blocked!(issue, blocked_action: "approve write")
  refute Enum.any?(MemoryTracker.calls(), &match?({:update_issue_state, _, _}, &1))
end
```

> Use the `memory` tracker (`SymphonyElixir.Tracker.Memory`) with a small call-recording extension if not already present; match the existing tracker-test helpers. `run_blocked!/2` drives `AgentRunner.run/3` with a stub backend whose `run_turn` returns `{:ok, Result.new(status: :blocked, blocked_action: ...)}`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/symphony_elixir/agent_runner_test.exs`
Expected: FAIL — blocked handling not implemented.

- [ ] **Step 3: Implement blocked-write ownership**

In `run_on_worker_host/4`, capture the `{:blocked, result}` from `run_codex_turns` and handle it before the `after` hook returns. Add:

```elixir
  defp handle_run_outcome({:blocked, result}, issue) do
    post_blocked_state(issue, result)
    :ok
  end

  defp handle_run_outcome(other, _issue), do: other

  defp post_blocked_state(%Issue{} = issue, result) do
    body = blocked_comment_body(issue, result)

    case Tracker.create_comment(issue.id, body) do
      :ok ->
        blocked_state = Config.settings!().agent.blocked_state

        case Tracker.update_issue_state(issue.id, blocked_state) do
          :ok ->
            Logger.info("Parked blocked issue #{issue_context(issue)} state=#{blocked_state}")

          {:error, reason} ->
            Logger.error("Blocked state update failed for #{issue_context(issue)}: #{inspect(reason)} (comment posted; will retry on next poll)")
        end

      {:error, reason} ->
        Logger.error("Blocked comment failed for #{issue_context(issue)}: #{inspect(reason)} (state NOT changed; will retry on next poll)")
    end
  end

  defp blocked_comment_body(%Issue{} = issue, result) do
    detail = result.blocked_action || result.summary || "No blocked action detail was provided."
    truncated = String.slice(detail, 0, 4_000)
    suffix = if String.length(detail) > 4_000, do: "\n… (truncated)", else: ""

    """
    **Symphony: blocked**

    session_id: #{result.session_id || "unknown"}

    #{truncated}#{suffix}
    """
  end
```

Wire `handle_run_outcome/2` around the `run_codex_turns` result inside `run_on_worker_host/4` (after the `with`/`after`), so a `{:blocked, result}` is converted to `:ok` only after the Linear writes are attempted. Keep `run/3` mapping `{:blocked, _}` → `:ok` (Task 4) as a fallback, but the outcome should now already be `:ok`.

- [ ] **Step 4: Run the blocked tests + full AgentRunner suite**

Run: `mise exec -- mix test test/symphony_elixir/agent_runner_test.exs`
Expected: PASS, codex-path tests still green.

- [ ] **Step 5: Format + commit**

```bash
cd elixir && mise exec -- mix format
git add lib/symphony_elixir/agent_runner.ex test/symphony_elixir/agent_runner_test.exs lib/symphony_elixir/tracker/memory.ex
git commit -m "feat(agent_runner): own blocked-state Linear writes (comment-then-state, partial-failure safe)"
```

---

### Task 10: Docs, spec alignment, and the full quality gate

**Files:**
- Modify: `SPEC.md`, `elixir/README.md`, `elixir/WORKFLOW.md`, root `README.md` (review only), `docs/superpowers/plans/2026-06-19-symphony-pipeline.md` (Task 6 supersession note)

- [ ] **Step 1: Update `SPEC.md`**

Document the agent-backend abstraction and the config keys `agent.backend`, `agent.backend_by_state`, `agent.blocked_state`, and the `claude.*` block. State the codex path is behavior-preserving and the Claude path is the new backend. Keep the implementation a non-conflicting superset.

- [ ] **Step 2: Update `elixir/README.md`**

Add a "Agent backends" subsection: `agent.backend` / `backend_by_state` / `blocked_state`; the `claude.*` keys; `claude` CLI as an optional dependency; the `symphony --linear-mcp --workflow <abs>` escript mode.

- [ ] **Step 3: Update `elixir/WORKFLOW.md`**

Add an `agent.backend_by_state` example routing `implemented: claude` plus `blocked_state`, and a minimal `claude:` block.

- [ ] **Step 4: Review root `README.md`**

Confirm the project concept/goals are unchanged; add at most a one-line mention of multi-agent backends if warranted, else leave as-is. Record the decision in the commit message.

- [ ] **Step 5: Supersede pipeline Plan B Task 6**

In `docs/superpowers/plans/2026-06-19-symphony-pipeline.md`, add a note to Task 6 that `review-pr` now runs by setting `backend_by_state: {implemented: claude}` rather than codex shelling out to claude.

- [ ] **Step 6: Run the full quality gate**

Run: `cd elixir && mise exec -- make all`
Expected: setup, build, fmt-check, lint, **coverage 100%**, dialyzer all PASS. If coverage flags an untested branch in a new module, add a unit test (do not add the module to `mix.exs` `ignore_modules`).

- [ ] **Step 7: Commit**

```bash
git add SPEC.md elixir/README.md elixir/WORKFLOW.md README.md docs/superpowers/plans/2026-06-19-symphony-pipeline.md
git commit -m "docs: document Claude agent backend config and supersede pipeline Task 6"
```

---

### Task 11 (opt-in): live e2e scenario routing one state to claude

**Files:**
- Modify: `elixir/test/symphony_elixir/live_e2e_test.exs`

**Interfaces:**
- Consumes: the live e2e harness (gated by `SYMPHONY_RUN_LIVE_E2E=1`); a local `claude` CLI + auth.

- [ ] **Step 1: Add a claude-routed scenario (skipped unless the flag is set)**

Add a scenario that writes a temp `WORKFLOW.md` with `agent.backend_by_state: {"<active state>": "claude"}`, drives one issue through, and asserts the Claude backend ran (workspace side effect + a Linear comment). Gate it behind the existing `SYMPHONY_RUN_LIVE_E2E` check and a `System.find_executable("claude")` guard that skips with a clear message when absent.

- [ ] **Step 2: Run it (only when explicitly enabled)**

Run: `cd elixir && export LINEAR_API_KEY=... && SYMPHONY_RUN_LIVE_E2E=1 mise exec -- mix test test/symphony_elixir/live_e2e_test.exs`
Expected: PASS (or skipped if `claude` is not installed).

- [ ] **Step 3: Commit**

```bash
cd elixir && git add test/symphony_elixir/live_e2e_test.exs
git commit -m "test(e2e): add opt-in live scenario routing a state to the claude backend"
```

---

## Self-Review

**1. Spec coverage:**
- `Agent` behaviour + `Result` + `Event` → Task 1. Session-aware callbacks (`start_session`/`run_turn`/`stop_session`) → Tasks 1, 2, 7.
- `Agent.Codex` behavior-preserving wrap → Task 2.
- `agent.backend` / `backend_by_state` / `blocked_state` + `claude.*` + `agent_backend_for_state/1` (structural validation, error tuple) → Task 3.
- Continuation ownership in `AgentRunner` (resolve once, loop while same state) → Task 4; backend resolved at dispatch before claim, invalid → skip → Task 5.
- Standalone `linear_graphql` MCP server (`--linear-mcp --workflow`, reuse `DynamicTool`, `approval_prompt` deny) → Task 6.
- Claude argv launch (no shell), stream-json parsing, blocked-wins precedence, secret-safe 0600 MCP config deleted on `stop_session`, allowed-tools policy → Task 7; SSH stdin prompt delivery + prompt-absent-from-command invariant → Task 8.
- Blocked-write ownership comment-then-state, partial-failure, deterministic comment body w/ truncation → Task 9.
- Event bridge to existing `{:codex_worker_update, …}` map → Task 1 (`Event.to_worker_update/1`) + Task 4 (`normalize_agent_message/1`).
- Docs/spec alignment incl. root README review + pipeline supersession → Task 10. Opt-in live e2e → Task 11.

**2. Placeholder scan:** The string `"PLACEHOLDER"` in Task 7 Step 6 is explicitly replaced in Step 7 (called out, not a silent TODO). Open-item CLI/flag confirmations are flagged with a stable invariant + a "confirm against the installed CLI" note, not left as vague requirements. No "TBD"/"add error handling"/"similar to" placeholders.

**3. Type consistency:** `Agent.Result.new/1`, `Result.t()` fields (`status/session_id/tokens/seconds_running/summary/blocked_action`), `Event.to_worker_update/1` output (`%{event:, timestamp:, session_id:, usage: %{input_tokens:, output_tokens:, total_tokens:}}`), `agent_backend_for_state/1` `{:ok, backend} | {:error, {:invalid_agent_backend, state, value}}`, and `Stream.fold/2` `{:ok, Result.t()} | {:error, {:claude_error|:claude_stream, _}}` are referenced identically across Tasks 1–9. `Agent.module_for/1` (Task 1) is consumed in Task 5.
