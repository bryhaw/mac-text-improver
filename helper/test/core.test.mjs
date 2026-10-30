import assert from "node:assert/strict";
import { test } from "node:test";
import { buildPrompt, cleanOutput, isAuthError, MAX_CHARS, validateText } from "../proofread-core.mjs";

test("cleanOutput restores surrounding whitespace", () => {
  assert.equal(cleanOutput("  helo world\n", "hello world"), "  hello world\n");
  assert.equal(cleanOutput("hi", "\n\nHi.\n"), "Hi.");
});

test("cleanOutput strips echoed draft tags and code fences", () => {
  assert.equal(cleanOutput("teh cat", "<draft>\nThe cat\n</draft>"), "The cat");
  assert.equal(cleanOutput("teh cat", "```\nThe cat\n```"), "The cat");
  assert.equal(cleanOutput("run ```ls```", "Run ```ls```"), "Run ```ls```");
});

test("cleanOutput falls back to the original on empty output", () => {
  assert.equal(cleanOutput("keep me", "   "), "keep me");
  assert.equal(cleanOutput("keep me", undefined), "keep me");
});

test("cleanOutput preserves inner line breaks", () => {
  assert.equal(cleanOutput("hi\n\n- one\n- too", "Hi,\n\n- one\n- two"), "Hi,\n\n- one\n- two");
});

test("validateText rejects empty and oversized text", () => {
  assert.ok(validateText(""));
  assert.ok(validateText("   \n"));
  assert.ok(validateText("x".repeat(MAX_CHARS + 1)));
  assert.equal(validateText("fine"), null);
});

test("isAuthError recognizes auth failures only", () => {
  assert.ok(isAuthError("No GitHub OAuth token found"));
  assert.ok(isAuthError("Request failed: 401 Unauthorized"));
  assert.ok(!isAuthError("Request timed out"));
});

test("buildPrompt wraps the draft", () => {
  assert.equal(buildPrompt("hi"), "<draft>\nhi\n</draft>");
});
