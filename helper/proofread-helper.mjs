#!/usr/bin/env node
// Line-delimited JSON bridge between the Swift menu-bar app and the proofreading provider:
// GitHub Copilot (via the Copilot SDK and your Copilot sign-in) or OpenAI / Anthropic (via your API key).
// stdin:  {"type":"configure","provider":"copilot"|"openai"|"anthropic","model":"..."|null,"apiKey":"..."|null}
//         {"type":"check","id":1,"text":"...","mode":"fix"|"polish"} | {"type":"cancel","id":1}
//         {"type":"set_model","model":"..."} | {"type":"login"} | {"type":"status"}
// stdout: {"type":"status","provider":"...","state":"starting"|"ready"|"signed_out"|"needs_key"|"error",...}
//         {"type":"result","id":1,"text":"..."} | {"type":"error",...} | {"type":"login_url","url":"..."}
// API keys are held in memory only and never written to stdout, stderr, or disk.
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
import { API_PROVIDERS, complete, listModels, redact } from "./providers.mjs";

const REQUEST_TIMEOUT_MS = 45_000;
const STATUS_TIMEOUT_MS = 15_000;
const PROVIDERS = new Set(["copilot", ...Object.keys(API_PROVIDERS)]);
const BASE_DIR =
  process.env.PROOFREADER_HOME ??
  join(homedir(), "Library", "Application Support", "Copilot Proofreader", "copilot");
mkdirSync(BASE_DIR, { recursive: true });

// Never let ambient env tokens (e.g. a terminal's GH_TOKEN) override the app's own sign-in.
const runtimeEnv = { ...process.env };
for (const key of ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"]) delete runtimeEnv[key];
if (process.env.PROOFREADER_USE_ENV_TOKEN === "1") Object.assign(runtimeEnv, process.env);

const send = (msg) => process.stdout.write(JSON.stringify(msg) + "\n");
const log = (...args) => process.stderr.write(redact(args.join(" "), apiKey) + "\n");

const normalizeProvider = (value) => (PROVIDERS.has(value) ? value : "copilot");

let provider = normalizeProvider(process.env.PROOFREADER_PROVIDER);
let model = process.env.PROOFREADER_MODEL || null; // null = provider default
let apiKey = null;
let availableModels = [];
let auth = { isAuthenticated: false };
let client = null;
let clientStarting = null;
let spare = null; // pre-created Copilot session, so a check never waits on session setup
let statusSeq = 0;
const active = new Map(); // request id -> { cancel() }

const providerName = (p = provider) => (p === "copilot" ? "GitHub Copilot" : API_PROVIDERS[p].name);
const currentModel = () => model ?? (provider === "copilot" ? DEFAULT_MODEL : API_PROVIDERS[provider].fallbackModel);

// MARK: - GitHub Copilot

function ensureCopilot() {
  if (client) return Promise.resolve(client);
  if (!clientStarting) {
    clientStarting = (async () => {
      const c = new CopilotClient({ logLevel: "error", baseDirectory: BASE_DIR, env: runtimeEnv });
      await c.start();
      client = c;
      return c;
    })();
    clientStarting.catch(() => {
      clientStarting = null;
    });
  }
  return clientStarting;
}

function sessionConfig(mode) {
  const config = {
    model: currentModel(),
    onPermissionRequest: approveAll,
    availableTools: [],
    disabledMcpServers: ["github-mcp-server"],
    enableSessionStore: false,
    systemMessage: { mode: "replace", content: SYSTEM_PROMPTS[mode] },
  };
  const effort = reasoningEffortFor(config.model);
  if (effort) config.reasoningEffort = effort;
  return config;
}

function discardSpare() {
  if (spare) spare.session.then((s) => disposeSession(s)).catch(() => {});
  spare = null;
}

function prepareSpare() {
  discardSpare();
  if (provider !== "copilot" || !client || !auth.isAuthenticated) return;
  const pending = { mode: "fix", model: currentModel(), session: client.createSession(sessionConfig("fix")) };
  pending.session.catch(() => {});
  spare = pending;
}

async function takeSession(mode) {
  const current = spare;
  spare = null;
  if (current && current.mode === mode && current.model === currentModel()) {
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

async function copilotStatus() {
  try {
    await ensureCopilot();
  } catch (err) {
    return { state: "error", message: `Couldn't start GitHub Copilot: ${err?.message ?? err}` };
  }
  try {
    auth = await client.getAuthStatus();
  } catch (err) {
    auth = { isAuthenticated: false, statusMessage: String(err?.message ?? err) };
  }
  let models = [];
  let chosen = model ?? DEFAULT_MODEL;
  if (auth.isAuthenticated) {
    try {
      models = (await client.listModels())
        .filter((m) => m.id !== "auto" && m.policy?.state !== "disabled")
        .map((m) => ({ id: m.id, name: m.name ?? m.id }));
      if (models.length && !models.some((m) => m.id === chosen)) {
        chosen = models.some((m) => m.id === DEFAULT_MODEL) ? DEFAULT_MODEL : models[0].id;
      }
    } catch (err) {
      log("listModels failed:", err?.message ?? err);
    }
  }
  return {
    state: auth.isAuthenticated ? "ready" : "signed_out",
    login: auth.login ?? null,
    message: auth.isAuthenticated ? null : auth.statusMessage ?? "Sign in to GitHub Copilot to start checking text.",
    models,
    model: chosen,
  };
}

async function copilotCheck(id, text, mode) {
  if (!client || !auth.isAuthenticated) {
    return send({ type: "error", id, code: "auth", message: "Sign in to GitHub Copilot first (menu bar → Sign In)." });
  }
  const started = Date.now();
  let session;
  try {
    session = await takeSession(mode);
    active.set(id, { cancel: () => session.abort() });
    const reply = await session.sendAndWait({ prompt: buildPrompt(text) }, REQUEST_TIMEOUT_MS);
    if (!active.has(id)) return; // cancelled
    const output = cleanOutput(text, reply?.data?.content);
    send({ type: "result", id, text: output, model: currentModel(), ms: Date.now() - started });
  } catch (err) {
    if (!active.has(id)) return;
    const message = String(err?.message ?? err);
    log("check failed:", message);
    const authProblem = isAuthError(message);
    if (authProblem) {
      auth = { isAuthenticated: false };
      refreshStatus();
    }
    const timedOut = /timeout|timed out/i.test(message);
    send({
      type: "error",
      id,
      code: authProblem ? "auth" : timedOut ? "timeout" : "failed",
      message: authProblem
        ? "Copilot needs you to sign in again."
        : timedOut
          ? "Copilot took too long to respond. Try again."
          : `Copilot couldn't check that text: ${message}`,
    });
  } finally {
    active.delete(id);
    if (session) disposeSession(session);
  }
}

// MARK: - API-key providers (OpenAI, Anthropic)

async function apiStatus(p, key) {
  const { name, fallbackModel } = API_PROVIDERS[p];
  if (!key) {
    return { state: "needs_key", message: `Add your ${name} API key to start checking text.`, models: [], model: model ?? fallbackModel };
  }
  try {
    const listed = await listModels(p, { apiKey: key, signal: AbortSignal.timeout(STATUS_TIMEOUT_MS) });
    return { state: "ready", login: null, models: listed.models, model: model ?? listed.defaultModel ?? fallbackModel };
  } catch (err) {
    if (err.code === "auth") {
      return { state: "needs_key", message: `${name} rejected the saved API key. Enter a new one.`, models: [], model: model ?? fallbackModel };
    }
    // Restricted keys may not be allowed to list models, and we may be offline; checks will report real problems.
    log(`${name} model list unavailable:`, err.message);
    return { state: "ready", login: null, models: [], model: model ?? fallbackModel };
  }
}

async function apiCheck(id, text, mode) {
  const p = provider;
  const key = apiKey;
  const m = currentModel();
  const { name } = API_PROVIDERS[p];
  if (!key) {
    return send({ type: "error", id, code: "auth", message: `Add your ${name} API key first (menu bar → Provider).` });
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort("timeout"), REQUEST_TIMEOUT_MS);
  active.set(id, { cancel: () => controller.abort("cancelled") });
  const started = Date.now();
  try {
    const raw = await complete(p, {
      apiKey: key,
      model: m,
      system: SYSTEM_PROMPTS[mode],
      prompt: buildPrompt(text),
      signal: controller.signal,
    });
    if (!active.has(id)) return;
    send({ type: "result", id, text: cleanOutput(text, raw), model: m, ms: Date.now() - started });
  } catch (err) {
    if (!active.has(id)) return;
    const detail = redact(err?.message ?? err, key);
    log("check failed:", err?.code ?? "-", detail);
    if (err?.code === "auth") refreshStatus();
    const messages = {
      auth: `${name} rejected your API key. Update it from the menu bar.`,
      timeout: `${name} took too long to respond. Try again.`,
      not_found: `${name} doesn't recognize the model "${m}". Pick another from the menu bar.`,
      forbidden: `${name} refused the request (${detail}). Check the key's permissions and model access.`,
      rate_limit: `${name} rate limit or quota reached (${detail}).`,
    };
    send({
      type: "error",
      id,
      code: err?.code === "auth" ? "auth" : err?.code === "timeout" ? "timeout" : "failed",
      message: messages[err?.code] ?? `${name} couldn't check that text: ${detail}`,
    });
  } finally {
    clearTimeout(timer);
    active.delete(id);
  }
}

// MARK: - Shared

async function refreshStatus() {
  const seq = ++statusSeq;
  const p = provider;
  const status = p === "copilot" ? await copilotStatus() : await apiStatus(p, apiKey);
  if (seq !== statusSeq || p !== provider) return; // superseded by a newer configure/status request
  availableModels = status.models ?? [];
  // Copilot swaps in a default when the chosen model isn't offered; API providers fill in their default.
  if (status.model && (p === "copilot" ? status.model !== currentModel() : model == null)) model = status.model;
  const resolved = currentModel();
  send({
    type: "status",
    provider: p,
    state: status.state,
    login: status.login ?? null,
    message: status.message ?? null,
    model: resolved,
    models: availableModels,
  });
  if (p === "copilot") prepareSpare();
}

async function handleCheck({ id, text, mode = "fix" }) {
  const problem = validateText(text);
  if (problem) return send({ type: "error", id, message: problem });
  if (!SYSTEM_PROMPTS[mode]) mode = "fix";
  return provider === "copilot" ? copilotCheck(id, text, mode) : apiCheck(id, text, mode);
}

async function handleCancel({ id }) {
  const job = active.get(id);
  active.delete(id);
  try {
    await job?.cancel();
  } catch {
    // already finished
  }
}

function handleConfigure(msg) {
  const next = normalizeProvider(msg.provider);
  if (next !== provider) {
    discardSpare();
    availableModels = [];
  }
  provider = next;
  if ("model" in msg) model = typeof msg.model === "string" && msg.model.trim() ? msg.model.trim() : null;
  if ("apiKey" in msg) apiKey = typeof msg.apiKey === "string" && msg.apiKey.trim() ? msg.apiKey.trim() : null;
  send({ type: "status", provider, state: "starting", model: currentModel(), models: [] });
  refreshStatus();
}

let loginInProgress = false;
async function handleLogin() {
  if (loginInProgress) return;
  loginInProgress = true;
  let session;
  let flowId;
  try {
    await ensureCopilot();
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
  }
}

function main() {
  send({ type: "status", provider, state: "starting", model: currentModel(), models: [] });
  const rl = createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      return send({ type: "error", message: "Invalid request" });
    }
    switch (msg.type) {
      case "configure":
        handleConfigure(msg);
        break;
      case "check":
        handleCheck(msg);
        break;
      case "cancel":
        handleCancel(msg);
        break;
      case "set_model":
        if (typeof msg.model === "string" && msg.model.trim() && msg.model.trim() !== model) {
          model = msg.model.trim();
          prepareSpare();
        }
        send({ type: "model", model: currentModel() });
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
  // The app sends "configure" (with any API key) right after launch. Copilot needs no key,
  // so start it straight away when it's the selected provider.
  if (provider === "copilot") refreshStatus();
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

try {
  main();
} catch (err) {
  send({ type: "status", provider, state: "error", message: String(err?.message ?? err) });
  log(err?.stack ?? err);
  process.exit(1);
}
