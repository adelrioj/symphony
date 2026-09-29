import test from "node:test";
import assert from "node:assert/strict";
import { McpClient, registerBridgeTools } from "./symphony-mcp-bridge.ts";

const server = (mode) => ({
  command: process.execPath,
  args: [new URL("./fake-mcp-server.mjs", import.meta.url).pathname],
  env: { FAKE_MODE: mode ?? "" },
  cwd: process.cwd(),
});
const fakePi = () => {
  const tools = [];
  return { tools, registerTool: (t) => tools.push(t) };
};

test("registers symphony_-prefixed tools and skips approval_prompt", async () => {
  const c = new McpClient(server(), 2000);
  await c.start();
  const pi = fakePi();
  assert.deepEqual(await registerBridgeTools(pi, c), ["symphony_linear_graphql"]);
  assert.equal(pi.tools[0].parameters.required[0], "query");
  c.close();
});

test("execute forwards arguments and maps content", async () => {
  const c = new McpClient(server(), 2000);
  await c.start();
  const pi = fakePi();
  await registerBridgeTools(pi, c);
  const out = await pi.tools[0].execute("id1", { query: "{a}" }, undefined, undefined, {});
  assert.equal(out.content[0].text, 'echo:{"query":"{a}"}');
  c.close();
});

test("isError becomes a thrown tool error", async () => {
  const c = new McpClient(server("error"), 2000);
  await c.start();
  const pi = fakePi();
  await registerBridgeTools(pi, c);
  await assert.rejects(() => pi.tools[0].execute("i", { query: "x" }), /echo:/);
  c.close();
});

test("call times out instead of hanging", async () => {
  const c = new McpClient(server("hang"), 200);
  await c.start();
  const pi = fakePi();
  await registerBridgeTools(pi, c);
  await assert.rejects(() => pi.tools[0].execute("i", { query: "x" }), /timed out/);
  c.close();
});

test("a dead child fails later calls fast", async () => {
  const c = new McpClient(server("die"), 2000);
  await c.start();
  const pi = fakePi();
  await registerBridgeTools(pi, c);
  await new Promise((r) => setTimeout(r, 100));
  await assert.rejects(() => pi.tools[0].execute("i", { query: "x" }), /exited|closed/);
});

test("child env comes from cfg.env on top of process env", async () => {
  const c = new McpClient({ ...server(), env: { FAKE_MODE: "", SECRET_PROBE: "s3" } }, 2000);
  await c.start();
  const tools = await c.listTools();
  assert.ok(tools.some((t) => t.name === "linear_graphql"));
  c.close();
});
