#!/usr/bin/env node
/**
 * hermes-mcp — exposes the Hermes Agent CLI (Nous Research) as an MCP server over stdio.
 * Hermes has no MCP server mode of its own (`hermes-acp` speaks ACP), so this wraps its
 * one-shot mode: `hermes chat --query-file - -Q`. The prompt goes in via stdin, so quotes,
 * backticks and $(...) reach Hermes verbatim. Override the binary with HERMES_BIN.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir, platform } from "node:os";
import { join } from "node:path";
import { z } from "zod";

const HOME = homedir();
const IS_WIN = platform() === "win32";

function resolveHermesBin() {
  const candidates = [
    process.env.HERMES_BIN,
    join(process.env.LOCALAPPDATA ?? "", "hermes", "bin", "hermes.exe"),
    join(HOME, ".local", "bin", "hermes"),
    "/usr/local/bin/hermes",
  ].filter(Boolean);
  return candidates.find((p) => existsSync(p)) ?? null;
}

const HERMES_BIN = resolveHermesBin();
const CHILD_ENV = { ...process.env, NO_COLOR: "1", TERM: "dumb", PYTHONIOENCODING: "utf-8" };

// hermes.exe is a launcher shim around a Python process; a plain kill() would orphan the Python child.
function killTree(child) {
  if (IS_WIN) spawnSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore" });
  else child.kill("SIGKILL");
}

function runProcess(args, { stdin, cwd, timeoutSec }) {
  return new Promise((resolve) => {
    const child = spawn(HERMES_BIN, args, {
      cwd: cwd && existsSync(cwd) ? cwd : process.cwd(),
      stdio: ["pipe", "pipe", "pipe"],
      env: CHILD_ENV,
      windowsHide: true,
    });
    let stdout = "", stderr = "", settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      killTree(child);
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

async function runHermes({ prompt, context, model, provider, cwd, toolsets, yolo, maxTurns, session, timeoutSec }) {
  if (!HERMES_BIN) return { ok: false, text: "Hermes CLI not found. Install Hermes Agent or set HERMES_BIN." };

  // --source tool keeps these runs out of the user's own session list in the Hermes UI.
  // stream-json (implies -Q) reports which model actually answered, so a silent fallback is visible.
  const args = ["chat", "--query-file", "-", "--format", "stream-json", "--source", "tool",
                "--max-turns", String(maxTurns),
                "--run-budget", String(Math.max(30, timeoutSec - 15))];
  if (model) args.push("-m", model);
  if (provider) args.push("--provider", provider);
  if (cwd && existsSync(cwd)) args.push("--in", cwd);
  if (toolsets) args.push("-t", toolsets);
  if (yolo) args.push("--yolo");
  if (session) args.push("-c", session, "--create-if-missing");

  const stdin = context ? `${prompt}\n\n---\n${context}` : prompt;
  const r = await runProcess(args, { stdin, cwd, timeoutSec });
  const ev = parseStream(r.stdout);
  const body = ev.text || r.stdout.trim();

  if (r.launchError) return { ok: false, text: `Failed to launch Hermes CLI: ${r.launchError}` };
  if (r.timedOut) return { ok: false, text: `Hermes timed out after ${timeoutSec}s.\n\nPartial output:\n${body.slice(-4000)}` };
  if (r.code !== 0 || (ev.exitCode != null && ev.exitCode !== 0)) {
    const hint = /api key|not logged in|auth|credits|billing|isn't available|not found/i.test(body + r.stderr)
      ? "\n\nThis looks like a provider/model problem. Call hermes_status, or pass model/provider explicitly " +
        "(free Nous models: poolside/laguna-s-2.1:free, stepfun/step-3.7-flash:free)."
      : "";
    return { ok: false, text: `Hermes exited with code ${r.code}.\n\nstdout:\n${body.slice(-4000)}\n\nstderr:\n${r.stderr.trim().slice(-4000)}${hint}` };
  }
  const meta = [
    ev.models.length ? `model=${ev.models.join(" -> ")}` : null,
    ev.tokens != null ? `tokens=${ev.tokens}` : null,
    ev.durationMs != null ? `${Math.round(ev.durationMs / 1000)}s` : null,
    ev.sessionId ? `session_id=${ev.sessionId}` : null,
  ].filter(Boolean);
  return { ok: true, text: (body || "(Hermes returned no output.)") + (meta.length ? `\n\n[hermes: ${meta.join(", ")}]` : "") };
}

// JSONL events from `--format stream-json`: system/init carries the model, text events the reply,
// result the final text, exit code and usage. Any later event naming a different model means a fallback.
function parseStream(stdout) {
  const ev = { text: "", models: [], sessionId: null, exitCode: null, tokens: null, durationMs: null };
  const chunks = [];
  for (const line of stdout.split(/\r?\n/)) {
    if (!line.trim().startsWith("{")) continue;
    let e;
    try { e = JSON.parse(line); } catch { continue; }
    if (e.model && ev.models[ev.models.length - 1] !== e.model) ev.models.push(e.model);
    if (e.session_id) ev.sessionId = e.session_id;
    if (e.type === "text" && e.text) chunks.push(e.text);
    if (e.type === "error" && (e.message || e.text)) chunks.push(`[error] ${e.message || e.text}`);
    if (e.type === "result") {
      if (typeof e.text === "string") ev.text = e.text;
      if (e.exit_code != null) ev.exitCode = e.exit_code;
      if (e.tokens?.total != null) ev.tokens = e.tokens.total;
      if (e.duration_ms != null) ev.durationMs = e.duration_ms;
    }
  }
  if (!ev.text) ev.text = chunks.join("");
  return ev;
}

const server = new McpServer({ name: "hermes", version: "1.0.0" });

server.registerTool(
  "ask_hermes",
  {
    title: "Ask Hermes",
    description:
      "Delegate a task to Hermes Agent (Nous Research) running on this Windows PC and return its final " +
      "answer. Hermes is a full agent with its own tools (terminal, files, web, skills, memory), so it can " +
      "do multi-step work, not just answer. Default model is the free Nous Portal model from its config. " +
      "Dangerous commands are NOT auto-approved unless yolo=true.",
    inputSchema: {
      prompt: z.string().min(1).describe("The task or question for Hermes."),
      context: z.string().optional().describe("Optional bulk context (file contents, logs). Appended after the prompt via stdin."),
      model: z.string().optional().describe("Model override, e.g. 'poolside/laguna-s-2.1:free' or 'stepfun/step-3.7-flash:free'. Omit for the config default."),
      provider: z.string().optional().describe("Provider override, e.g. 'nous', 'copilot', 'anthropic'. Omit for the config default."),
      cwd: z.string().optional().describe("Working directory for the Hermes session (passed as --in)."),
      toolsets: z.string().optional().describe("Comma-separated toolsets to enable, limiting what Hermes may use."),
      yolo: z.boolean().default(false).describe("Bypass Hermes' dangerous-command approval prompts. Leave false unless explicitly needed."),
      max_turns: z.number().int().min(1).max(200).default(30).describe("Max tool-calling iterations for this run."),
      session: z.string().optional().describe("Named Hermes session to continue (created if missing), for multi-call conversations."),
      timeout_sec: z.number().int().min(30).max(3600).default(600).describe("Kill Hermes after this many seconds."),
    },
  },
  async ({ prompt, context, model, provider, cwd, toolsets, yolo, max_turns, session, timeout_sec }) => {
    const r = await runHermes({ prompt, context, model, provider, cwd, toolsets, yolo, maxTurns: max_turns, session, timeoutSec: timeout_sec });
    return { content: [{ type: "text", text: r.text }], isError: !r.ok };
  }
);

server.registerTool(
  "hermes_status",
  {
    title: "Hermes status",
    description:
      "Resolved binary path and Hermes' own status report (provider login, model, components). " +
      "Call this first when ask_hermes fails.",
    inputSchema: {},
  },
  async () => {
    const lines = [`binary : ${HERMES_BIN ?? "NOT FOUND"}`];
    if (HERMES_BIN) {
      const r = await runProcess(["status"], { timeoutSec: 60 });
      const out = (r.stdout + r.stderr).trim()
        // Never echo anything that looks like a credential back into the caller's transcript.
        .replace(/((?:key|token|secret)\S*\s*[:=]\s*)\S{12,}/gi, "$1<redacted>");
      lines.push("", r.timedOut ? "(timed out asking `hermes status`)" : out || "(no output)");
    }
    return { content: [{ type: "text", text: lines.join("\n") }] };
  }
);

await server.connect(new StdioServerTransport());
