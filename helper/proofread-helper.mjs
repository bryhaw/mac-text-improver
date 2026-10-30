#!/usr/bin/env node
// Line-delimited JSON bridge between the Swift menu-bar app and GitHub Copilot.
// stdin:  {"type":"check","id":1,"text":"...","mode":"fix"|"polish"} | {"type":"cancel","id":1}
//         {"type":"set_model","model":"..."} | {"type":"login"} | {"type":"status"}
// stdout: {"type":"status",...} | {"type":"result","id":1,"text":"..."} | {"type":"error",...}
//         {"type":"login_url","url":"..."}
import { CopilotClient, approveAll } from "@github/copilot-sdk";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import {
  DEFAULT_MODEL,
  SYSTEM_PROMPTS,
  buildPrompt,
  cleanOutput,
  isAuthError,
  reasoningEffortFor,
  validateText,
} from "./proofread-core.mjs";

const REQUEST_TIMEOUT_MS = 45_000;
const BASE_DIR =
  process.env.PROOFREADER_HOME ??
  join(homedir(), "Library", "Application Support", "Copilot Proofreader", "copilot");
mkdirSync(BASE_DIR, { recursive: true });

// Never let ambient env tokens (e.g. a terminal's GH_TOKEN) override the app's own sign-in.
const runtimeEnv = { ...process.env };
for (const key of ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"]) delete runtimeEnv[key];
if (process.env.PROOFREADER_USE_ENV_TOKEN === "1") Object.assign(runtimeEnv, process.env);

const send = (msg) => process.stdout.write(JSON.stringify(msg) + "\n");
const log = (...args) => process.stderr.write(args.join(" ") + "\n");

let client;
let model = process.env.PROOFREADER_MODEL || DEFAULT_MODEL;
let availableModels = [];
let auth = { isAuthenticated: false };
let spare = null; // pre-created session per mode, so a check never waits on session setup
const active = new Map(); // request id -> session

function sessionConfig(mode) {
  const config = {
    model,
    onPermissionRequest: approveAll,
    availableTools: [],
    disabledMcpServers: ["github-mcp-server"],
    enableSessionStore: false,
    systemMessage: { mode: "replace", content: SYSTEM_PROMPTS[mode] },
  };
  const effort = reasoningEffortFor(model);
  if (effort) config.reasoningEffort = effort;
  return config;
}

function prepareSpare() {
  if (spare) {
    spare.session.then((s) => disposeSession(s)).catch(() => {});
    spare = null;
  }
  if (!auth.isAuthenticated) return;
  const pending = { mode: "fix", model, session: client.createSession(sessionConfig("fix")) };
  pending.session.catch(() => {});
  spare = pending;
}

async function takeSession(mode) {
  const current = spare;
  spare = null;
  if (current && current.mode === mode && current.model === model) {
    try {
      const session = await current.session;
      prepareSpare();
      return session;
    } catch {
      // fall through and create a fresh one
    }
  } else if (current) {
    current.session.then((s) => disposeSession(s)).catch(() => {});
  }
  const session = await client.createSession(sessionConfig(mode));
  prepareSpare();
  return session;
}

async function disposeSession(session) {
  try {
    await session.disconnect();
    await client.deleteSession(session.sessionId);
  } catch {
    // best effort; the session store is local and disposable
  }
}

async function refreshStatus() {
  try {
    auth = await client.getAuthStatus();
  } catch (err) {
    auth = { isAuthenticated: false, statusMessage: String(err?.message ?? err) };
  }
  if (auth.isAuthenticated) {
    try {
      const models = await client.listModels();
      availableModels = models
        .filter((m) => m.id !== "auto" && m.policy?.state !== "disabled")
        .map((m) => ({ id: m.id, name: m.name ?? m.id }));
      if (availableModels.length && !availableModels.some((m) => m.id === model)) {
        model = availableModels.some((m) => m.id === DEFAULT_MODEL) ? DEFAULT_MODEL : availableModels[0].id;
      }
    } catch (err) {
      log("listModels failed:", err?.message ?? err);
    }
  }
  send({
    type: "status",
    state: auth.isAuthenticated ? "ready" : "signed_out",
    login: auth.login ?? null,
    message: auth.isAuthenticated ? null : auth.statusMessage ?? "Sign in to GitHub Copilot to start checking text.",
    model,
    models: availableModels,
  });
}

async function handleCheck({ id, text, mode = "fix" }) {
  const problem = validateText(text);
  if (problem) return send({ type: "error", id, message: problem });
  if (!SYSTEM_PROMPTS[mode]) mode = "fix";
  if (!auth.isAuthenticated) {
    return send({ type: "error", id, code: "auth", message: "Sign in to GitHub Copilot first (menu bar → Sign In)." });
  }
  const started = Date.now();
  let session;
  try {
    session = await takeSession(mode);
    active.set(id, session);
    const reply = await session.sendAndWait({ prompt: buildPrompt(text) }, REQUEST_TIMEOUT_MS);
    if (!active.has(id)) return; // cancelled
    const output = cleanOutput(text, reply?.data?.content);
    send({ type: "result", id, text: output, model, ms: Date.now() - started });
  } catch (err) {
    if (!active.has(id)) return;
    const message = String(err?.message ?? err);
    log("check failed:", message);
    const authProblem = isAuthError(message);
    if (authProblem) {
      auth = { isAuthenticated: false };
      refreshStatus();
    }
    send({
      type: "error",
      id,
      code: authProblem ? "auth" : /timeout|timed out/i.test(message) ? "timeout" : "failed",
      message: authProblem
        ? "Copilot needs you to sign in again."
        : /timeout|timed out/i.test(message)
          ? "Copilot took too long to respond. Try again."
          : `Copilot couldn't check that text: ${message}`,
    });
  } finally {
    active.delete(id);
    if (session) disposeSession(session);
  }
}

async function handleCancel({ id }) {
  const session = active.get(id);
  active.delete(id);
  if (session) {
    try {
      await session.abort();
    } catch {
      // already finished
    }
  }
}

let loginInProgress = false;
async function handleLogin() {
  if (loginInProgress) return;
  loginInProgress = true;
  let session;
  let flowId;
  try {
    session = await client.createSession({
      onPermissionRequest: approveAll,
      availableTools: [],
      disabledMcpServers: ["github-mcp-server"],
      enableSessionStore: false,
    });
    const begun = await session.rpc.accounts.login.begin({ kind: "githubDotCom" });
    flowId = begun.flowId;
    let step = begun.step;
    for (let i = 0; i < 20; i++) {
      if (step.kind === "open-url") send({ type: "login_url", url: step.url });
      if (step.kind === "completed") {
        const status = step.result?.status;
        if (status !== "completed") throw new Error(`Sign-in did not complete (${status}).`);
        break;
      }
      if (step.kind === "error") throw new Error(step.message);
      if (step.kind === "input-required") throw new Error(`Sign-in needs input this app can't provide: ${step.prompt}`);
      step = await session.rpc.accounts.login.advance({ flowId });
    }
    send({ type: "login_done" });
  } catch (err) {
    if (flowId && session) session.rpc.accounts.login.cancel?.({ flowId }).catch(() => {});
    send({ type: "error", code: "login", message: `Sign-in failed: ${err?.message ?? err}` });
  } finally {
    loginInProgress = false;
    if (session) disposeSession(session);
    await refreshStatus();
    prepareSpare();
  }
}

async function main() {
  send({ type: "status", state: "starting" });
  client = new CopilotClient({ logLevel: "error", baseDirectory: BASE_DIR, env: runtimeEnv });
  await client.start();
  await refreshStatus();
  prepareSpare();

  const rl = createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      return send({ type: "error", message: "Invalid request" });
    }
    switch (msg.type) {
      case "check":
        handleCheck(msg);
        break;
      case "cancel":
        handleCancel(msg);
        break;
      case "set_model":
        if (typeof msg.model === "string" && msg.model && msg.model !== model) {
          model = msg.model;
          prepareSpare();
        }
        send({ type: "model", model });
        break;
      case "login":
        handleLogin();
        break;
      case "status":
        refreshStatus();
        break;
    }
  });
  rl.on("close", shutdown);
}

let stopping = false;
async function shutdown() {
  if (stopping) return;
  stopping = true;
  try {
    await client?.stop();
  } finally {
    process.exit(0);
  }
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

main().catch((err) => {
  send({ type: "status", state: "error", message: String(err?.message ?? err) });
  log(err?.stack ?? err);
  process.exit(1);
});
