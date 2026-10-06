import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const c = new Client({ name: "e2e", version: "1.0.0" });
await c.connect(new StdioClientTransport({ command: process.execPath, args: [join(here, "index.mjs")] }));

console.log("tools:", (await c.listTools()).tools.map((t) => t.name).join(", "));

const status = await c.callTool({ name: "openclaw_status", arguments: {} });
console.log("\n--- openclaw_status ---\n" + status.content[0].text.slice(0, 1500));

const ask = await c.callTool({
  name: "ask_openclaw",
  arguments: {
    prompt: "In one short sentence, state which model you are running on. Quote this verbatim: \"it's $(not) `expanded`\". Then output OPENCLAW-MCP-OK.",
    timeout_sec: 240,
  },
}, undefined, { timeout: 400000 });
console.log("\n--- ask_openclaw (isError=" + !!ask.isError + ") ---\n" + ask.content[0].text);

await c.close();
