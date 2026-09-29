# pi Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `pi` (`agent.backend: pi`) as a fourth `Agent` backend, driven per turn via `pi -p --mode json`, with tracker tools delivered by a Symphony-shipped pi extension that bridges to the existing MCP server.

**Architecture:** `Agent.Pi` mirrors `Agent.Omp` (per-turn process, `--session-dir` + `--continue`, private `PI_CODING_AGENT_DIR`, local + SSH + managed). The omp JSON folder becomes a shared `Agent.PiFamily.Stream`. Pieces both backends use identically move into `Agent.CliHarness`. A TypeScript extension (`priv/pi/symphony-mcp-bridge.ts`) speaks minimal MCP over stdio to `symphony --linear-mcp` and registers each tool with `pi.registerTool()`.

**Tech Stack:** Elixir 1.19 / OTP 28, ExUnit, Jason; TypeScript (no build step, loaded by `pi -e`), Node 24 `node:test` for the bridge tests. Run `mix` from `elixir/`.

**Spec:** `docs/superpowers/specs/2026-09-29-pi-backend-design.md` (with its "Verification results"). Builds on merged omp work (PR #53).

## Global Constraints

- Every public `def` in `lib/` needs `@spec`; line length 120; `credo --strict` clean; coverage >= 80%; `make all` passes at the end (known machine-specific failing test: orchestrator "SSH startup cleanup cannot delete through a stable root symlink", fails without these changes).
- Clean cutover: when code moves, migrate every caller and test; no shims.
- Omp behavior must not change: its existing tests stay green unmodified except for renamed/moved helpers.
- Logs never contain prompt or secret bodies. Tracker secret values only in 0600 files and length-prefixed stdin, never argv, and never in pi's process environment.
- Credentials come from the process environment only (`OPENROUTER_API_KEY` etc.); Symphony never stores provider keys.
- pi facts (probed on pi 0.79.1): prompt via stdin works with `-p`; `--continue` with `--session-dir` resumes context; `-e file.ts` loads TypeScript with no build and works with `--no-extensions`; `--tools` accepts explicit names only (no globs); default tools are `read, bash, edit, write`; JSON stream matches omp's (`session` v3 header, `message_end` with assistant `usage` and `stopReason`, `agent_end`).
- Hermetic pi flags (verified): env `PI_CODING_AGENT_DIR=<private>/agent`; `<private>/agent/settings.json` = `{"defaultProjectTrust":"never","packages":[]}`; flags `--offline --no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files --no-approve`; explicit `-e <bridge.ts>`.
- The bridge must skip the MCP tool named `approval_prompt` (the server lists it for Claude); pi has no approval channel.
- Bridge config is a 0600 file whose path is passed in env `SYMPHONY_BRIDGE_CONFIG` (path is not secret); secrets are never put in pi's env, so pi's own bash tool children cannot read them from `env`. Correction to the spec's env-var description: the spec is updated in Task 3.
- New behavior/config: update `SPEC.md`, `elixir/README.md`, `elixir/WORKFLOW.md`, `.claude/docs/architecture.md`, `.claude/docs/configuration.md`, root `CLAUDE.md` backend list in the same change.

## File Structure

| File | Responsibility |
|---|---|
| `lib/symphony_elixir/agent/pi_family/stream.ex` (new, from `omp/stream.ex`) | Shared pure folder; struct carries `error_tag` and `stream_tag` |
| `lib/symphony_elixir/agent/omp/stream.ex` (modify) | 3-function delegator with omp tags |
| `lib/symphony_elixir/agent/pi/stream.ex` (new) | Delegator with pi tags |
| `lib/symphony_elixir/agent/cli_harness.ex` (modify) | Gains `require_context/1`, `workspace_cwd/2`, `mkdir_private/1`, `remove_remote_dir/2`, `ssh_payload/1` |
| `lib/symphony_elixir/agent/omp.ex` (modify) | Uses the moved helpers; no behavior change |
| `priv/pi/symphony-mcp-bridge.ts` (new) | pi extension: minimal MCP client + tool registration |
| `priv/pi/bridge.test.mjs` (new) | `node --test` suite for the bridge, with a fake MCP server script |
| `lib/symphony_elixir/agent/pi.ex` (new) | Session, isolation files, argv, local and SSH turns |
| `lib/symphony_elixir/config/schema.ex`, `config.ex`, `agent.ex` (modify) | `Pi` embed, validation, `backend_command/2`, `module_for("pi")` |
| `lib/symphony_elixir_web/live/lane_editor_live.ex` (modify) | pi section |
| `test/symphony_elixir/agent/pi_test.exs`, `pi_ssh_test.exs`, `pi_bridge_test.exs` (new) | Backend + `node --test` runner |

---

### Task 1: Shared `Agent.PiFamily.Stream`

**Files:**
- Create: `lib/symphony_elixir/agent/pi_family/stream.ex`, `lib/symphony_elixir/agent/pi/stream.ex`, `test/fixtures/pi/success.jsonl`
- Modify: `lib/symphony_elixir/agent/omp/stream.ex`, `lib/symphony_elixir/agent/omp.ex` (alias unchanged), `test/symphony_elixir/agent/omp/stream_test.exs`
- Test: `test/symphony_elixir/agent/pi/stream_test.exs`, `test/symphony_elixir/agent/pi_family/stream_test.exs`

**Interfaces:**
- Produces: `PiFamily.Stream.new(error_tag :: atom(), stream_tag :: atom()) :: t()`, `step/2`, `finalize/2`, `fold/2` (same behavior as today's `Omp.Stream`; errors become `{acc.error_tag, reason}` for stop-reason errors and `{acc.stream_tag, message}` for stream errors). `Omp.Stream` and `Pi.Stream` each implement `CliHarness.StreamFolder` via `new/0` (= `PiFamily.Stream.new(:omp_error, :omp_stream)` / `(:pi_error, :pi_stream)`), `defdelegate step/2`, `defdelegate finalize/2`, and `fold/2`.

- [ ] **Step 1: Failing test** for the pi tags plus a moved-unchanged omp check:

```elixir
defmodule SymphonyElixir.Agent.Pi.StreamTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Agent.Pi.Stream
  alias SymphonyElixir.Agent.Result

  defp events(name) do
    "test/fixtures/pi/#{name}.jsonl" |> File.stream!() |> Enum.flat_map(fn l ->
      case Jason.decode(l) do
        {:ok, %{} = e} -> [e]
        _ -> []
      end
    end)
  end

  test "success run folds to done" do
    assert {:ok, %Result{status: :done, summary: summary}} = Stream.fold(events("success"), 0)
    assert is_binary(summary)
  end

  test "errors use pi tags" do
    truncated = Enum.reject(events("success"), &(&1["type"] == "agent_end"))
    assert {:error, {:pi_stream, "stream ended without an agent_end event"}} = Stream.fold(truncated, 0)
    assert {:error, {:pi_stream, "nonzero exit after successful agent_end"}} = Stream.fold(events("success"), 2)

    errored =
      Enum.map(events("success"), fn
        %{"type" => "message_end", "message" => %{"role" => "assistant"} = m} = e ->
          put_in(e, ["message"], Map.put(m, "stopReason", "error"))
        e -> e
      end)

    assert {:error, {:pi_error, "error"}} = Stream.fold(errored, 0)
  end
end
```

- [ ] **Step 2: Record `test/fixtures/pi/success.jsonl`** from a real pi run against a local fake OpenAI-compatible server (the recipe from the spec's probe: `models.json` with `api: openai-completions`, `compat.supportsDeveloperRole: false`, `supportsReasoningEffort: false`; run `pi -p --mode json --offline --model fake/m ...`). Scrub machine paths (replace cwd with `/workspace`). Also keep one fixture line set with a `tool_execution_start` if obtainable; otherwise reuse omp's `tool_call.jsonl` shape in the family test.

- [ ] **Step 3: Run** `mix test test/symphony_elixir/agent/pi test/symphony_elixir/agent/omp` — expected FAIL (module missing).

- [ ] **Step 4: Implement.** `git mv lib/symphony_elixir/agent/omp/stream.ex lib/symphony_elixir/agent/pi_family/stream.ex`; rename the module to `SymphonyElixir.Agent.PiFamily.Stream`; add `error_tag: :omp_error, stream_tag: :omp_stream` struct fields and `new/2`; `finalize/2` clauses return `{acc.error_tag, ...}` / `{acc.stream_tag, ...}` (the three `:omp_stream` and one `:omp_error` sites). The `@behaviour` line moves to the delegators (the family module keeps `new/0` = omp tags only if needed by the behaviour; drop `@behaviour` from it). Then:

```elixir
defmodule SymphonyElixir.Agent.Omp.Stream do
  @moduledoc "omp event folder: the shared pi-family folder with omp error tags."
  @behaviour SymphonyElixir.Agent.CliHarness.StreamFolder
  alias SymphonyElixir.Agent.PiFamily.Stream, as: Family

  @impl true
  @spec new() :: Family.t()
  def new, do: Family.new(:omp_error, :omp_stream)

  @impl true
  defdelegate step(event, acc), to: Family

  @impl true
  defdelegate finalize(acc, exit_status), to: Family

  @spec fold([map()], integer() | nil) :: {:ok, SymphonyElixir.Agent.Result.t()} | {:error, term()}
  def fold(events, exit_status), do: events |> Enum.reduce(new(), &elem(step(&1, &2), 0)) |> finalize(exit_status)
end
```

`Agent.Pi.Stream` is identical with tags `:pi_error, :pi_stream`. Existing omp stream tests keep their assertions (they call `Omp.Stream`); add `defdelegate` specs as needed for `mix specs.check`.

- [ ] **Step 5: Run** `mix test test/symphony_elixir/agent`, `mix format --check-formatted && mix lint && mix dialyzer` — all green.

- [ ] **Step 6: Commit** — `git add -A elixir && git commit -m "refactor: share the omp event folder as Agent.PiFamily.Stream"`.

---

### Task 2: Move shared omp/pi helpers into `CliHarness`

Pure refactor; omp tests are the net.

**Files:**
- Modify: `lib/symphony_elixir/agent/cli_harness.ex`, `lib/symphony_elixir/agent/omp.ex`
- Test: `test/symphony_elixir/agent/cli_harness_test.exs`

**Interfaces:**
- Produces in `CliHarness` (each with `@spec`): `require_context(context :: term()) :: :ok | {:error, atom()}` (body of `Omp.require_context/1`), `workspace_cwd(workspace, context) :: {:ok, Path.t()} | {:error, term()}` (both `Omp.workspace_cwd/2` clauses), `mkdir_private(path) :: :ok | {:error, term()}`, `remove_remote_dir(host, remote_dir) :: :ok` (bounded 2 s, best effort, body of `Omp.remove_remote_dir/2` with its `@remote_cleanup_timeout_ms`), `ssh_payload([binary()]) :: iodata()` (length-prefixed, body of `Omp.ssh_payload/4` generalized to a list), `new_remote_dir(prefix :: String.t(), context) :: String.t() | nil`.

- [ ] **Step 1: Failing tests** in `cli_harness_test.exs`:

```elixir
test "ssh_payload/1 length-prefixes every part" do
  assert IO.iodata_to_binary(CliHarness.ssh_payload(["ab", "", "xyz"])) == "2\nab0\n3\nxyz"
end

test "mkdir_private/1 creates a 0700 directory" do
  dir = Path.join(System.tmp_dir!(), "harness-#{System.unique_integer([:positive])}/a/b")
  assert :ok = CliHarness.mkdir_private(dir)
  assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
  File.rm_rf!(Path.dirname(Path.dirname(dir)))
end

test "new_remote_dir/2 is nil for local contexts and prefixed for remote ones" do
  local = %SymphonyElixir.ExecutionContext{mode: :local, target: nil}
  assert CliHarness.new_remote_dir("symphony-x", local) == nil
  remote = %SymphonyElixir.ExecutionContext{mode: :static, target: "host"}
  assert "/tmp/symphony-x-" <> _ = CliHarness.new_remote_dir("symphony-x", remote)
end
```

Construct the `ExecutionContext` values the way `omp_ssh_test.exs` builds them (adjust the struct fields to what `ExecutionContext.remote?/1` actually checks).

- [ ] **Step 2: Run** — expected FAIL (functions undefined).
- [ ] **Step 3: Move** the listed Omp private functions into `CliHarness` unchanged (renaming as above), delete them from `Omp`, and make `Omp` call `CliHarness.*` (`remote_dir(context)` becomes `CliHarness.new_remote_dir("symphony-omp", context)`; the `@remote_cleanup_timeout_ms` attribute moves too).
- [ ] **Step 4: Run** `mix test test/symphony_elixir/agent` (omp + claude + harness green), `mix lint`.
- [ ] **Step 5: Commit** — `git commit -am "refactor: move shared omp session helpers into CliHarness"`.

---

### Task 3: The pi MCP bridge extension

**Files:**
- Create: `priv/pi/symphony-mcp-bridge.ts`, `priv/pi/bridge.test.mjs`, `priv/pi/fake-mcp-server.mjs`, `test/symphony_elixir/agent/pi_bridge_test.exs`
- Modify: `docs/superpowers/specs/2026-09-29-pi-backend-design.md` (bridge section: config file instead of env vars)

**Interfaces:**
- Produces: TS module exporting `class McpClient` (`constructor(cfg: {command: string; args: string[]; env: Record<string,string>; cwd: string}, timeoutMs: number)`, `start(): Promise<void>`, `listTools(): Promise<McpTool[]>`, `callTool(name: string, args: unknown): Promise<McpResult>`, `close(): void`), `registerBridgeTools(pi, client): Promise<string[]>` returning registered pi tool names (`symphony_<mcp name>`), and `export default async function (pi)` reading `process.env.SYMPHONY_BRIDGE_CONFIG` (JSON file: `{command, args, env, timeoutMs}`; `cwd` = `process.cwd()`), starting the client, registering tools, and closing on `session_shutdown`.
- Elixir side: `mix test` runs `node --test priv/pi/` from `pi_bridge_test.exs` (tagged `:bridge`, skipped with an explicit message when `node` is absent).

- [ ] **Step 1: Write the fake MCP server** `priv/pi/fake-mcp-server.mjs`: newline-delimited JSON-RPC on stdio. Behavior via env `FAKE_MODE`: default replies to `initialize`, ignores `notifications/initialized`, lists tools `[{name:"linear_graphql",description:"q",inputSchema:{type:"object",properties:{query:{type:"string"}},required:["query"]}},{name:"approval_prompt",...}]`, answers `tools/call` `linear_graphql` with `{content:[{type:"text",text:"echo:"+JSON.stringify(arguments)}],isError:false}`; `FAKE_MODE=error` returns `isError:true`; `FAKE_MODE=die` exits right after answering `tools/list`; `FAKE_MODE=hang` never answers `tools/call`.

- [ ] **Step 2: Failing tests** `priv/pi/bridge.test.mjs` (`node:test`, imports the `.ts` via `node --experimental-strip-types`; Node 24 strips types natively):

```js
import test from "node:test";
import assert from "node:assert/strict";
import { McpClient, registerBridgeTools } from "./symphony-mcp-bridge.ts";

const server = (mode) => ({ command: process.execPath, args: [new URL("./fake-mcp-server.mjs", import.meta.url).pathname],
  env: { FAKE_MODE: mode ?? "" }, cwd: process.cwd() });
const fakePi = () => { const tools = []; return { tools, registerTool: (t) => tools.push(t) }; };

test("registers symphony_-prefixed tools and skips approval_prompt", async () => {
  const c = new McpClient(server(), 2000); await c.start();
  const pi = fakePi();
  assert.deepEqual(await registerBridgeTools(pi, c), ["symphony_linear_graphql"]);
  assert.equal(pi.tools[0].parameters.required[0], "query");
  c.close();
});

test("execute forwards arguments and maps content", async () => {
  const c = new McpClient(server(), 2000); await c.start();
  const pi = fakePi(); await registerBridgeTools(pi, c);
  const out = await pi.tools[0].execute("id1", { query: "{a}" }, undefined, undefined, {});
  assert.equal(out.content[0].text, 'echo:{"query":"{a}"}');
  c.close();
});

test("isError becomes a thrown tool error", async () => {
  const c = new McpClient(server("error"), 2000); await c.start();
  const pi = fakePi(); await registerBridgeTools(pi, c);
  await assert.rejects(() => pi.tools[0].execute("i", { query: "x" }), /echo:/);
  c.close();
});

test("call times out instead of hanging", async () => {
  const c = new McpClient(server("hang"), 200); await c.start();
  const pi = fakePi(); await registerBridgeTools(pi, c);
  await assert.rejects(() => pi.tools[0].execute("i", { query: "x" }), /timed out/);
  c.close();
});

test("a dead child fails later calls fast", async () => {
  const c = new McpClient(server("die"), 2000); await c.start();
  const pi = fakePi(); await registerBridgeTools(pi, c);
  await new Promise((r) => setTimeout(r, 100));
  await assert.rejects(() => pi.tools[0].execute("i", { query: "x" }), /exited|closed/);
});

test("stderr and secrets never surface: child env comes from cfg.env only on top of process env", async () => {
  const c = new McpClient({ ...server(), env: { FAKE_MODE: "", SECRET_PROBE: "s3" } }, 2000); await c.start();
  const tools = await c.listTools();
  assert.ok(tools.some((t) => t.name === "linear_graphql"));
  c.close();
});
```

- [ ] **Step 3: Run** `cd elixir && node --experimental-strip-types --test priv/pi/` — expected FAIL (module missing).

- [ ] **Step 4: Implement** `priv/pi/symphony-mcp-bridge.ts`:

```ts
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { readFileSync } from "node:fs";

export type McpTool = { name: string; description?: string; inputSchema?: Record<string, unknown> };
export type McpResult = { isError?: boolean; content?: { type: string; text?: string }[] };
type BridgeConfig = { command: string; args: string[]; env: Record<string, string>; timeoutMs: number };
type Pending = { resolve: (v: any) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> };

export class McpClient {
  private child: ChildProcessWithoutNullStreams;
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private buffer = "";
  private failure: Error | null = null;

  constructor(cfg: { command: string; args: string[]; env: Record<string, string>; cwd: string }, private timeoutMs: number) {
    // stderr is discarded: the server may log request bodies.
    this.child = spawn(cfg.command, cfg.args, {
      cwd: cfg.cwd,
      env: { ...process.env, ...cfg.env },
      stdio: ["pipe", "pipe", "ignore"],
    });
    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (chunk: string) => this.onData(chunk));
    this.child.on("error", (e) => this.fail(new Error(`MCP server failed to start: ${e.message}`)));
    this.child.on("exit", (code) => this.fail(new Error(`MCP server exited (code ${code})`)));
    this.child.stdin.on("error", () => {});
  }

  async start(): Promise<void> {
    await this.request("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "symphony-pi-bridge", version: "0.1.0" },
    });
    this.send({ jsonrpc: "2.0", method: "notifications/initialized" });
  }

  async listTools(): Promise<McpTool[]> {
    const res = await this.request("tools/list", {});
    return res.tools ?? [];
  }

  async callTool(name: string, args: unknown): Promise<McpResult> {
    return this.request("tools/call", { name, arguments: args ?? {} });
  }

  close(): void {
    this.fail(new Error("MCP client closed"));
    this.child.kill();
  }

  private send(message: object): void {
    if (!this.failure) this.child.stdin.write(JSON.stringify(message) + "\n");
  }

  private request(method: string, params: object): Promise<any> {
    if (this.failure) return Promise.reject(this.failure);
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`MCP ${method} timed out after ${this.timeoutMs}ms`));
      }, this.timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.send({ jsonrpc: "2.0", id, method, params });
    });
  }

  private onData(chunk: string): void {
    this.buffer += chunk;
    let index: number;
    while ((index = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, index).trim();
      this.buffer = this.buffer.slice(index + 1);
      if (!line) continue;
      let message: any;
      try { message = JSON.parse(line); } catch { continue; }
      const entry = typeof message.id === "number" ? this.pending.get(message.id) : undefined;
      if (!entry) continue;
      this.pending.delete(message.id);
      clearTimeout(entry.timer);
      if (message.error) entry.reject(new Error(String(message.error.message ?? "MCP error")));
      else entry.resolve(message.result ?? {});
    }
  }

  private fail(error: Error): void {
    if (!this.failure) this.failure = error;
    for (const [id, entry] of this.pending) {
      clearTimeout(entry.timer);
      entry.reject(error);
      this.pending.delete(id);
    }
  }
}

export async function registerBridgeTools(pi: any, client: McpClient): Promise<string[]> {
  const names: string[] = [];
  for (const tool of await client.listTools()) {
    if (tool.name === "approval_prompt") continue;
    const name = `symphony_${tool.name}`;
    names.push(name);
    pi.registerTool({
      name,
      label: tool.name,
      description: tool.description ?? tool.name,
      parameters: tool.inputSchema ?? { type: "object", properties: {} },
      async execute(_id: string, params: unknown) {
        const result = await client.callTool(tool.name, params);
        const content = (result.content ?? []).map((c) => ({ type: "text", text: c.text ?? "" }));
        if (result.isError) throw new Error(content.map((c) => c.text).join("\n") || "tool failed");
        return { content, details: {} };
      },
    });
  }
  return names;
}

export default async function (pi: any): Promise<void> {
  const configPath = process.env.SYMPHONY_BRIDGE_CONFIG;
  if (!configPath) throw new Error("SYMPHONY_BRIDGE_CONFIG is not set");
  const cfg: BridgeConfig = JSON.parse(readFileSync(configPath, "utf8"));
  const client = new McpClient({ ...cfg, cwd: process.cwd() }, cfg.timeoutMs);
  await client.start();
  await registerBridgeTools(pi, client);
  pi.on("session_shutdown", () => client.close());
}
```

If the "dead child fails fast" test observes the `exit` race (child exits before `fail` runs), keep the assertion regex as written; both messages match.

- [ ] **Step 5: Elixir runner** `pi_bridge_test.exs`:

```elixir
defmodule SymphonyElixir.Agent.PiBridgeTest do
  use ExUnit.Case, async: false
  @moduletag :bridge

  test "bridge node tests pass" do
    case System.find_executable("node") do
      nil -> IO.puts("skipping: node not installed")
      node ->
        {out, status} = System.cmd(node, ["--experimental-strip-types", "--test", "priv/pi/"], stderr_to_stdout: true)
        assert status == 0, out
    end
  end
end
```

Exclude nothing by default; `mix test` runs it (the run must use the `elixir/` cwd).

- [ ] **Step 6: Spec fix.** In the spec's "Bridge behavior" step 1 and the "Tracker secrets" paragraph replace the `SYMPHONY_MCP_*` env-var description with: the bridge reads `SYMPHONY_BRIDGE_CONFIG` (path to a 0600 JSON file `{command,args,env,timeoutMs}`); secrets live only in that file, never in pi's environment.

- [ ] **Step 7: Run** `mix test test/symphony_elixir/agent/pi_bridge_test.exs` and the node suite directly — expected PASS. `mix lint`.
- [ ] **Step 8: Commit** — `git add -A && git commit -m "feat: add pi extension bridging to the tracker MCP server"`.

---

### Task 4: `pi.*` config and registry

**Files:**
- Modify: `lib/symphony_elixir/config/schema.ex` (new `Pi` embed after `Omp`; `embeds_one`, `cast_embed`, take-list), `lib/symphony_elixir/config.ex` (blank check + `backend_command/2`), `lib/symphony_elixir/agent.ex`
- Test: `test/symphony_elixir/config_test.exs`, `test/symphony_elixir/agent_test.exs`

**Interfaces:**
- Produces: `Config.settings!().pi` with `command` (default `"pi"`), `model`, `thinking` (inclusion `off minimal low medium high xhigh`), `args` (default `[]`), `allowed_tools` (nil = default set), `linear_mcp_command`, `linear_mcp_args` (default `[]`); `Agent.module_for("pi") == {:ok, SymphonyElixir.Agent.Pi}` (atom-only); `Config.backend_command(settings, SymphonyElixir.Agent.Pi)`; error `"pi.command can't be blank"`.

- [ ] **Step 1: Failing tests** mirroring Task 2 of the omp plan (`module_for("pi")`, blank-command validation, defaults, `thinking` rejects `"max"` and `"auto"` but accepts `"xhigh"`, `backend_command/2`). Follow the neighbouring omp tests in `config_test.exs` for helpers.
- [ ] **Step 2: Run** them — expected FAIL.
- [ ] **Step 3: Implement** the `Pi` embed by copying `Omp` minus `extra_mcp_servers`; `validate_inclusion(:thinking, ~w(off minimal low medium high xhigh), message: "is not a pi thinking level")`; extend `backend_command/2`, the blank-command `cond`, `module_for/1`; add `:pi` to the schema take-list next to `:omp`.
- [ ] **Step 4: Run** the two files, `mix lint`. **Step 5: Commit** — `git commit -am "feat: add pi backend config and registry"`.

---

### Task 5: `Agent.Pi` local execution

**Files:**
- Create: `lib/symphony_elixir/agent/pi.ex`, `test/symphony_elixir/agent/pi_test.exs`
- Modify: `test/support/test_support.exs` (add a `pi_command` option beside `omp_command`)

**Interfaces:**
- Consumes: `CliHarness.*` (incl. Task 2 helpers), `Pi.Stream` (Task 1), the bridge file (Task 3), `Config.settings!().pi` (Task 4), `Tracker.bind_agent_tools/0`, `Workflow`.
- Produces: `Agent.Pi` (`start_session/2`, `run_turn/4`, `stop_session/1`); `@doc false` helpers `settings_json/0 :: String.t()`, `bridge_config(command, args, env, timeout_ms) :: map()`, `tool_allowlist(pi, tool_specs) :: [String.t()]`, `argv(paths, pi, tool_specs, continue?) :: [String.t()]` with `paths :: %{sessions_dir, bridge_path}`. Session keys: `workspace, execution_context, session_dir, cleanup_monitor, workflow_snapshot_path, secret_environment_names, tool_specs, pi_settings, remote_dir`.

Session dir layout (`CliHarness.create_session_dir("symphony-pi", workspace)`):

```
<session_dir>/WORKFLOW.md              tracker-only workflow snapshot
<session_dir>/bridge.ts                the extension text (embedded at compile time)
<session_dir>/bridge.json              0600 {command,args,env,timeoutMs}
<session_dir>/agent/settings.json      {"defaultProjectTrust":"never","packages":[]}
<session_dir>/sessions/                pi --session-dir (persists across turns)
```

The extension text is embedded so escripts and releases need no `priv` at runtime:

```elixir
@bridge_path Path.expand("../../../priv/pi/symphony-mcp-bridge.ts", __DIR__)
@external_resource @bridge_path
@bridge_source File.read!(@bridge_path)
```

Adjust the relative path to the real location of `pi.ex` (`lib/symphony_elixir/agent/pi.ex` -> `../../../priv/pi/...` is `elixir/priv/pi/...`).

- [ ] **Step 1: Failing tests** (`pi_test.exs`, `use SymphonyElixir.TestSupport`; copy the fake-script/workflow scaffolding from `omp_test.exs`):

```elixir
test "settings_json disables project trust and packages" do
  assert %{"defaultProjectTrust" => "never", "packages" => []} = Jason.decode!(Pi.settings_json())
end

test "bridge_config carries the tracker server launch and timeout" do
  cfg = Pi.bridge_config("/bin/symphony", ["--linear-mcp", "--workflow", "/w"], %{"T" => "t"}, 30_000)
  assert cfg == %{"command" => "/bin/symphony", "args" => ["--linear-mcp", "--workflow", "/w"],
                  "env" => %{"T" => "t"}, "timeoutMs" => 30_000}
end

test "allowlist is explicit names: built-ins plus symphony_ tool names" do
  tools = Pi.tool_allowlist(%{allowed_tools: nil}, [%{"name" => "linear_graphql"}])
  assert tools == ~w(read bash edit write grep find ls symphony_linear_graphql)
  assert Pi.tool_allowlist(%{allowed_tools: ["read"]}, [%{"name" => "x"}]) == ["read", "symphony_x"]
end

test "argv is hermetic, turn 1 has no --continue, later turns do" do
  pi = %{args: ["--foo"], model: "openrouter/x/y", thinking: "high", allowed_tools: nil}
  paths = %{sessions_dir: "/s/sessions", bridge_path: "/s/bridge.ts"}
  first = Pi.argv(paths, pi, [%{"name" => "linear_graphql"}], false)
  later = Pi.argv(paths, pi, [%{"name" => "linear_graphql"}], true)
  assert hd(first) == "--foo"
  for f <- ~w(-p --offline --no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files --no-approve), do: assert(f in first)
  assert value(first, "--mode") == "json" and value(first, "-e") == "/s/bridge.ts"
  assert value(first, "--session-dir") == "/s/sessions"
  assert value(first, "--model") == "openrouter/x/y" and value(first, "--thinking") == "high"
  assert "symphony_linear_graphql" in String.split(value(first, "--tools"), ",")
  assert "--continue" in later and "--continue" not in first
end
```

plus an end-to-end test with a fake `pi` script (copy of `omp_test.exs`'s e2e; fake records `PI_CODING_AGENT_DIR`, `SYMPHONY_BRIDGE_CONFIG`, argv, stdin, and its env): turn 1 lacks `--continue`, turn 2 has it; `PI_CODING_AGENT_DIR == <session_dir>/agent` with `settings.json` present; `SYMPHONY_BRIDGE_CONFIG` names an existing 0600 file whose JSON has `command/args/env/timeoutMs` and whose `env` holds the tracker secret; the child env does NOT contain the tracker secret name; stdin equals the prompt; result `:done` with tokens; error stream -> `{:error, {:pi_error, "error"}}`; missing executable -> `{:error, {:executable_not_found, _}}`; `stop_session/1` removes the dir. Remote contexts return `{:error, :pi_remote_unavailable}` in this task only (one-line test; Task 6 deletes clause and test).

- [ ] **Step 2: Run** `mix test test/symphony_elixir/agent/pi_test.exs` — expected FAIL.
- [ ] **Step 3: Implement** `Agent.Pi` following `Agent.Omp` structure now that shared helpers live in `CliHarness`:

```elixir
@default_tools ~w(read bash edit write grep find ls)

@doc false
@spec settings_json() :: String.t()
def settings_json, do: Jason.encode!(%{"defaultProjectTrust" => "never", "packages" => []})

@doc false
@spec bridge_config(String.t(), [String.t()], map(), pos_integer()) :: map()
def bridge_config(command, args, env, timeout_ms),
  do: %{"command" => command, "args" => args, "env" => env, "timeoutMs" => timeout_ms}

@doc false
@spec tool_allowlist(map(), [map()]) :: [String.t()]
def tool_allowlist(%{allowed_tools: tools}, specs) when is_list(tools), do: tools ++ bridge_tools(specs)
def tool_allowlist(_pi, specs), do: @default_tools ++ bridge_tools(specs)

defp bridge_tools(specs), do: for(%{"name" => n} when is_binary(n) <- specs, do: "symphony_" <> n)

@doc false
@spec argv(map(), map(), [map()], boolean()) :: [String.t()]
def argv(%{sessions_dir: sessions, bridge_path: bridge}, pi, specs, continue?) do
  pi.args ++
    ["-p", "--mode", "json", "--offline", "--no-extensions", "--no-skills", "--no-prompt-templates",
     "--no-themes", "--no-context-files", "--no-approve", "-e", bridge, "--session-dir", sessions,
     "--tools", Enum.join(tool_allowlist(pi, specs), ",")] ++
    if(continue?, do: ["--continue"], else: []) ++ opt("--model", pi.model) ++ opt("--thinking", pi.thinking)
end
```

`start_session/2`: same flow as `Omp.start_session/2` (require_context, workspace_cwd, capture_tracker_env, `Workflow.current`, `CliHarness.create_session_dir("symphony-pi", ...)`), then writes the layout above with `CliHarness.write_private_file/2` / `mkdir_private/1`. The bridge config is `bridge_config(CliHarness.default_mcp_command() (or pi.linear_mcp_command), pi.linear_mcp_args ++ ["--linear-mcp", "--workflow", workflow_path], tracker_env, Config.settings!().codex.turn_timeout_ms)`. `run_local/4` mirrors `Omp.run_local/4` with `env: [{~c"PI_CODING_AGENT_DIR", ...}, {~c"SYMPHONY_BRIDGE_CONFIG", ...}]`, `stream: Pi.Stream`, `error_tag: :pi_port`, `label: "pi"`, `continue?` from a non-empty `sessions/`.

- [ ] **Step 4: Run** pi tests, whole agent dir, `mix lint`.
- [ ] **Step 5: Real hermetic smoke** (record in the commit body, do not commit scripts): fake OpenAI-compatible server + private agent dir as in the spec probe, but through the real `Agent.Pi.start_session/run_turn` with a workspace containing `.pi/extensions/leak.ts`, `AGENTS.md`, and a memory-tracker workflow; assert the request's tool names are exactly the allowlist (bridge tools present, no `leak_project_tool`) and no planted markers reach the model. If a real provider key exists, also do one turn that calls a bridge tool end to end; otherwise state that no real model turn ran.
- [ ] **Step 6: Commit** — `git add -A elixir && git commit -m "feat: add pi agent backend (local)"`.

---

### Task 6: `Agent.Pi` over SSH and managed contexts

**Files:**
- Modify: `lib/symphony_elixir/agent/pi.ex`
- Create: `test/symphony_elixir/agent/pi_ssh_test.exs`

**Interfaces:**
- Consumes: `CliHarness.ssh_payload/1`, `remove_remote_dir/2`, `new_remote_dir/2`, `read_length_prefixed_file/2`, `shell_escape/1`, `tracker_secret_unset_command/1`, `collect_port_stream/4`; `SSH.start_port/3`, `SSH.write_stdin/2`.
- Produces: `Pi.remote_command(workspace, remote_dir) :: String.t()` (`@doc false`); session key `remote_dir` set by `start_session` for remote contexts via `CliHarness.new_remote_dir("symphony-pi", context)`.

Remote turn (same length-prefixed stdin protocol as omp): payload parts in order `WORKFLOW.md`, `bridge.ts`, `bridge.json`, `settings.json`, prompt. The remote script: `cd <workspace> && umask 077 && trap 'rm -f <secret files>' EXIT HUP INT TERM && mkdir -p <dir>/agent <dir>/sessions && chmod 700 <dir>` then read each part to `<dir>/WORKFLOW.md`, `<dir>/bridge.ts`, `<dir>/bridge.json`, `<dir>/agent/settings.json`, then the prompt-length line, `unset` tracker secrets, choose `--continue` if `<dir>/sessions` is non-empty, and finally `dd ... | PI_CODING_AGENT_DIR=<dir>/agent SYMPHONY_BRIDGE_CONFIG=<dir>/bridge.json <pi> <argv from Pi.argv(paths, pi, specs, false)> $symphony_continue`. `bridge.json` is rebuilt for the remote (`--workflow <dir>/WORKFLOW.md`, tracker env read back from the local `bridge.json`, command `pi.linear_mcp_command || "symphony"`). The trap removes only `bridge.json`, `WORKFLOW.md` (secret-bearing); `bridge.ts` and `agent/settings.json` are not secret and `sessions/` persists. `stop_session/1` removes the local dir first, then `CliHarness.remove_remote_dir/2`.

- [ ] **Step 1: Failing tests** (`pi_ssh_test.exs`, modeled on `omp_ssh_test.exs`, static and structured transports): `remote_command/2` never contains prompt text, quotes every interpolated value, contains `PI_CODING_AGENT_DIR=`, `SYMPHONY_BRIDGE_CONFIG=`, `--no-extensions`, `--no-approve`, `--tools`, and `$symphony_continue`; a two-turn run over fake ssh delivers the prompt via stdin, gets `--continue` on turn 2, the fake `pi` sees its env without tracker secrets, tracker secrets are absent from the ssh argv, after each turn `bridge.json` and `WORKFLOW.md` are gone from the fake remote disk while `sessions/` remains, and `stop_session/1` returns `:ok` with the local dir gone even when ssh hangs (bounded, fast). Managed: `start_session` requires a `:managed` context when `worker.environment` is set.
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement** `drive_ssh/4`, `build_remote_command/4`, `remote_command/2`, the remote `stop_session/1` clause; delete the temporary `:pi_remote_unavailable` clause and its test from Task 5.
- [ ] **Step 4: Run** pi SSH tests, `mix test test/symphony_elixir/agent`, `mix lint`.
- [ ] **Step 5: Commit** — `git add -A elixir && git commit -m "feat: run the pi backend over ssh and managed contexts"`.

---

### Task 7: Lane editor, docs, `SPEC.md`, gate

**Files:**
- Modify: `lib/symphony_elixir_web/live/lane_editor_live.ex`, `SPEC.md`, `elixir/README.md`, `elixir/WORKFLOW.md`, `.claude/docs/architecture.md`, `.claude/docs/configuration.md`, root `CLAUDE.md`
- Test: `test/symphony_elixir_web/lane_editor_live_test.exs`

**Interfaces:**
- Consumes: `pi.*` schema (Task 4). Produces editor form keys `pi_command, pi_model, pi_thinking, pi_args, pi_allowed_tools, pi_linear_mcp_command, pi_linear_mcp_args` (no `extra_mcp_servers`).

- [ ] **Step 1: Failing editor test**: with `agent_backend: "pi"` the pi block renders and the omp/claude blocks do not; saving `pi_model: "openrouter/anthropic/claude-sonnet-4"`, `pi_args` (list) and `pi_allowed_tools` (list) persists `pi.model`, `pi.args`, `pi.allowed_tools` with correct types. Copy the omp editor test.
- [ ] **Step 2: Implement** the rows (`:text` command/model/thinking/linear_mcp_command; `:list` args/allowed_tools/linear_mcp_args), the `<option value="pi">pi</option>` entry, and the `:if={@params["agent_backend"] == "pi"}` block copied from the omp block minus the extra MCP servers field.
- [ ] **Step 3: Docs.** `SPEC.md`: `agent.backend` gains `pi`; `pi.*` keys; per-turn resume; no approval channel. `elixir/README.md` "pi backend" subsection: credentials from environment only (API keys; `auth.json`-only logins invisible to lanes); the hermetic isolation recipe (flags + private `settings.json`); the bridge extension (delivered by Symphony, needs `node`-free pi only, tools named `symphony_*`); unsandboxed daemon-user privileges with tracker credentials in a same-user 0600 `bridge.json` the agent can read; `--tools` are explicit names so `allowed_tools` lists built-ins only and bridge tools are added automatically; pi must be installed and credentialed on SSH/managed hosts; not in the Docker image. `WORKFLOW.md`: commented `pi:` example with an OpenRouter model. Architecture/configuration docs and root `CLAUDE.md` backend lists: add `pi`, `Agent.PiFamily.Stream`, the bridge.
- [ ] **Step 4: Gate** — `make all` from `elixir/`; report exactly what ran and any failure, distinguishing the known machine-specific orchestrator test. Coverage >= 80%.
- [ ] **Step 5: Real smoke** — if a provider key is available: a memory-tracker issue, `agent.backend: pi`, cheap model, `max_turns: 2`; observe a `--continue` turn and a bridge tool call in run history. Otherwise run the fake-server smoke through `Agent.Pi` and state precisely what was not verified (no real model turn, no real SSH host).
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: expose pi backend in lane editor and docs"`.

---

## Self-review

**Spec coverage:** shared folder and tags (T1); shared harness pieces (T2); bridge with MCP client, `approval_prompt` skip, timeouts, dead-child, no-secrets-in-env (T3); config and registry (T4); isolation flags, private settings, explicit-name allowlist, resume, credentials from env, secret scrub (T5); SSH/managed with trap cleanup, bounded stop (T6); lane editor, all named docs, gate, smoke (T7). Non-goals (approval bridge, package install, rpc, per-state model) have no tasks.

**Known risks for the executor to surface:** (1) T3's bridge is only tested against a fake MCP server; the real `symphony --linear-mcp` server and a real pi loading the bridge are only exercised in T5 Step 5 (fake model). (2) T5's `-e` path: the same bridge file must be loadable by pi's TypeScript loader without `node --experimental-strip-types`, verified in the spec probe with a plain `.ts` extension, but the bridge uses `node:child_process`/`node:fs` and `export class`; if pi's loader rejects a construct, T5 Step 5 will show it. (3) T2 requires reading `ExecutionContext` fields to build test values.

**Type consistency:** `PiFamily.Stream.new/2`, `Omp.Stream`/`Pi.Stream` delegators (T1) match `CliHarness.drive_port` opts `stream: mod`; `CliHarness.ssh_payload/1`, `new_remote_dir/2`, `remove_remote_dir/2`, `mkdir_private/1`, `require_context/1`, `workspace_cwd/2` (T2) are the names T5/T6 call; `Pi.argv/4 (paths, pi, tool_specs, continue?)` with `paths %{sessions_dir, bridge_path}` is identical in T5 and T6; `SYMPHONY_BRIDGE_CONFIG` and `bridge.json` keys `command, args, env, timeoutMs` match between T3 (reader) and T5/T6 (writer).
