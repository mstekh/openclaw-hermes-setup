#!/usr/bin/env node
/**
 * openclaw-mcp — exposes an OpenClaw agent as an MCP server over stdio.
 * The OpenClaw gateway runs inside the WSL distro that the OpenClaw Windows tray app manages
 * (default "OpenClawGateway"), so this calls `openclaw agent ... --json` there through wsl.exe.
 * `--message-file /dev/stdin` is refused under wsl.exe (EACCES), hence the temp file.
 * Override with OPENCLAW_WSL_DISTRO / OPENCLAW_BIN.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { spawn } from "node:child_process";
import { z } from "zod";

const DISTRO = process.env.OPENCLAW_WSL_DISTRO || "OpenClawGateway";
const OPENCLAW_BIN = process.env.OPENCLAW_BIN || "/usr/local/bin/openclaw";

// Runs inside WSL. Args after "_" arrive as "$@" untouched: `wsl -e` bypasses any shell parsing of them.
const AGENT_SCRIPT =
  'f=$(mktemp); cat > "$f"; "$0" agent "$@" --message-file "$f"; rc=$?; rm -f "$f"; exit $rc';

function runWsl(argv, { stdin, timeoutSec }) {
  return new Promise((resolve) => {
    const child = spawn("wsl.exe", ["-d", DISTRO, "-e", ...argv], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    let stdout = "", stderr = "", settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill();
      resolve({ code: null, timedOut: true, stdout, stderr });
    }, timeoutSec * 1000);
    child.stdout.on("data", (d) => (stdout += d.toString("utf8")));
    child.stderr.on("data", (d) => (stderr += d.toString("utf8")));
    child.on("error", (err) => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      resolve({ code: null, launchError: err.message, stdout, stderr });
    });
    child.on("close", (code) => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
    if (stdin) child.stdin.write(stdin);
    child.stdin.end();
  });
}

function parseJson(text) {
  const start = text.indexOf("{");
  if (start < 0) return null;
  try { return JSON.parse(text.slice(start)); } catch { return null; }
}

function summarize(res) {
  const r = res.result ?? {};
  const text = (r.payloads ?? []).map((p) => p.text).filter(Boolean).join("\n\n").trim();
  const meta = r.meta?.agentMeta ?? {};
  const eff = meta.terminalReceipt?.effective ?? {};
  const parts = [
    `model=${eff.responseModel || eff.model || meta.model || "?"}`,
    meta.costUsd != null ? `cost=$${Number(meta.costUsd).toFixed(4)}` : null,
    r.meta?.durationMs != null ? `${Math.round(r.meta.durationMs / 1000)}s` : null,
    meta.sessionFile ? `session=${meta.sessionFile}` : null,
  ].filter(Boolean);
  return `${text || "(OpenClaw returned no text.)"}\n\n[openclaw: ${parts.join(", ")}]`;
}

const server = new McpServer({ name: "openclaw", version: "1.0.0" });

server.registerTool(
  "ask_openclaw",
  {
    title: "Ask OpenClaw",
    description:
      "Delegate a task to an OpenClaw agent (gateway in WSL distro " + DISTRO + ") and return its reply. " +
      "OpenClaw is a full personal agent with its own tools, memory, channels and the paired Windows node, " +
      "so it can act, not just answer. Each call gets a fresh session unless `session` is given, so history " +
      "never piles up and nothing mixes into the owner's main chat. Note: each turn sends a large system " +
      "prompt (~30K+ tokens), which eats free-tier quotas fast. Reading Windows files goes through the paired " +
      "Windows node and needs the owner to approve each command in the tray; unattended it is denied.",
    inputSchema: {
      prompt: z.string().min(1).describe("The task or question for OpenClaw."),
      context: z.string().optional().describe("Optional bulk context (file contents, logs). Appended after the prompt."),
      agent: z.string().default("main").describe("OpenClaw agent id."),
      session: z.string().optional().describe("Session key within the agent, to continue a multi-call conversation. Omit for a fresh session per call."),
      model: z.string().optional().describe("Model override for this run (provider/model). Omit for the agent's configured model."),
      thinking: z.enum(["off", "minimal", "low", "medium", "high", "xhigh", "adaptive", "max", "ultra"]).optional()
        .describe("Thinking level, where the model supports it."),
      timeout_sec: z.number().int().min(30).max(3600).default(600).describe("Agent turn timeout in seconds."),
    },
  },
  async ({ prompt, context, agent, session, model, thinking, timeout_sec }) => {
    const key = session || `claude-code-${Date.now().toString(36)}`;
    const args = ["--agent", agent, "--session-key", `agent:${agent}:${key}`, "--json", "--timeout", String(timeout_sec)];
    if (model) args.push("--model", model);
    if (thinking) args.push("--thinking", thinking);
    const stdin = context ? `${prompt}\n\n---\n${context}` : prompt;

    // Extra 60s over the agent's own timeout: a cold WSL distro needs ~1 min before the gateway answers.
    const r = await runWsl(["bash", "-c", AGENT_SCRIPT, OPENCLAW_BIN, ...args], { stdin, timeoutSec: timeout_sec + 60 });
    if (r.launchError) return { content: [{ type: "text", text: `Failed to launch wsl.exe: ${r.launchError}` }], isError: true };
    if (r.timedOut) return { content: [{ type: "text", text: `OpenClaw timed out after ${timeout_sec + 60}s. The turn may still finish inside the gateway.` }], isError: true };

    const res = parseJson(r.stdout);
    if (!res || res.ok === false || (res.status && res.status !== "ok")) {
      const msg = res?.error?.message ?? res?.summary ?? "";
      const hint = /not running|ECONNREFUSED|gateway/i.test(msg + r.stderr)
        ? "\n\nThe gateway may still be starting (it needs ~1 min after WSL boots). Call openclaw_status."
        : "";
      return {
        content: [{ type: "text", text: `OpenClaw failed (exit ${r.code}). ${msg}\n\nstdout:\n${r.stdout.slice(-3000)}\n\nstderr:\n${r.stderr.trim().slice(-3000)}${hint}` }],
        isError: true,
      };
    }
    return { content: [{ type: "text", text: summarize(res) }] };
  }
);

server.registerTool(
  "openclaw_status",
  {
    title: "OpenClaw status",
    description: "Gateway service/runtime status inside WSL (`openclaw gateway status`). Call this first when ask_openclaw fails.",
    inputSchema: {},
  },
  async () => {
    const r = await runWsl([OPENCLAW_BIN, "gateway", "status"], { timeoutSec: 90 });
    const out = r.timedOut ? "(timed out)" : (r.stdout + r.stderr).trim()
      .replace(/(token[=:"\s]+)[A-Za-z0-9_-]{12,}/gi, "$1<redacted>");
    return { content: [{ type: "text", text: `distro : ${DISTRO}\nbinary : ${OPENCLAW_BIN}\n\n${out || r.launchError || "(no output)"}` }] };
  }
);

await server.connect(new StdioServerTransport());
