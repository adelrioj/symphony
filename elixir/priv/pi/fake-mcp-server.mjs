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
    reply(msg.id, { tools });
    if (mode === "die") process.stdout.write("", () => process.exit(0));
  } else if (msg.method === "tools/call") {
    if (mode === "hang") return;
    const text = "echo:" + JSON.stringify(msg.params.arguments);
    reply(msg.id, { content: [{ type: "text", text }], isError: mode === "error" });
  }
});
