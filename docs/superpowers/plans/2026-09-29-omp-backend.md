# omp Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `omp` as a third `Agent` backend (`agent.backend: omp`) driven per turn via `omp -p --mode json`, on a shared `Agent.CliHarness` extracted from `Agent.Claude`.

**Architecture:** Harness-neutral session-dir, port, SSH and tracker-env helpers move from `Agent.Claude` into `Agent.CliHarness`, parametrized by a stream-folder module. `Agent.Omp` builds a hermetic per-session omp environment (private `PI_CODING_AGENT_DIR`, overlay config) and folds omp's JSON events with `Agent.Omp.Stream`.

**Tech Stack:** Elixir 1.19 / OTP 28, Ecto embedded schemas, ExUnit, Jason. Run all `mix` commands in `elixir/`.

**Spec:** `docs/superpowers/specs/2026-09-29-omp-backend-design.md`

## Global Constraints

- Every public `def` in `lib/` needs an adjacent `@spec` (`mix specs.check`); `defp` and `@impl` are exempt.
- Line length 120 (`mix format`); `credo --strict` clean; coverage >= 80%; `make all` must pass at the end.
- Clean cutover: when code moves, migrate every caller and test; no re-export shims in `Agent.Claude`.
- Claude behavior must not change: existing Claude tests (moved helper tests excepted, they move with the code) stay green unmodified.
- Follow `elixir/docs/logging.md`. Logs must never contain prompt or secret bodies.
- Symphony never stores provider keys. Credentials come from the process environment.
- Tracker secret env names are unset for the child: local via Port `env: [{name, false}]`, remote via `unset`.
- New behavior/config: update `SPEC.md`, `elixir/README.md`, `elixir/WORKFLOW.md`, `.claude/docs/architecture.md`, `.claude/docs/configuration.md` in the same change.
- omp facts (probed on omp 18.4.3): prompt via stdin works with `-p`; `--continue` with `--session-dir` resumes context; JSON events on stdout are `session`, `agent_start`, `turn_start`, `message_start|update|end`, `tool_execution_start`, `turn_end`, `agent_end`; assistant `message_end.message.usage` = `{input, output, cacheRead, cacheWrite, totalTokens}` and `stopReason`.
- Hermetic omp flags/settings (verified): env `PI_CODING_AGENT_DIR=<private>/agent`; overlay `mcp.enableProjectConfig: false` and `disabledProviders` = `omp-plugins, claude, agent-plugins, codex, agents, claude-plugins, gemini, opencode, cursor, windsurf, cline, github, vscode, agents-md, mcp-json, ssh-json`; flags `--no-extensions --no-skills --no-rules --no-title`.

## File Structure

| File | Responsibility |
|---|---|
| `lib/symphony_elixir/agent/cli_harness.ex` (new) | Session dir + cleanup monitor, executable resolution, private file writes, Port driver, stream collection, tracker env capture/scrub, remote-shell building blocks, default MCP command |
| `lib/symphony_elixir/agent/cli_harness/stream_folder.ex` (new) | `@behaviour` for stream folders: `new/0`, `step/2`, `finalize/2` |
| `lib/symphony_elixir/agent/claude.ex` (modify) | Claude argv, MCP config, SSH command; delegates to harness |
| `lib/symphony_elixir/agent/claude/stream.ex` (modify) | Add `@behaviour StreamFolder` only |
| `lib/symphony_elixir/agent/omp.ex` (new) | omp session, isolation files, argv, local and SSH turns |
| `lib/symphony_elixir/agent/omp/stream.ex` (new) | Pure folder for omp JSON events |
| `lib/symphony_elixir/agent.ex` (modify) | `module_for("omp")` |
| `lib/symphony_elixir/config/schema.ex` (modify) | `Omp` embed |
| `lib/symphony_elixir/config.ex` (modify) | Blank-command validation, `backend_command/2` |
| `lib/symphony_elixir/orchestrator.ex` (modify ~2205) | Use `Config.backend_command/2` |
| `lib/symphony_elixir/agent_runner.ex` (modify ~263) | Continuation prompt for omp |
| `lib/symphony_elixir_web/live/lane_editor_live.ex` (modify) | Backend option + omp fields |
| `test/symphony_elixir/agent/cli_harness_test.exs` (new) | Harness tests (moved from `claude_test.exs`) |
| `test/symphony_elixir/agent/omp/stream_test.exs` (new) | Folder tests |
| `test/symphony_elixir/agent/omp_test.exs`, `omp_ssh_test.exs` (new) | Backend tests with fake `omp` scripts |

---

### Task 1: Extract `Agent.CliHarness` from `Agent.Claude`

Pure refactor. The Claude suite is the safety net; no new behavior.

**Files:**
- Create: `lib/symphony_elixir/agent/cli_harness.ex`, `lib/symphony_elixir/agent/cli_harness/stream_folder.ex`, `test/symphony_elixir/agent/cli_harness_test.exs`
- Modify: `lib/symphony_elixir/agent/claude.ex`, `lib/symphony_elixir/agent/claude/stream.ex`, `test/symphony_elixir/agent/claude_test.exs`, `test/symphony_elixir/agent/claude_ssh_test.exs`

**Interfaces:**
- Produces (all in `SymphonyElixir.Agent.CliHarness`, each with `@spec`):
  - `create_session_dir(dir_name :: String.t(), workspace :: Path.t()) :: {:ok, session_dir :: Path.t(), cleanup_monitor :: pid()} | {:error, term()}` — body of `mcp_config_dir/1` (tmp dir named `dir_name`, `.`-prefixed sibling of the workspace when tmp is inside it) + `ensure_private_directory` + `create_private_session_directory` + `start_cleanup_monitor(self(), dir)`.
  - `remove_session_dir(session_dir :: Path.t(), monitor :: pid() | nil) :: :ok`
  - `write_private_file(path, contents) :: :ok | {:error, term()}`; `write_prompt_file(session_dir, prompt) :: {:ok, Path.t()} | {:error, term()}`
  - `resolve_executable(command :: String.t(), not_configured :: atom()) :: {:ok, String.t()} | {:error, term()}` (Claude passes `:claude_command_not_configured`)
  - `drive_port(executable, argv, workspace, on_message, stdin_path, secret_environment_names, opts)` where `opts :: [stream: module(), error_tag: atom(), label: String.t(), env: [{charlist(), charlist() | false}]]`; `env` is appended to the scrub env (Omp uses it for `PI_CODING_AGENT_DIR`).
  - `collect_port_stream(port, on_message, stream :: module(), label :: String.t()) :: {:ok, Result.t()} | {:error, term()}`; `close_port/1`
  - `capture_tracker_env(names, env_reader)`, `valid_environment_names/1`, `tracker_secret_port_env/1`, `tracker_secret_unset_command/1`
  - `shell_escape/1`, `remote_mktemp_function/0`, `read_length_prefixed_file(label, destination)`, `remote_temp_path(prefix, suffix)`, `temp_token/0`, `default_mcp_command/1`
- `CliHarness.StreamFolder` callbacks: `new() :: struct()`, `step(map(), struct()) :: {struct(), map() | nil}`, `finalize(struct(), integer() | nil) :: {:ok, Result.t()} | {:error, term()}`. Every folder struct exposes `:session_id` (used in the undecodable-line warning).

- [ ] **Step 1: Baseline** — `mix test test/symphony_elixir/agent` must be green before touching anything. Record the count.

- [ ] **Step 2: Create the behaviour**

```elixir
defmodule SymphonyElixir.Agent.CliHarness.StreamFolder do
  @moduledoc "Contract for pure folders of a CLI agent's line-delimited JSON event stream."

  alias SymphonyElixir.Agent.Result

  @callback new() :: struct()
  @callback step(event :: map(), acc :: struct()) :: {struct(), map() | nil}
  @callback finalize(acc :: struct(), exit_status :: integer() | nil) :: {:ok, Result.t()} | {:error, term()}
end
```

Add `@behaviour SymphonyElixir.Agent.CliHarness.StreamFolder` to `Agent.Claude.Stream` (its `new/0`, `step/2`, `finalize/2` already match; add `@impl true` above each).

- [ ] **Step 3: Move code verbatim into `cli_harness.ex`.** Move these `Agent.Claude` functions unchanged in body, renaming per the Interfaces list (line numbers refer to the current `claude.ex`): `mcp_config_dir` 218-233, `path_inside?` 235-240, `default_mcp_command`/`safe_escript_name`/`burrito_runtime?`/`executable_candidate`/`executable_regular_file?` 242-291, `claude_executable` 330-349, `write_prompt_file`/`write_private_file*` 485-505, `remote_mktemp_function` 507-517, `read_length_prefixed_file` 541-548, `capture_tracker_env*`/`valid_environment_names`/`tracker_secret_*` 588-629, `stdin_redirect_command`/`shell_escape` 631-638, `collect_stream`/`drain_port_data`/`finalize_stream`/`handle_line`/`receive_timeout*`/`close_port`/`maybe_emit` 640-736, `remote_temp_path`/`temp_token`/`monotonic_ms` 742-750, `ensure_private_directory`/`create_private_session_directory`/`start_cleanup_monitor` 156-184.

Three parametrizations only:
1. `drive_port/7` takes `opts`; its `rescue` returns `{:error, {Keyword.fetch!(opts, :error_tag), error}}`; `env` = `tracker_secret_port_env(secret_environment_names) ++ Keyword.get(opts, :env, [])`; it calls `collect_port_stream(port, on_message, opts[:stream], opts[:label])`.
2. `collect_stream`/`handle_line`/`finalize_stream` call `stream.new()`, `stream.step/2`, `stream.finalize/2` instead of `Stream.*`, and the undecodable-line warning becomes `"#{label} stream line dropped (undecodable) session_id=... bytes=..."` (identical text for Claude).
3. `create_session_dir(dir_name, workspace)` composes the three moved directory helpers; `mcp_config_dir` is inlined into it using `dir_name` instead of the literal `"symphony-claude-mcp"` / `".symphony-claude-mcp"`.

- [ ] **Step 4: Rewire `Agent.Claude`.** Delete the moved functions; call `CliHarness.*` (alias it). Claude passes `stream: Stream, error_tag: :claude_port, label: "Claude"` and `create_session_dir("symphony-claude-mcp", expanded_workspace)`. Keep the existing SSH `{:claude_ssh_port, error}` rescue. Remove Claude's `@doc false` public `drive_port`, `collect_port_stream`, `close_port`, `mcp_config_dir`, `default_mcp_command` (kept: `remote_command/2`, used by `claude_ssh_test.exs`). `remote_mcp_command/0` and `mcp_config/4` stay in Claude.

- [ ] **Step 5: Migrate tests.** Move to `cli_harness_test.exs`, changing only the module alias and the added `opts`: the `mcp_config_dir/1` error test (now `create_session_dir/2` with a bad workspace: `assert {:error, {:mcp_config_dir, _}}`; keep the `{:mcp_config_dir, error}` rescue in `create_session_dir`), `default_mcp_command`, `close_port`, `drive_port/4,5` startup and folding tests, scrub test, `collect_port_stream` split/drained/bad-line tests. Calls become e.g. `CliHarness.drive_port(script, [], workspace, nil, nil, [], stream: Claude.Stream, error_tag: :claude_port, label: "Claude")`. Tests that go through `Claude.run_turn`/`start_session` stay in `claude_test.exs` untouched.

- [ ] **Step 6: Verify** — `mix test test/symphony_elixir/agent` (same count as Step 1 plus/minus only moved tests), then `mix format --check-formatted && mix lint && mix dialyzer`. Expected: all green, no warnings.

- [ ] **Step 7: Commit**

```bash
git add -A elixir && git commit -m "refactor: extract Agent.CliHarness from Agent.Claude"
```

---

### Task 2: `omp` config, backend registry, runner and orchestrator wiring

**Files:**
- Modify: `lib/symphony_elixir/config/schema.ex` (add after `Claude`, ~271; embed at ~342 and ~498; take-list ~356), `lib/symphony_elixir/config.ex` (~211), `lib/symphony_elixir/agent.ex`, `lib/symphony_elixir/orchestrator.ex` (~2205), `lib/symphony_elixir/agent_runner.ex` (~263)
- Test: `test/symphony_elixir/config_test.exs`, `test/symphony_elixir/agent_test.exs`, `test/symphony_elixir/agent_runner_test.exs`

**Interfaces:**
- Produces: `Config.settings!().omp` with fields `command` (default `"omp"`), `model`, `thinking`, `args` (default `[]`), `allowed_tools` (nil = default set), `linear_mcp_command`, `linear_mcp_args` (default `[]`), `extra_mcp_servers` (default `%{}`); `Agent.module_for("omp") == {:ok, SymphonyElixir.Agent.Omp}`; `Config.backend_command(settings :: map(), backend :: module()) :: String.t()`.

- [ ] **Step 1: Failing tests**

```elixir
# agent_test.exs
test "module_for/1 resolves omp" do
  assert {:ok, SymphonyElixir.Agent.Omp} = SymphonyElixir.Agent.module_for("omp")
end

# config_test.exs (follow the surrounding tests' workflow-writing helper)
test "selecting the omp backend requires a non-blank omp.command" do
  write_workflow_file!(agent: %{backend: "omp"}, omp: %{command: "  "})
  assert {:error, {:invalid_workflow_config, "omp.command can't be blank"}} = Config.validate!()
end

test "omp defaults" do
  write_workflow_file!(agent: %{backend: "omp"})
  omp = Config.settings!().omp
  assert %{command: "omp", args: [], model: nil, thinking: nil, allowed_tools: nil, extra_mcp_servers: %{}} = omp
end

# agent_runner_test.exs: continuation prompt for omp is the short one (no original prompt restated)
test "omp continuation turns use the short continuation prompt" do
  prompt = AgentRunner.__build_turn_prompt__(%Issue{id: "1", identifier: "X-1", title: "t"}, [], 2, 5, SymphonyElixir.Agent.Omp)
  assert prompt =~ "continuation turn #2 of 5"
  refute prompt =~ "fresh process"
end
```

Use the existing test helper names in those files (check how the neighbouring tests write workflows and call `validate!`); if `build_turn_prompt` is private, test through the existing public path the neighbouring Claude continuation test uses instead of `__build_turn_prompt__`.

- [ ] **Step 2: Run** `mix test test/symphony_elixir/agent_test.exs test/symphony_elixir/config_test.exs test/symphony_elixir/agent_runner_test.exs` — expected FAIL (missing module/field).

- [ ] **Step 3: Implement schema**

```elixir
defmodule Omp do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:command, :string, default: "omp")
    field(:model, :string)
    field(:thinking, :string)
    field(:args, {:array, :string}, default: [])
    field(:allowed_tools, {:array, :string})
    field(:linear_mcp_command, :string)
    field(:linear_mcp_args, {:array, :string}, default: [])
    field(:extra_mcp_servers, :map, default: %{})
  end

  @cast_fields [:command, :model, :thinking, :args, :allowed_tools, :linear_mcp_command, :linear_mcp_args, :extra_mcp_servers]

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, @cast_fields, empty_values: [])
    |> validate_inclusion(:thinking, ~w(off minimal low medium high xhigh max auto), message: "is not an omp thinking level")
  end
end
```

Add `embeds_one(:omp, Omp, on_replace: :update, defaults_to_struct: true)`, `cast_embed(:omp, with: &Omp.changeset/2)`, and `:omp` to the `Map.take` list (~356) beside `:claude`.

- [ ] **Step 4: Implement config + registry + wiring**

```elixir
# config.ex, in validate_backend_commands/1 cond, after the claude clause
selected_backend?(settings, "omp") and blank_string?(settings.omp.command) ->
  {:error, {:invalid_workflow_config, "omp.command can't be blank"}}

# config.ex, public
@spec backend_command(map(), module()) :: String.t()
def backend_command(settings, SymphonyElixir.Agent.Claude), do: settings.claude.command
def backend_command(settings, SymphonyElixir.Agent.Omp), do: settings.omp.command
def backend_command(settings, _codex), do: settings.codex.command
```

```elixir
# agent.ex
def module_for("omp"), do: {:ok, SymphonyElixir.Agent.Omp}
```

```elixir
# orchestrator.ex selected_executable/1
settings = Config.settings!()
command = Config.backend_command(settings, backend)
command |> OptionParser.split() |> List.first()
```

```elixir
# agent_runner.ex: generalize the Claude clause head so omp is not given it
# (omp resumes its session, so it takes the generic short continuation clause: no change needed).
```
`AgentRunner.build_turn_prompt/5` already falls through to the short continuation for any backend other than Claude, so no runner code change is required; the test above pins it. Create a compiling `Agent.Omp` stub module only if `module_for` cannot compile without it: `defmodule SymphonyElixir.Agent.Omp do @moduledoc false; @behaviour SymphonyElixir.Agent end` is NOT acceptable as a stub (no-op callbacks); instead order this task after Task 4's module skeleton, or reference the module by atom only (as written, `module_for` returns the atom and compiles without the module existing). Prefer the atom-only form.

- [ ] **Step 5: Run** the three test files — expected PASS. Then `mix lint`.

- [ ] **Step 6: Commit** — `git commit -am "feat: add omp backend config and registry"`.

---

### Task 3: `Agent.Omp.Stream`

**Files:**
- Create: `lib/symphony_elixir/agent/omp/stream.ex`, `test/symphony_elixir/agent/omp/stream_test.exs`, `test/fixtures/omp/success.jsonl`, `test/fixtures/omp/tool_call.jsonl`, `test/fixtures/omp/error.jsonl`

**Interfaces:**
- Consumes: `CliHarness.StreamFolder`, `Agent.Result`.
- Produces: `Omp.Stream.new/0`, `step/2`, `finalize/2`, and `fold(events, exit_status)`; worker-update map identical in shape to `Claude.Stream.worker_update` (`event, timestamp, session_id, usage_scope: :turn, payload, detail, usage: %{input_tokens, output_tokens, cached_tokens, total_tokens}`).

- [ ] **Step 1: Fixtures.** Capture real streams: `cd /tmp && omp -p --mode json --no-session --no-tools --thinking off --model haiku "reply with the single word: ok" > success.jsonl`; `tool_call.jsonl` from a run that reads a file (`--tools read`); `error.jsonl` by forcing failure, e.g. `--model definitely/not-a-model` or an invalid key env. Strip machine paths/ids if any. Copy under `test/fixtures/omp/`.

- [ ] **Step 2: Failing tests**

```elixir
defmodule SymphonyElixir.Agent.Omp.StreamTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent.Omp.Stream
  alias SymphonyElixir.Agent.Result

  defp events(name) do
    "test/fixtures/omp/#{name}.jsonl"
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{} = event} -> [event]
        _ -> []
      end
    end)
  end

  test "success run folds to a done result with summed usage and last assistant text" do
    assert {:ok, %Result{status: :done, summary: "ok", session_id: id, tokens: tokens}} = Stream.fold(events("success"), 0)
    assert is_binary(id)
    assert tokens.output > 0
    assert tokens.total >= tokens.input + tokens.output - 1
  end

  test "input tokens include cache reads and writes" do
    event = %{
      "type" => "message_end",
      "message" => %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "x"}],
        "stopReason" => "stop",
        "usage" => %{"input" => 3, "output" => 4, "cacheRead" => 10, "cacheWrite" => 5, "totalTokens" => 22}
      }
    }

    {acc, update} = Stream.step(event, Stream.new())
    assert acc.tokens == %{input: 18, output: 4, total: 22}
    assert acc.cached_tokens == 15
    assert update.usage.input_tokens == 18
  end

  test "tool execution surfaces the tool name as activity and keeps args in detail only" do
    {acc, update} =
      Stream.step(
        %{"type" => "tool_execution_start", "toolName" => "bash", "args" => %{"command" => "mix test"}},
        Stream.new()
      )

    assert acc.activity == "Using tool: bash"
    assert update.event == :tool_use
    assert update.payload == "Using tool: bash"
    assert update.detail == "bash: mix test"
  end

  test "non-stop final stopReason is an error even with exit 0" do
    assert {:error, {:omp_error, "error"}} = Stream.fold(events("error"), 0)
  end

  test "stream without agent_end is an error" do
    truncated = Enum.reject(events("success"), &(&1["type"] == "agent_end"))
    assert {:error, {:omp_stream, "stream ended without an agent_end event"}} = Stream.fold(truncated, 0)
    assert {:error, {:omp_stream, "nonzero exit without an agent_end event"}} = Stream.fold(truncated, 1)
  end

  test "nonzero exit after a successful agent_end is an error" do
    assert {:error, {:omp_stream, "nonzero exit after successful agent_end"}} = Stream.fold(events("success"), 2)
  end

  test "unknown events are ignored" do
    assert {%Stream{}, nil} = Stream.step(%{"type" => "message_update"}, Stream.new())
  end
end
```

If `error.jsonl` from Step 1 ends with a different `stopReason` string, assert that exact string in `{:omp_error, reason}`; the tuple shape is fixed.

- [ ] **Step 3: Run** `mix test test/symphony_elixir/agent/omp/stream_test.exs` — expected FAIL (module undefined).

- [ ] **Step 4: Implement**

```elixir
defmodule SymphonyElixir.Agent.Omp.Stream do
  @moduledoc """
  Pure folder for `omp --mode json` events.

  Assistant `message_end` events carry per-call usage and the final `stopReason`; `agent_end`
  marks a complete run. Tool input rides only in `detail` (operator-only run history), as in Claude.
  """

  @behaviour SymphonyElixir.Agent.CliHarness.StreamFolder

  alias SymphonyElixir.Agent.Result

  @tool_detail_keys ~w(command file_path path pattern url query description)

  defstruct session_id: nil,
            tokens: %{input: 0, output: 0, total: 0},
            cached_tokens: 0,
            activity: nil,
            activity_kind: :notification,
            activity_detail: nil,
            summary: nil,
            stop_reason: nil,
            error_message: nil,
            saw_agent_end: false

  @type t :: %__MODULE__{}

  @impl true
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec fold([map()], integer() | nil) :: {:ok, Result.t()} | {:error, term()}
  def fold(events, exit_status) do
    events
    |> Enum.reduce(new(), fn event, acc -> elem(step(event, acc), 0) end)
    |> finalize(exit_status)
  end

  @impl true
  @spec step(map(), t()) :: {t(), map() | nil}
  def step(%{"type" => "session"} = event, acc) do
    acc = %{acc | session_id: Map.get(event, "id", acc.session_id)}
    {acc, worker_update(:session_started, acc)}
  end

  def step(%{"type" => "message_end", "message" => %{"role" => "assistant"} = message}, acc) do
    acc =
      acc
      |> apply_usage(message["usage"])
      |> apply_text(message["content"])
      |> Map.merge(%{stop_reason: message["stopReason"], error_message: message["errorMessage"]})

    {acc, worker_update(acc.activity_kind, acc)}
  end

  def step(%{"type" => "tool_execution_start", "toolName" => name} = event, acc) when is_binary(name) do
    name = String.slice(name, 0, 200)

    acc = %{
      acc
      | activity: "Using tool: " <> name,
        activity_kind: :tool_use,
        activity_detail: tool_detail(name, event["args"])
    }

    {acc, worker_update(:tool_use, acc)}
  end

  def step(%{"type" => "agent_end"}, acc) do
    acc = %{acc | saw_agent_end: true}
    kind = if acc.stop_reason == "stop", do: :completed, else: :error
    {acc, worker_update(kind, acc)}
  end

  def step(_event, acc), do: {acc, nil}

  @impl true
  @spec finalize(t(), integer() | nil) :: {:ok, Result.t()} | {:error, term()}
  def finalize(%__MODULE__{saw_agent_end: true, stop_reason: "stop"} = acc, status) when status in [0, nil] do
    {:ok, Result.new(status: :done, session_id: acc.session_id, tokens: acc.tokens, summary: acc.summary)}
  end

  def finalize(%__MODULE__{saw_agent_end: true, stop_reason: "stop"}, _status),
    do: {:error, {:omp_stream, "nonzero exit after successful agent_end"}}

  def finalize(%__MODULE__{saw_agent_end: true, stop_reason: reason}, _status),
    do: {:error, {:omp_error, to_string(reason || "unknown")}}

  def finalize(%__MODULE__{}, status) when status in [0, nil],
    do: {:error, {:omp_stream, "stream ended without an agent_end event"}}

  def finalize(%__MODULE__{}, _status), do: {:error, {:omp_stream, "nonzero exit without an agent_end event"}}

  defp apply_usage(acc, %{} = usage) do
    cache = Map.get(usage, "cacheRead", 0) + Map.get(usage, "cacheWrite", 0)
    input = Map.get(usage, "input", 0) + cache
    output = Map.get(usage, "output", 0)
    total = Map.get(usage, "totalTokens", input + output)

    %{
      acc
      | tokens: %{
          input: acc.tokens.input + input,
          output: acc.tokens.output + output,
          total: acc.tokens.total + total
        },
        cached_tokens: acc.cached_tokens + cache
    }
  end

  defp apply_usage(acc, _usage), do: acc

  defp apply_text(acc, content) when is_list(content) do
    text = for %{"type" => "text", "text" => t} when is_binary(t) <- content, into: "", do: t

    if text == "" do
      acc
    else
      %{acc | summary: text, activity: String.slice(text, 0, 500), activity_kind: :notification, activity_detail: nil}
    end
  end

  defp apply_text(acc, _content), do: acc

  defp tool_detail(name, input) when is_map(input) do
    case Enum.find(@tool_detail_keys, &(is_binary(input[&1]) and input[&1] != "")) do
      nil -> nil
      key -> name <> ": " <> String.slice(input[key], 0, 300)
    end
  end

  defp tool_detail(_name, _input), do: nil

  defp worker_update(kind, acc) do
    %{
      event: kind,
      timestamp: DateTime.utc_now(),
      session_id: acc.session_id,
      usage_scope: :turn,
      payload: acc.activity || "omp #{kind}",
      detail: acc.activity_detail,
      usage: %{
        input_tokens: acc.tokens.input,
        output_tokens: acc.tokens.output,
        cached_tokens: acc.cached_tokens,
        total_tokens: acc.tokens.total
      }
    }
  end
end
```

Note `apply_text` keeps the last non-empty assistant text as `summary` (replace, not append): omp emits one assistant message per LLM call and the final one is the answer.

- [ ] **Step 5: Run** stream tests — expected PASS. `mix lint`.

- [ ] **Step 6: Commit** — `git add -A elixir && git commit -m "feat: add omp stream folder"`.

---

### Task 4: `Agent.Omp` local execution with hermetic isolation

**Files:**
- Create: `lib/symphony_elixir/agent/omp.ex`, `test/symphony_elixir/agent/omp_test.exs`

**Interfaces:**
- Consumes: `CliHarness.*` (Task 1), `Omp.Stream` (Task 3), `Config.settings!().omp` (Task 2), `Tracker.bind_agent_tools/0`, `Workflow.current/0`, `Workflow.render/2`.
- Produces: `Agent.Omp` implementing `start_session/2`, `run_turn/4`, `stop_session/1`. Session map keys: `workspace, execution_context, session_dir, cleanup_monitor, workflow_snapshot_path, secret_environment_names, tool_specs, omp_settings`. Public `@doc false` helpers used by tests and Task 5: `overlay_yaml/0 :: String.t()`, `mcp_config(workflow_path, command, omp, tracker_env) :: map()`, `argv(session_paths, omp, tool_specs, continue?) :: [String.t()]`, `tool_allowlist(omp, tool_specs) :: [String.t()]`.

Session dir layout (`<session_dir>` from `CliHarness.create_session_dir("symphony-omp", workspace)`):

```
<session_dir>/WORKFLOW.md          workflow snapshot (tracker section only, as Claude)
<session_dir>/overlay.yml          hermetic omp settings overlay
<session_dir>/agent/mcp.json       {"mcpServers": {...}} with the symphony server
<session_dir>/sessions/            omp --session-dir (persists across turns)
```

- [ ] **Step 1: Failing tests**

```elixir
defmodule SymphonyElixir.Agent.OmpTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.{Omp, Result}

  test "overlay disables project MCP config and every foreign discovery provider except native" do
    yaml = Omp.overlay_yaml()
    assert yaml =~ "enableProjectConfig: false"

    for id <- ~w(omp-plugins claude agent-plugins codex agents claude-plugins gemini opencode cursor
                 windsurf cline github vscode agents-md mcp-json ssh-json) do
      assert yaml =~ id
    end

    refute yaml =~ "native"
  end

  test "mcp_config declares only symphony plus configured servers, symphony wins collisions" do
    omp = %{linear_mcp_command: nil, linear_mcp_args: ["--x"], extra_mcp_servers: %{"symphony" => %{"command" => "evil"}, "other" => %{"command" => "o"}}}
    cfg = Omp.mcp_config("/w/WORKFLOW.md", "/bin/symphony", omp, %{"TOKEN" => "t"})
    assert %{"command" => "/bin/symphony", "args" => ["--x", "--linear-mcp", "--workflow", "/w/WORKFLOW.md"], "env" => %{"TOKEN" => "t"}} = cfg["mcpServers"]["symphony"]
    assert cfg["mcpServers"]["other"]["command"] == "o"
  end

  test "argv omits --continue on turn 1 and includes it afterwards; flags are hermetic" do
    omp = %{args: ["--foo"], model: "openrouter/x/y", thinking: "high", allowed_tools: nil}
    paths = %{sessions_dir: "/s/sessions", overlay_path: "/s/overlay.yml"}
    first = Omp.argv(paths, omp, [%{"name" => "linear_graphql"}], false)
    later = Omp.argv(paths, omp, [%{"name" => "linear_graphql"}], true)

    assert hd(first) == "--foo"
    for flag <- ~w(-p --no-extensions --no-skills --no-rules --no-title), do: assert(flag in first)
    assert ["--mode", "json"] == Enum.slice(first, Enum.find_index(first, &(&1 == "--mode")), 2)
    assert "--continue" in later and "--continue" not in first
    assert argv_value(first, "--model") == "openrouter/x/y"
    assert argv_value(first, "--thinking") == "high"
    assert argv_value(first, "--approval-mode") == "yolo"
    assert argv_value(first, "--config") == "/s/overlay.yml"
    assert argv_value(first, "--session-dir") == "/s/sessions"
    tools = argv_value(first, "--tools") |> String.split(",")
    assert "mcp__symphony__linear_graphql" in tools and "bash" in tools
  end

  test "end to end: private agent dir env, stdin prompt, --continue on the second turn, folded result" do
    # fake `omp` writes PI_CODING_AGENT_DIR, argv and stdin to capture files and emits a success stream
    # (mirror the fake-script + workflow setup of claude_test.exs "run_turn" tests)
    ...
  end

  defp argv_value(argv, flag), do: Enum.at(argv, Enum.find_index(argv, &(&1 == flag)) + 1)
end
```

Replace the `...` end-to-end body by copying the fake-script scaffolding from the existing `claude_test.exs` run_turn tests (workspace + `write_workflow_file!` with `agent: %{backend: "omp"}, omp: %{command: fake_omp}`, `Agent.Omp.start_session/2` with `execution_context: local_context`, two `run_turn/4` calls). Assertions: turn 1 argv lacks `--continue`, turn 2 has it; `PI_CODING_AGENT_DIR` captured equals `<session_dir>/agent` and `<that>/mcp.json` exists and parses; overlay file exists; stdin capture equals the prompt; tracker secret env var is absent from the child env; `Result` is `:done`; after `stop_session/1` the session dir is gone. Add: a failing fake (`stopReason":"error"`) yields `{:error, {:omp_error, "error"}}`; a missing executable yields `{:error, {:executable_not_found, _}}`.

- [ ] **Step 2: Run** `mix test test/symphony_elixir/agent/omp_test.exs` — expected FAIL.

- [ ] **Step 3: Implement.** Structure mirrors `Agent.Claude` (`start_session` lines 40-97, `run_turn` 99-109, `stop_session` 111-126). Key code:

```elixir
@providers_to_disable ~w(omp-plugins claude agent-plugins codex agents claude-plugins gemini opencode
                         cursor windsurf cline github vscode agents-md mcp-json ssh-json)
@default_non_tracker_tools ~w(read grep find edit write bash)

@doc false
@spec overlay_yaml() :: String.t()
def overlay_yaml do
  providers = Enum.map_join(@providers_to_disable, "\n", &"  - #{&1}")
  "mcp:\n  enableProjectConfig: false\ndisabledProviders:\n#{providers}\n"
end

@doc false
@spec mcp_config(Path.t(), String.t() | nil, map(), map()) :: map()
def mcp_config(workflow_path, command, omp, tracker_env) do
  %{
    "mcpServers" =>
      Map.merge(omp.extra_mcp_servers || %{}, %{
        "symphony" => %{
          "command" => command || omp.linear_mcp_command || CliHarness.default_mcp_command(),
          "args" => omp.linear_mcp_args ++ ["--linear-mcp", "--workflow", workflow_path],
          "env" => tracker_env
        }
      })
  }
end

@doc false
@spec tool_allowlist(map(), [map()]) :: [String.t()]
def tool_allowlist(%{allowed_tools: tools}, tool_specs) when is_list(tools), do: tools ++ tracker_tools(tool_specs)
def tool_allowlist(_omp, tool_specs), do: @default_non_tracker_tools ++ tracker_tools(tool_specs)

defp tracker_tools(specs) do
  for %{"name" => name} when is_binary(name) <- specs, do: "mcp__symphony__#{name}"
end

@doc false
@spec argv(map(), map(), [map()], boolean()) :: [String.t()]
def argv(%{sessions_dir: sessions, overlay_path: overlay}, omp, tool_specs, continue?) do
  omp.args ++
    ["-p", "--mode", "json", "--no-title", "--no-extensions", "--no-skills", "--no-rules",
     "--approval-mode", "yolo", "--config", overlay, "--session-dir", sessions,
     "--tools", Enum.join(tool_allowlist(omp, tool_specs), ",")] ++
    if(continue?, do: ["--continue"], else: []) ++
    opt("--model", omp.model) ++ opt("--thinking", omp.thinking)
end

defp opt(_flag, nil), do: []
defp opt(flag, value), do: [flag, value]
```

`start_session/2`: same `require_context`/`workspace_cwd` (copy the three small private helpers, they touch `Config`/`Workspace`/`ExecutionContext`; if duplication bothers reviewers, move them into `CliHarness` as `require_context/1` and `workspace_cwd/2` in this task and switch Claude to them). Create the dir via `CliHarness.create_session_dir("symphony-omp", expanded_workspace)`, `mkdir_p` `agent/` and `sessions/` (chmod 0700), write `WORKFLOW.md`, `overlay.yml`, `agent/mcp.json` with `CliHarness.write_private_file/2` (`Jason.encode!`; map encode errors to `{:omp_mcp_config_encode, path}`), clean up on failure like `cleanup_failed_session` in Claude.

`run_turn/4` local path:

```elixir
defp run_local(session, workspace, prompt, on_message) do
  agent_dir = Path.join(session.session_dir, "agent")
  paths = %{sessions_dir: Path.join(session.session_dir, "sessions"), overlay_path: Path.join(session.session_dir, "overlay.yml")}
  continue? = paths.sessions_dir |> File.ls() |> then(&match?({:ok, [_ | _]}, &1))

  with {:ok, executable} <- CliHarness.resolve_executable(session.omp_settings.command, :omp_command_not_configured),
       {:ok, prompt_path} <- CliHarness.write_prompt_file(session.session_dir, prompt) do
    try do
      CliHarness.drive_port(
        executable,
        argv(paths, session.omp_settings, session.tool_specs, continue?),
        workspace,
        on_message,
        prompt_path,
        session.secret_environment_names,
        stream: Stream,
        error_tag: :omp_port,
        label: "omp",
        env: [{~c"PI_CODING_AGENT_DIR", String.to_charlist(agent_dir)}]
      )
    after
      _ = File.rm(prompt_path)
    end
  end
end
```

`stop_session/1`: `CliHarness.remove_session_dir(session.session_dir, session[:cleanup_monitor])`. The remote clause is added in Task 5. For remote contexts in this task, `run_turn` returns `{:error, :omp_remote_unavailable}` only until Task 5 replaces the clause; Task 5 must delete that clause (it is not a permanent path).

- [ ] **Step 4: Run** the omp test file — expected PASS. Then `mix test test/symphony_elixir/agent`, `mix lint`.

- [ ] **Step 5: Real isolation smoke (manual, record output in the commit body).** With `OPENROUTER_API_KEY` or `ANTHROPIC_API_KEY` exported, run a throwaway script exercising `start_session`/`run_turn` with a workspace containing a `.mcp.json` declaring a leak server and a fake `~/.claude`-style server; ask the agent "list tool names starting with mcp__". Expected: only `mcp__symphony__*` (or none if tracker specs empty), and no stderr warnings naming the leak servers.

- [ ] **Step 6: Commit** — `git add -A elixir && git commit -m "feat: add omp agent backend (local)"`.

---

### Task 5: `Agent.Omp` over SSH and managed contexts

**Files:**
- Modify: `lib/symphony_elixir/agent/omp.ex`
- Create: `test/symphony_elixir/agent/omp_ssh_test.exs`

**Interfaces:**
- Consumes: `CliHarness.remote_mktemp_function/0`, `read_length_prefixed_file/2`, `shell_escape/1`, `remote_temp_path/2`, `collect_port_stream/4`, `tracker_secret_unset_command/1`; `SSH.start_port/3`, `SSH.write_stdin/2`, `SSH.run/3`.
- Produces: `Omp.remote_command(workspace :: String.t(), remote_dir :: String.t()) :: String.t()` (`@doc false`, for the never-contains-the-prompt test); session key `remote_dir` (`"/tmp/symphony-omp-" <> token`, set at `start_session` when the context is remote; nothing remote is touched at start).

Remote turn design (mirrors Claude's length-prefixed stdin protocol). Payload order: `WORKFLOW.md`, `mcp.json`, `overlay.yml`, prompt, each as `<bytes>\n<content>`. The remote script:

```
cd <workspace> && umask 077
&& mkdir -p <dir>/agent <dir>/sessions && chmod 700 <dir>
&& read+write <dir>/WORKFLOW.md, <dir>/agent/mcp.json, <dir>/overlay.yml
&& IFS= read -r symphony_prompt_bytes && case ... esac
&& unset <tracker secrets>
&& symphony_continue=""; [ -n "$(ls -A <dir>/sessions 2>/dev/null)" ] && symphony_continue=--continue
&& dd bs=1 count="$symphony_prompt_bytes" 2>/dev/null | PI_CODING_AGENT_DIR=<dir>/agent <omp> <argv...> $symphony_continue
```

`--continue` is omitted from `argv/4` here (call it with `continue?: false`) and supplied by the shell variable, so the argv used remotely is the same builder as local. `omp` runs with the workflow path `<dir>/WORKFLOW.md` in `mcp.json` (rebuild the config with `mcp_config(remote_workflow_path, remote_mcp_command(), omp, tracker_env)` exactly as Claude's `drive_ssh` does, reading `tracker_env` back from the local `mcp.json`).

- [ ] **Step 1: Failing tests** (`omp_ssh_test.exs`, modeled on `claude_ssh_test.exs`)

```elixir
test "remote_command/2 never contains the prompt text and is hermetic" do
  command = Omp.remote_command("/work/dir", "/tmp/symphony-omp-abc")
  refute command =~ "rm -rf /"
  assert command =~ "PI_CODING_AGENT_DIR="
  assert command =~ "--no-extensions"
  assert command =~ "--mode json"
  assert command =~ "--continue"
  assert command =~ "omp"
end

# Then, mirroring the `for transport <- [:static, :structured]` block in claude_ssh_test.exs:
# - run_turn over ssh delivers the prompt via stdin and folds the stream
# - second run_turn adds --continue (fake ssh keeps the remote dir on local disk, fake omp records argv)
# - tracker secrets are absent from the ssh argv and unset before omp runs
# - stop_session runs `rm -rf <remote_dir>` through ssh
# - managed context: start_session requires a :managed ExecutionContext when worker.environment is set
```

Reuse the fake `ssh` script scaffolding from `claude_ssh_test.exs` (PATH override, trace file) rather than inventing a new harness.

- [ ] **Step 2: Run** `mix test test/symphony_elixir/agent/omp_ssh_test.exs` — expected FAIL.

- [ ] **Step 3: Implement** `drive_ssh/4`, `build_remote_command/3`, `ssh_payload/4`, the `stop_session/1` remote clause (`SSH.run(host, "rm -rf " <> CliHarness.shell_escape(dir))`, ignoring errors, plus removing the local session dir), and delete the temporary `:omp_remote_unavailable` clause from Task 4. Rescue tag `{:omp_ssh_port, error}`. The `sessions/` non-empty check and `PI_CODING_AGENT_DIR` prefix are in `build_remote_command/3`; everything else follows `Claude.build_remote_command/4` (lines 519-539) with `read_length_prefixed_file("overlay", ...)` added.

- [ ] **Step 4: Run** omp SSH tests and the whole agent dir — expected PASS. `mix lint`.

- [ ] **Step 5: Commit** — `git add -A elixir && git commit -m "feat: run the omp backend over ssh and managed contexts"`.

---

### Task 6: Lane editor, docs, `SPEC.md`, gate

**Files:**
- Modify: `lib/symphony_elixir_web/live/lane_editor_live.ex` (fields ~61-66, select ~274, section ~291-300), `SPEC.md` (~531, ~808, ~1206, ~2713), `elixir/README.md` (~165, ~828, ~895, ~997), `elixir/WORKFLOW.md` (~151), `.claude/docs/architecture.md`, `.claude/docs/configuration.md`, root `CLAUDE.md` (backend list in "Repository shape")
- Test: `test/symphony_elixir_web/` lane editor test (find with `grep -rl claude_command test/`)

**Interfaces:**
- Consumes: `omp.*` schema (Task 2). Produces: editor form keys `omp_command`, `omp_model`, `omp_thinking`, `omp_args`, `omp_allowed_tools`, `omp_linear_mcp_command`, `omp_linear_mcp_args`, `omp_extra_mcp_servers_json`.

- [ ] **Step 1: Failing editor test** — copy the existing claude-section test: with `agent_backend: "omp"` the omp settings block renders and `claude_command` does not; saving `omp_model: "openrouter/anthropic/claude-sonnet-4"` persists `omp.model`.

- [ ] **Step 2: Implement** — add the `{"omp_...", ["omp", ...], type}` rows after the Claude rows (types: `:text` for command/model/thinking/linear_mcp_command, `:list` for args/allowed_tools/linear_mcp_args, `:json` for extra servers), the `<option value="omp">omp</option>` entry, and an `:if={@params["agent_backend"] == "omp"}` block copied from the Claude block with `omp-` ids and `prefix="omp."` errors.

- [ ] **Step 3: Docs.** `SPEC.md`: `agent.backend` values gain `omp`; add `omp.*` keys to the config cheat sheet (~808) and backend section (~1206); note omp's session-resume per issue and lack of approval channel. `elixir/README.md`: supported backends, an "omp backend" subsection with the Credentials section from the design spec (env API keys, auth broker vars, the `agent.db` limitation), the hermetic isolation summary, the SSH/managed requirement that omp be installed and authenticated on the host, and the Docker note that omp is not in the image. `elixir/WORKFLOW.md`: commented `omp:` example including an OpenRouter model. Architecture and configuration docs: `Agent.module_for` now lists `omp`, `Agent.CliHarness` exists.

- [ ] **Step 4: Full gate** — from `elixir/`: `make all`. Expected: setup, build, fmt-check, lint (specs + credo), coverage >= 80%, dialyzer all pass.

- [ ] **Step 5: Real smoke, both paths** (record commands and output in the PR description; do not commit scripts): (a) local: memory-tracker issue, `agent.backend: omp`, `omp.model` set to a cheap model with a real key in env, `max_turns: 2`; observe turn 1 then a `--continue` turn in the run history, non-zero token counts, and no foreign MCP servers connecting. (b) SSH: same against `localhost` ssh worker if available; otherwise state that only the fake-ssh tests exercised it.

- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: expose omp backend in lane editor and docs"`.

---

## Self-review

**Spec coverage:** architecture/extraction (T1), config table and registry, touchpoints in orchestrator/runner/validation (T2), event folding and error mapping (T3), per-turn flags, `--continue`, isolation, credentials via env (T4), SSH and managed with remote session dir (T5), lane editor + all named docs + `make all` + real smoke (T6). Spec non-goals (pi, approvals bridge, rpc) have no tasks by design.

**Known risks the executor must surface, not hide:** (1) real-omp isolation smoke in T4 Step 5 is the only proof the hermetic recipe holds on other omp versions; a failure there blocks T5. (2) omp `error.jsonl` fixture's actual `stopReason` string decides the literal in one assertion. (3) Moving Claude's `require_context`/`workspace_cwd` into the harness is optional in T4; do it if the duplicate exceeds ~15 lines.

**Type consistency:** `drive_port/7` opts keys (`stream`, `error_tag`, `label`, `env`) are used identically in T1 and T4; `argv/4` signature `(paths, omp, tool_specs, continue?)` is identical in T4 tests, T4 code and T5; session key `omp_settings` is used in T4 `run_local`, and `remote_dir` is introduced in T5 only.
