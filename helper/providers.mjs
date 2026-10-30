// Direct API-key providers (OpenAI, Anthropic). Uses the built-in fetch; no extra dependencies.
// API keys arrive from the app over stdin, live only in memory, and are never logged or echoed.

export const API_PROVIDERS = {
  openai: {
    name: "OpenAI",
    baseURL: "https://api.openai.com/v1",
    // Used only when the model list can't be fetched (e.g. a restricted key without model access).
    fallbackModel: "gpt-5-mini",
  },
  anthropic: {
    name: "Anthropic",
    baseURL: "https://api.anthropic.com/v1",
    fallbackModel: "claude-haiku-4-5",
  },
};

const ANTHROPIC_VERSION = "2023-06-01";
const ANTHROPIC_MAX_TOKENS = 8192;
const MAX_LISTED_MODELS = 15;

export class ProviderError extends Error {
  constructor(code, message, status) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

/** Removes API keys (the given ones, plus anything key-shaped) from text before it's shown or logged. */
export function redact(text, ...keys) {
  let out = String(text ?? "");
  for (const key of keys) {
    if (typeof key === "string" && key.length >= 8) out = out.split(key).join("[redacted]");
  }
  return out.replace(/\b(sk-[A-Za-z0-9]{0,4})[A-Za-z0-9_-]{12,}/g, "$1…[redacted]");
}

function codeForStatus(status) {
  if (status === 401) return "auth";
  if (status === 403) return "forbidden";
  if (status === 404) return "not_found";
  if (status === 429) return "rate_limit";
  if (status >= 400 && status < 500) return "bad_request";
  return "server";
}

function headersFor(provider, apiKey) {
  if (provider === "anthropic") {
    return { "x-api-key": apiKey, "anthropic-version": ANTHROPIC_VERSION, "content-type": "application/json" };
  }
  return { authorization: `Bearer ${apiKey}`, "content-type": "application/json" };
}

async function request(provider, path, { apiKey, body, signal, fetchImpl = fetch }) {
  const { name, baseURL } = API_PROVIDERS[provider];
  let res;
  try {
    res = await fetchImpl(`${baseURL}${path}`, {
      method: body ? "POST" : "GET",
      headers: headersFor(provider, apiKey),
      body: body ? JSON.stringify(body) : undefined,
      signal,
    });
  } catch (err) {
    if (signal?.aborted) {
      const reason = signal.reason;
      const timedOut = reason === "timeout" || reason?.name === "TimeoutError";
      throw new ProviderError(timedOut ? "timeout" : "cancelled", timedOut ? `${name} timed out.` : "Cancelled.");
    }
    throw new ProviderError("network", `Couldn't reach ${name}: ${redact(err?.message ?? err, apiKey)}`);
  }
  const raw = await res.text();
  let json;
  try {
    json = JSON.parse(raw);
  } catch {
    json = undefined;
  }
  if (!res.ok) {
    const detail = json?.error?.message ?? raw.slice(0, 200);
    throw new ProviderError(codeForStatus(res.status), `${res.status} ${redact(detail, apiKey)}`.trim(), res.status);
  }
  return json ?? {};
}

// Reasoning models are much faster at low effort; non-reasoning models reject the parameter.
// Try the fastest setting first and remember what each model accepts.
const OPENAI_EFFORTS = ["none", "minimal", "low", null];
const openaiEffort = new Map();

async function openaiComplete({ apiKey, model, system, prompt, signal, fetchImpl }) {
  const candidates = openaiEffort.has(model) ? [openaiEffort.get(model)] : OPENAI_EFFORTS;
  let lastError;
  for (const effort of candidates) {
    const body = {
      model,
      messages: [
        { role: "system", content: system },
        { role: "user", content: prompt },
      ],
    };
    if (effort) body.reasoning_effort = effort;
    let json;
    try {
      json = await request("openai", "/chat/completions", { apiKey, body, signal, fetchImpl });
    } catch (err) {
      if (effort && err.code === "bad_request" && /reasoning/i.test(err.message)) {
        lastError = err;
        continue;
      }
      throw err;
    }
    openaiEffort.set(model, effort);
    const choice = json.choices?.[0];
    if (choice?.finish_reason === "length") {
      throw new ProviderError("failed", "The response was cut off. Try a shorter passage.");
    }
    const content = choice?.message?.content;
    if (typeof content !== "string" || !content.trim()) {
      throw new ProviderError("failed", "OpenAI returned an empty response.");
    }
    return content;
  }
  throw lastError;
}

async function anthropicComplete({ apiKey, model, system, prompt, signal, fetchImpl }) {
  const json = await request("anthropic", "/messages", {
    apiKey,
    signal,
    fetchImpl,
    body: { model, max_tokens: ANTHROPIC_MAX_TOKENS, system, messages: [{ role: "user", content: prompt }] },
  });
  if (json.stop_reason === "max_tokens") {
    throw new ProviderError("failed", "The response was cut off. Try a shorter passage.");
  }
  const text = (json.content ?? [])
    .filter((block) => block?.type === "text")
    .map((block) => block.text)
    .join("");
  if (!text.trim()) throw new ProviderError("failed", "Anthropic returned an empty response.");
  return text;
}

/** Sends one proofreading request and returns the model's raw text. */
export function complete(provider, options) {
  if (provider === "openai") return openaiComplete(options);
  if (provider === "anthropic") return anthropicComplete(options);
  throw new ProviderError("failed", `Unknown provider: ${provider}`);
}

// Chat-capable OpenAI models only; skip audio/image/embedding models and dated snapshots.
const OPENAI_CHAT = /^(gpt-|chatgpt-|o\d)/i;
const OPENAI_EXCLUDE =
  /(audio|realtime|tts|transcribe|whisper|dall-e|image|embedding|moderation|search|computer-use|codex|instruct|-\d{4}-\d{2}-\d{2}$|-\d{4}$)/i;

export function pickOpenAIModels(data) {
  const models = (data ?? [])
    .filter((m) => typeof m?.id === "string" && OPENAI_CHAT.test(m.id) && !OPENAI_EXCLUDE.test(m.id))
    .sort((a, b) => (b.created ?? 0) - (a.created ?? 0))
    .slice(0, MAX_LISTED_MODELS)
    .map((m) => ({ id: m.id, name: m.id }));
  const preferred =
    models.find((m) => /luna/i.test(m.id)) ?? models.find((m) => /mini/i.test(m.id)) ?? models[0];
  return { models, defaultModel: preferred?.id ?? null };
}

export function pickAnthropicModels(data) {
  const models = (data ?? [])
    .filter((m) => typeof m?.id === "string")
    .sort((a, b) => Date.parse(b.created_at ?? 0) - Date.parse(a.created_at ?? 0))
    .slice(0, MAX_LISTED_MODELS)
    .map((m) => ({ id: m.id, name: m.display_name ?? m.id }));
  const preferred = models.find((m) => /haiku/i.test(m.id)) ?? models[0];
  return { models, defaultModel: preferred?.id ?? null };
}

/** Lists the models this key can use. Doubles as a key check: a bad key throws code "auth". */
export async function listModels(provider, { apiKey, signal, fetchImpl }) {
  if (provider === "openai") {
    const json = await request("openai", "/models", { apiKey, signal, fetchImpl });
    return pickOpenAIModels(json.data);
  }
  if (provider === "anthropic") {
    const json = await request("anthropic", "/models?limit=100", { apiKey, signal, fetchImpl });
    return pickAnthropicModels(json.data);
  }
  throw new ProviderError("failed", `Unknown provider: ${provider}`);
}
