import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { readFileSync } from "node:fs";

export type McpTool = { name: string; description?: string; inputSchema?: Record<string, unknown> };
export type McpResult = { isError?: boolean; content?: { type: string; text?: string }[] };
type BridgeConfig = { command: string; args: string[]; env: Record<string, string>; timeoutMs: number };
type Pending = { resolve: (v: any) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> };

export class McpClient {
  private child: ChildProcessWithoutNullStreams;
  private timeoutMs: number;
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private buffer = "";
  private failure: Error | null = null;

  constructor(cfg: { command: string; args: string[]; env: Record<string, string>; cwd: string }, timeoutMs: number) {
    this.timeoutMs = timeoutMs;
    // stderr is discarded: the server may log request bodies.
    this.child = spawn(cfg.command, cfg.args, {
      cwd: cfg.cwd,
      env: { ...process.env, ...cfg.env },
      stdio: ["pipe", "pipe", "ignore"],
    });
    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (chunk: string) => this.onData(chunk));
    this.child.on("error", (e) => this.fail(new Error(`MCP server failed to start: ${e.message}`)));
    // "close" fires after stdio drains, so a final response written just before exit is not lost.
    this.child.on("close", (code) => this.fail(new Error(`MCP server exited (code ${code})`)));
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
  process.once("exit", () => client.close());
}
