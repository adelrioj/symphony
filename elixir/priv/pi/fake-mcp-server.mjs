import { writeFileSync } from "node:fs";
import readline from "node:readline";

const mode = process.env.FAKE_MODE ?? "";
const tools = [
  {
    name: "linear_graphql",
    description: "q",
    inputSchema: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
  },
  { name: "approval_prompt", description: "p", inputSchema: { type: "object", properties: {} } },
];

if (process.env.PID_FILE) writeFileSync(process.env.PID_FILE, String(process.pid));

const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");

readline.createInterface({ input: process.stdin }).on("line", (line) => {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  if (msg.method === "initialize") {
    reply(msg.id, { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "fake", version: "0" } });
  } else if (msg.method === "tools/list") {
    if (mode === "list-error") {
      return process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: msg.id, error: { message: "list failed" } }) + "\n");
    }
    reply(msg.id, { tools });
    if (mode === "die") process.stdout.write("", () => process.exit(0));
  } else if (msg.method === "tools/call") {
    if (mode === "hang") return;
    if (mode === "env") {
      const name = msg.params.arguments.name;
      return reply(msg.id, { content: [{ type: "text", text: String(process.env[name]) }], isError: false });
    }
    if (mode === "unknown-id") reply(msg.id + 1000, { content: [{ type: "text", text: "stray" }] });
    if (mode === "split") {
      const raw = JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text: "whole" }] } }) + "\n";
      process.stdout.write(raw.slice(0, 10));
      return setTimeout(() => process.stdout.write(raw.slice(10)), 50);
    }
    if (mode === "exit-after-reply") {
      const raw = JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text: "last".padEnd(500000, "x") }] } }) + "\n";
      return process.stdout.write(raw, () => process.exit(0));
    }
    const text = "echo:" + JSON.stringify(msg.params.arguments);
    reply(msg.id, { content: [{ type: "text", text }], isError: mode === "error" });
  }
});
