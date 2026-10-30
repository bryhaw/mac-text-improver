import assert from "node:assert/strict";
import { test } from "node:test";
import { complete, listModels, pickAnthropicModels, pickOpenAIModels, redact } from "../providers.mjs";

// Obviously fake key, assembled at runtime so secret scanners don't flag the test file.
const FAKE_KEY = ["sk", "test", "0123456789abcdefghijklmnop"].join("-");

function mockFetch(handler) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ url, init, body });
    const { status = 200, json } = handler({ url, init, body, call: calls.length });
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(json) };
  };
  return { fetchImpl, calls };
}

const request = { apiKey: FAKE_KEY, system: "SYSTEM", prompt: "<draft>\nhi\n</draft>" };

test("OpenAI: sends system + draft with bearer auth and returns the reply", async () => {
  const { fetchImpl, calls } = mockFetch(() => ({ json: { choices: [{ message: { content: "Hi." }, finish_reason: "stop" }] } }));
  const out = await complete("openai", { ...request, model: "model-a", fetchImpl });
  assert.equal(out, "Hi.");
  assert.equal(calls[0].url, "https://api.openai.com/v1/chat/completions");
  assert.equal(calls[0].init.headers.authorization, `Bearer ${FAKE_KEY}`);
  assert.deepEqual(calls[0].body.messages, [
    { role: "system", content: "SYSTEM" },
    { role: "user", content: request.prompt },
  ]);
  assert.equal(calls[0].body.reasoning_effort, "none");
});

test("OpenAI: falls back when a model rejects reasoning_effort, then remembers", async () => {
  const { fetchImpl, calls } = mockFetch(({ body }) =>
    body.reasoning_effort
      ? { status: 400, json: { error: { message: "Unrecognized request argument supplied: reasoning_effort" } } }
      : { json: { choices: [{ message: { content: "Ok." } }] } },
  );
  assert.equal(await complete("openai", { ...request, model: "model-b", fetchImpl }), "Ok.");
  assert.deepEqual(calls.map((c) => c.body.reasoning_effort), ["none", "minimal", "low", undefined]);
  await complete("openai", { ...request, model: "model-b", fetchImpl });
  assert.equal(calls.length, 5);
  assert.equal(calls[4].body.reasoning_effort, undefined);
});

test("Anthropic: sends x-api-key, version, system, and joins text blocks", async () => {
  const { fetchImpl, calls } = mockFetch(() => ({
    json: { content: [{ type: "text", text: "Hel" }, { type: "text", text: "lo." }], stop_reason: "end_turn" },
  }));
  assert.equal(await complete("anthropic", { ...request, model: "claude-x", fetchImpl }), "Hello.");
  assert.equal(calls[0].url, "https://api.anthropic.com/v1/messages");
  assert.equal(calls[0].init.headers["x-api-key"], FAKE_KEY);
  assert.equal(calls[0].init.headers["anthropic-version"], "2023-06-01");
  assert.equal(calls[0].body.system, "SYSTEM");
  assert.ok(calls[0].body.max_tokens > 0);
});

test("401 maps to an auth error and never echoes the key", async () => {
  const { fetchImpl } = mockFetch(() => ({ status: 401, json: { error: { message: `Incorrect API key provided: ${FAKE_KEY}` } } }));
  await assert.rejects(complete("anthropic", { ...request, model: "m", fetchImpl }), (err) => {
    assert.equal(err.code, "auth");
    assert.ok(!err.message.includes(FAKE_KEY));
    return true;
  });
});

test("truncated responses are reported, not pasted", async () => {
  const { fetchImpl } = mockFetch(() => ({ json: { content: [{ type: "text", text: "partial" }], stop_reason: "max_tokens" } }));
  await assert.rejects(complete("anthropic", { ...request, model: "m", fetchImpl }), /cut off/);
});

test("redact hides explicit keys and key-shaped strings", () => {
  assert.equal(redact(`key ${FAKE_KEY} end`, FAKE_KEY), "key [redacted] end");
  assert.ok(!redact(`token ${FAKE_KEY}`).includes("0123456789abcdef"));
  assert.equal(redact("nothing secret"), "nothing secret");
});

test("pickOpenAIModels keeps chat models, newest first, preferring a small default", () => {
  const { models, defaultModel } = pickOpenAIModels([
    { id: "text-embedding-3-large", created: 9 },
    { id: "gpt-x-mini", created: 5 },
    { id: "gpt-x", created: 6 },
    { id: "gpt-x-2025-01-01", created: 7 },
    { id: "gpt-x-realtime", created: 8 },
    { id: "whisper-1", created: 10 },
  ]);
  assert.deepEqual(models.map((m) => m.id), ["gpt-x", "gpt-x-mini"]);
  assert.equal(defaultModel, "gpt-x-mini");
});

test("pickAnthropicModels sorts newest first and prefers Haiku", () => {
  const { models, defaultModel } = pickAnthropicModels([
    { id: "claude-old-haiku", display_name: "Old Haiku", created_at: "2024-01-01T00:00:00Z" },
    { id: "claude-new-sonnet", display_name: "New Sonnet", created_at: "2026-01-01T00:00:00Z" },
    { id: "claude-new-haiku", display_name: "New Haiku", created_at: "2025-06-01T00:00:00Z" },
  ]);
  assert.deepEqual(models.map((m) => m.name), ["New Sonnet", "New Haiku", "Old Haiku"]);
  assert.equal(defaultModel, "claude-new-haiku");
});

test("listModels hits the provider's models endpoint", async () => {
  const { fetchImpl, calls } = mockFetch(() => ({ json: { data: [{ id: "claude-a", created_at: "2026-01-01T00:00:00Z" }] } }));
  const result = await listModels("anthropic", { apiKey: FAKE_KEY, fetchImpl });
  assert.equal(calls[0].url, "https://api.anthropic.com/v1/models?limit=100");
  assert.equal(result.defaultModel, "claude-a");
});
