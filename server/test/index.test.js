import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { handle, sign, checkSession, FEEDBACK_DAILY, REFRESH_DAILY } from "../src/index.js";

/** In-memory stand-in for a KV namespace. */
function kv(entries = {}) {
  const map = new Map(Object.entries(entries));
  return {
    map,
    async get(key, type) {
      const value = map.get(key);
      if (value === undefined) return null;
      return type === "json" ? JSON.parse(value) : value;
    },
    async put(key, value) {
      map.set(key, value);
    },
  };
}

const KEYS = JSON.stringify({ 1: "test-secret-one", 2: "test-secret-two" });

async function codeFor(name, keyId = "2", secret = "test-secret-two") {
  return `${name}-${keyId}-${await sign(secret, keyId, name)}`;
}

async function setup({ calls = 0, all = 0, env = {} } = {}) {
  const code = await codeFor("alex");
  const day = new Date().toISOString().slice(0, 10);
  const usage = kv();
  if (calls) usage.map.set(`count:${day}:alex`, String(calls));
  if (all) usage.map.set(`count:${day}:all`, String(all));
  const sent = [];
  const upstream = async (url, init) => {
    sent.push({ url, init });
    return new Response(JSON.stringify({ session: { id: "s1" }, transport: { sdp: "answer" } }), {
      status: 201,
      headers: { "Content-Type": "application/json", "x-request-id": "req_1" },
    });
  };
  return { env: { OPENAI_API_KEY: "sk-real", INVITE_KEYS: KEYS, USAGE: usage, ...env }, usage, sent, upstream, code, day };
}

function call(body, code) {
  return new Request("https://worker.example/v1/live/sessions", {
    method: "POST",
    headers: code ? { Authorization: `Bearer ${code}` } : {},
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

const goodBody = () => ({
  session: {
    model: "gpt-live-1.1",
    instructions: "You are Pixie.",
    audio: { output: { voice: "marin" } },
    delegation: { type: "responses", responses: { model: "gpt-6.1-terra", tools: [{ type: "web_search" }] } },
  },
  transport: { type: "webrtc", sdp: "v=0" },
});

test("forwards a valid call with the real key and counts it", async () => {
  const t = await setup();
  const pending = [];
  const response = await handle(call(goodBody(), t.code), t.env, t.upstream, { waitUntil: (p) => pending.push(p) });
  await Promise.all(pending);
  assert.equal(response.status, 201);
  assert.equal(response.headers.get("x-request-id"), "req_1");
  assert.equal((await response.json()).transport.sdp, "answer");
  assert.equal(t.sent.length, 1);
  assert.equal(t.sent[0].url, "https://api.openai.com/v1/live/sessions");
  assert.equal(t.sent[0].init.headers.Authorization, "Bearer sk-real");
  const forwarded = JSON.parse(t.sent[0].init.body);
  assert.equal(forwarded.session.store, false);
  assert.equal(forwarded.transport.sdp, "v=0");
  assert.equal(t.usage.map.get(`count:${t.day}:alex`), "1");
  assert.equal(t.usage.map.get(`count:${t.day}:all`), "1");
  assert.deepEqual(JSON.parse(t.usage.map.get(`stats:${t.day}:alex`)), { calls: 1 });
});

test("the invite code itself is never sent to OpenAI or stored", async () => {
  const t = await setup();
  await handle(call(goodBody(), t.code), t.env, t.upstream);
  const sent = JSON.stringify(t.sent[0].init);
  assert.ok(!sent.includes(t.code));
  assert.ok(![...t.usage.map.keys()].some((key) => key.includes(t.code)));
});

test("wrong, expired and revoked codes are told apart, without calling OpenAI", async () => {
  const t = await setup({ env: { REVOKED: "sam, jo" } });
  const problem = async (code) => {
    const response = await handle(call(goodBody(), code), t.env, t.upstream);
    assert.equal(response.status, 401);
    return (await response.json()).error.code;
  };
  assert.equal((await handle(call(goodBody(), null), t.env, t.upstream)).status, 401);
  assert.equal(await problem("guess"), "invalid_code");
  assert.equal(await problem(t.code.slice(0, -1) + "0"), "invalid_code");
  assert.equal(await problem(await codeFor("bob", "2", "another-secret")), "invalid_code");
  assert.equal(await problem(await codeFor("alex", "7", "retired")), "expired_code");
  assert.equal(await problem(await codeFor("jo")), "revoked_code");
  assert.equal(t.sent.length, 0);
});

test("codes from an older key still work while that key is listed, and ignore case", async () => {
  const t = await setup();
  const old = await codeFor("alex", "1", "test-secret-one");
  assert.equal((await handle(call(goodBody(), old), t.env, t.upstream)).status, 201);
  assert.equal((await handle(call(goodBody(), ` ${t.code.toUpperCase()} `), t.env, t.upstream)).status, 201);
});

test("only Wake On's models and WebRTC calls are allowed", async () => {
  const t = await setup();
  const otherModel = goodBody();
  otherModel.session.model = "gpt-6";
  assert.equal((await handle(call(otherModel, t.code), t.env, t.upstream)).status, 400);
  const otherBackend = goodBody();
  otherBackend.session.delegation.responses.model = "o9-pro";
  assert.equal((await handle(call(otherBackend, t.code), t.env, t.upstream)).status, 400);
  const websocket = goodBody();
  websocket.transport = { type: "websocket" };
  assert.equal((await handle(call(websocket, t.code), t.env, t.upstream)).status, 400);
  assert.equal((await handle(call("not json", t.code), t.env, t.upstream)).status, 400);
  assert.equal(t.sent.length, 0);
});

test("daily limits per code and overall", async () => {
  const perCode = await setup({ calls: 40 });
  const limited = await handle(call(goodBody(), perCode.code), perCode.env, perCode.upstream);
  assert.equal(limited.status, 429);
  const limitedText = await limited.text();
  assert.equal(JSON.parse(limitedText).error.code, "daily_limit");
  const overall = await setup({ all: 5, env: { GLOBAL_DAILY_CALLS: "5" } });
  assert.equal((await handle(call(goodBody(), overall.code), overall.env, overall.upstream)).status, 429);
  // OpenAI was asked in parallel, but its answer never reaches the phone.
  assert.ok(!limitedText.includes("answer"));
});

test("a call OpenAI refuses isn't counted", async () => {
  const t = await setup();
  const refuse = async () => new Response('{"error":{"message":"bad voice"}}', { status: 400 });
  const response = await handle(call(goodBody(), t.code), t.env, refuse);
  assert.equal(response.status, 400);
  assert.equal(t.usage.map.get(`count:${t.day}:alex`), undefined);
});

test("prewarm HEAD and health need no code", async () => {
  const t = await setup();
  const head = await handle(new Request("https://worker.example/v1/live/sessions", { method: "HEAD" }), t.env, t.upstream);
  assert.equal(head.status, 204);
  const health = await handle(new Request("https://worker.example/health"), t.env, t.upstream);
  assert.equal(health.status, 200);
  assert.equal(t.sent.length, 0);
});

test("reports each step's time in Server-Timing", async () => {
  const t = await setup();
  const response = await handle(call(goodBody(), t.code), t.env, t.upstream);
  const timing = response.headers.get("Server-Timing");
  for (const step of ["code", "limits", "openai", "total"]) {
    assert.match(timing, new RegExp(`${step};dur=\\d+`));
  }
  assert.ok(!timing.includes("friend-code"));
});

test("the reply doesn't wait for the counter writes", async () => {
  const t = await setup();
  let release;
  t.usage.put = () => new Promise((resolve) => (release = resolve));
  const pending = [];
  const response = await handle(call(goodBody(), t.code), t.env, t.upstream, { waitUntil: (p) => pending.push(p) });
  assert.equal(response.status, 201);
  assert.equal(pending.length, 1);
  release();
});

test("the count is read while OpenAI sets up the call", async () => {
  const t = await setup();
  const order = [];
  t.usage.get = async () => {
    order.push("count read");
    await new Promise((resolve) => setTimeout(resolve, 20));
    return null;
  };
  const upstream = async (url, init) => {
    order.push("openai asked");
    return t.upstream(url, init);
  };
  await handle(call(goodBody(), t.code), t.env, upstream);
  assert.deepEqual(order.slice(0, 3).sort(), ["count read", "count read", "openai asked"]);
});

test("checking a code answers like a call would, without OpenAI or counting", async () => {
  const t = await setup({ env: { REVOKED: "jo" } });
  const check = (code) => handle(new Request("https://worker.example/v1/check", {
    method: "POST", headers: code ? { Authorization: `Bearer ${code}` } : {},
  }), t.env, t.upstream);
  const good = await check(t.code);
  assert.equal(good.status, 200);
  assert.deepEqual(await good.json(), { ok: true, name: "alex" });
  assert.equal((await (await check(await codeFor("jo"))).json()).error.code, "revoked_code");
  assert.equal((await (await check(await codeFor("alex", "7", "retired"))).json()).error.code, "expired_code");
  assert.equal((await check("nope")).status, 401);
  assert.equal((await check(null)).status, 401);
  assert.equal(t.sent.length, 0);
  assert.equal(t.usage.map.size, 0);
});

function summaryRequest(lines, code) {
  return new Request("https://worker.example/v1/memory/summarize", {
    method: "POST",
    headers: code ? { Authorization: `Bearer ${code}` } : {},
    body: JSON.stringify({ lines }),
  });
}

const summaryUpstream = (sent, replies = [" One line. "]) => async (url, init) => {
  sent.push({ url, init });
  const text = replies[Math.min(sent.length - 1, replies.length - 1)];
  return new Response(JSON.stringify({ output: [{ content: [{ type: "output_text", text }] }],
    usage: { input_tokens: 300, output_tokens: 40 } }),
    { status: 200, headers: { "Content-Type": "application/json" } });
};

test("summarizes memory lines with the fixed prompt and model, and counts it", async () => {
  const t = await setup();
  const sent = [];
  const pending = [];
  const response = await handle(summaryRequest(["[Nov 1, 2026] a", "[Nov 2, 2026] b"], t.code), t.env,
    summaryUpstream(sent), { waitUntil: (p) => pending.push(p) });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { text: "One line." });
  assert.equal(sent[0].url, "https://api.openai.com/v1/responses");
  const body = JSON.parse(sent[0].init.body);
  assert.equal(body.model, "gpt-6.2-sol");
  assert.deepEqual(body.reasoning, { effort: "medium" });
  assert.equal(body.store, false);
  assert.match(body.instructions, /compress a voice assistant's memory/);
  assert.deepEqual(body.input, [{ role: "user", content: "[Nov 1, 2026] a\n[Nov 2, 2026] b" }]);
  assert.equal(body.max_output_tokens, 2000);
  assert.equal(sent[0].init.headers.Authorization, "Bearer sk-real");
  await Promise.all(pending);
  assert.equal(t.usage.map.get(`summaries:${t.day}:alex`), "1");
  assert.deepEqual(JSON.parse(t.usage.map.get(`stats:${t.day}:alex`)),
    { summaries: 1, summary_input_tokens: 300, summary_output_tokens: 40 });
});

test("summaries need a valid code, a few short lines, and stay under the daily limit", async () => {
  const t = await setup();
  const sent = [];
  assert.equal((await handle(summaryRequest(["a"], null), t.env, summaryUpstream(sent))).status, 401);
  assert.equal((await handle(summaryRequest(["a"], "alex-2-wrong"), t.env, summaryUpstream(sent))).status, 401);
  assert.equal((await handle(summaryRequest([], t.code), t.env, summaryUpstream(sent))).status, 400);
  assert.equal((await handle(summaryRequest(Array(17).fill("a"), t.code), t.env, summaryUpstream(sent))).status, 400);
  assert.equal((await handle(summaryRequest(["x".repeat(401)], t.code), t.env, summaryUpstream(sent))).status, 400);
  assert.equal((await handle(summaryRequest([{ role: "system" }], t.code), t.env, summaryUpstream(sent))).status, 400);
  t.usage.map.set(`summaries:${t.day}:alex`, "200");
  assert.equal((await handle(summaryRequest(["a"], t.code), t.env, summaryUpstream(sent))).status, 429);
  assert.equal(sent.length, 0);
});

test("a summary over 280 bytes is sent back as too long and written again, never cut", async () => {
  const t = await setup();
  const sent = [];
  const long = "x".repeat(300);
  const response = await handle(summaryRequest(["a", "b"], t.code), t.env,
    summaryUpstream(sent, [long, "Short."]), { waitUntil: () => {} });
  assert.deepEqual(await response.json(), { text: "Short." });
  const retry = JSON.parse(sent[1].init.body).input;
  assert.deepEqual(retry[1], { role: "assistant", content: long });
  assert.match(retry[2].content, /^Too long: 300 bytes, limit 280/);
  const stuck = [];
  const failed = await handle(summaryRequest(["a", "b"], t.code), t.env, summaryUpstream(stuck, [long]), { waitUntil: () => {} });
  assert.equal(failed.status, 502);
  assert.equal(stuck.length, 3);
});

const usageRequest = (body, code) => new Request("https://worker.example/v1/usage", {
  method: "POST",
  headers: code ? { Authorization: `Bearer ${code}` } : {},
  body: JSON.stringify(body),
});

test("a call's reported seconds and tokens add up per person per day, kept 90 days", async () => {
  const t = await setup();
  const ttls = [];
  const put = t.usage.put;
  t.usage.put = (key, value, options) => { ttls.push(options && options.expirationTtl); return put(key, value); };
  const report = { seconds: 63.3, input_tokens: 2400, cached_tokens: 2000, output_tokens: 160 };
  for (let i = 0; i < 2; i++) {
    const pending = [];
    const response = await handle(usageRequest(report, t.code), t.env, t.upstream, { waitUntil: (p) => pending.push(p) });
    assert.equal(response.status, 200);
    await Promise.all(pending);
  }
  assert.deepEqual(JSON.parse(t.usage.map.get(`stats:${t.day}:alex`)),
    { reports: 2, seconds: 126.6, input_tokens: 4800, cached_tokens: 4000, output_tokens: 320 });
  assert.deepEqual(ttls, [90 * 24 * 3600, 90 * 24 * 3600]);
  assert.equal(t.sent.length, 0);
});

test("usage reports need a valid code and numbers, and are capped", async () => {
  const t = await setup();
  assert.equal((await handle(usageRequest({ seconds: 1 }), t.env, t.upstream)).status, 401);
  assert.equal((await handle(usageRequest({ seconds: 1 }, "alex-2-wrongwrongwr"), t.env, t.upstream)).status, 401);
  const bad = { seconds: -1, input_tokens: 0, cached_tokens: 0, output_tokens: 0 };
  assert.equal((await handle(usageRequest(bad, t.code), t.env, t.upstream)).status, 400);
  assert.equal((await handle(usageRequest({ seconds: "x" }, t.code), t.env, t.upstream)).status, 400);
  const pending = [];
  const huge = { seconds: 1e9, input_tokens: 1e12, cached_tokens: 0, output_tokens: 0 };
  assert.equal((await handle(usageRequest(huge, t.code), t.env, t.upstream, { waitUntil: (p) => pending.push(p) })).status, 200);
  await Promise.all(pending);
  const stats = JSON.parse(t.usage.map.get(`stats:${t.day}:alex`));
  assert.equal(stats.seconds, 4 * 3600);
  assert.equal(stats.input_tokens, 5_000_000);
});

test("each person's stats keep the app build they last used, from calls and usage reports", async () => {
  const t = await setup();
  const pending = [];
  const ctx = { waitUntil: (p) => pending.push(p) };
  const withBuild = (request, build) => { request.headers.set("X-Pixie-Build", build); return request; };
  await handle(withBuild(call(goodBody(), t.code), "0.1.0 (202611271412) 9ae86fe"), t.env, t.upstream, ctx);
  await Promise.all(pending);
  assert.equal(JSON.parse(t.usage.map.get(`stats:${t.day}:alex`)).build, "0.1.0 (202611271412) 9ae86fe");
  const report = { seconds: 60, input_tokens: 0, cached_tokens: 0, output_tokens: 0 };
  await handle(withBuild(usageRequest(report, t.code), "0.1.0 (202611271426) fae64eb\u0007"), t.env, t.upstream, ctx);
  await Promise.all(pending);
  const stats = JSON.parse(t.usage.map.get(`stats:${t.day}:alex`));
  assert.equal(stats.build, "0.1.0 (202611271426) fae64eb");
  assert.equal(stats.calls, 1);
  // Builds from before the header keep the last known build instead of wiping it.
  await handle(usageRequest(report, t.code), t.env, t.upstream, ctx);
  await Promise.all(pending);
  assert.equal(JSON.parse(t.usage.map.get(`stats:${t.day}:alex`)).build, "0.1.0 (202611271426) fae64eb");
});

test("the app's delegation model is allowed, and builds still on the older model keep working", () => {
  const swift = readFileSync(new URL("../../native/ios/WakeOn/OpenAILiveVoiceProvider.swift", import.meta.url), "utf8");
  const appModel = swift.match(/var delegationModel = "([^"]+)"/)[1];
  const toml = readFileSync(new URL("../wrangler.toml", import.meta.url), "utf8");
  const deployed = { ALLOWED_BACKEND_MODELS: toml.match(/^ALLOWED_BACKEND_MODELS = "([^"]+)"/m)[1] };
  for (const model of [appModel, "gpt-5.6-terra"]) {
    const body = goodBody();
    body.session.delegation.responses.model = model;
    assert.equal(checkSession(body, {}), null, `${model} with the default list`);
    assert.equal(checkSession(body, deployed), null, `${model} with wrangler.toml`);
  }
});

const feedbackRequest = (body, code) => new Request("https://worker.example/v1/feedback", {
  method: "POST",
  headers: code ? { Authorization: `Bearer ${code}` } : {},
  body: typeof body === "string" ? body : JSON.stringify(body),
});

test("feedback is kept a year with the person's name, Pixie's note and the build", async () => {
  const t = await setup();
  const ttls = {};
  const put = t.usage.put;
  t.usage.put = (key, value, options) => { ttls[key] = options && options.expirationTtl; return put(key, value); };
  const response = await handle(feedbackRequest({ feedback: "The map opened the wrong place", context: "Asked for Xiang Zi HotPot; map opened Markham", app: "202611260320", warnings: ["Weak connection", "", 7] }, t.code), t.env, t.upstream);
  assert.equal(response.status, 200);
  const key = [...t.usage.map.keys()].find((k) => k.startsWith("feedback:"));
  assert.match(key, /^feedback:\d{4}-\d\d-\d\dT[^:]+:\d\d:[\d.]+Z:alex:[0-9a-f]{8}$/);
  const entry = JSON.parse(t.usage.map.get(key));
  assert.equal(entry.name, "alex");
  assert.equal(entry.feedback, "The map opened the wrong place");
  assert.equal(entry.context, "Asked for Xiang Zi HotPot; map opened Markham");
  assert.equal(entry.app, "202611260320");
  assert.deepEqual(entry.warnings, ["Weak connection", "7"]);
  assert.equal(ttls[key], 365 * 24 * 3600);
  assert.ok(!t.usage.map.get(key).includes(t.code), "the invite code itself isn't stored");
});

test("feedback needs a valid code and some words, is cut to 2000 characters, and is limited per day", async () => {
  const t = await setup();
  assert.equal((await handle(feedbackRequest({ feedback: "hi" }), t.env, t.upstream)).status, 401);
  assert.equal((await handle(feedbackRequest({ feedback: "hi" }, "alex-2-bad"), t.env, t.upstream)).status, 401);
  assert.equal((await handle(feedbackRequest({ feedback: "  " }, t.code), t.env, t.upstream)).status, 400);
  assert.equal((await handle(feedbackRequest("nope", t.code), t.env, t.upstream)).status, 400);
  await handle(feedbackRequest({ feedback: "x".repeat(5000) }, t.code), t.env, t.upstream);
  const entry = JSON.parse([...t.usage.map].find(([k]) => k.startsWith("feedback:"))[1]);
  assert.equal(entry.feedback.length, 2000);
  t.usage.map.set(`feedbackcount:${t.day}:alex`, String(FEEDBACK_DAILY));
  const limited = await handle(feedbackRequest({ feedback: "one more" }, t.code), t.env, t.upstream);
  assert.equal(limited.status, 429);
});

function refreshRequest(body, code) {
  return new Request("https://worker.example/v1/apps/refresh", {
    method: "POST",
    headers: code ? { Authorization: `Bearer ${code}` } : {},
    body: JSON.stringify(body),
  });
}

const page = "<!doctype html><html><body>Old weather</body></html>";
const refreshBody = { request: "This week's weather in Toronto", html: page, now: "Now: Thursday (America/Toronto)." };

test("a saved app is refreshed with the fixed prompt, web search and model, and counted", async () => {
  const t = await setup();
  const sent = [];
  const pending = [];
  const response = await handle(refreshRequest(refreshBody, t.code), t.env,
    summaryUpstream(sent, ["<html>New weather</html>"]), { waitUntil: (p) => pending.push(p) });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { text: "<html>New weather</html>" });
  const body = JSON.parse(sent[0].init.body);
  assert.equal(body.model, "gpt-6.1-terra");
  assert.equal(body.store, false);
  assert.deepEqual(body.tools, [{ type: "web_search" }]);
  assert.match(body.instructions, /update a small app saved on the user's phone/);
  assert.equal(body.input, `Now: Thursday (America/Toronto).\nRequest: This week's weather in Toronto\n\nCurrent page:\n${page}`);
  assert.ok(!sent[0].init.body.includes(t.code), "the invite code isn't sent to OpenAI");
  await Promise.all(pending);
  const day = new Date().toISOString().slice(0, 10);
  assert.equal(t.usage.map.get(`refreshes:${day}:alex`), "1");
});

test("refreshes need a valid code, a short request and a page, and stay under the daily limit", async () => {
  const t = await setup();
  const sent = [];
  const send = (body, code = t.code) => handle(refreshRequest(body, code), t.env, summaryUpstream(sent, ["<html></html>"]));
  assert.equal((await send(refreshBody, null)).status, 401);
  assert.equal((await send({ ...refreshBody, request: "" })).status, 400);
  assert.equal((await send({ ...refreshBody, request: "x".repeat(301) })).status, 400);
  assert.equal((await send({ ...refreshBody, html: "no page" })).status, 400);
  assert.equal((await send({ ...refreshBody, html: "<" + "x".repeat(30000) })).status, 400);
  assert.equal(sent.length, 0);
  const day = new Date().toISOString().slice(0, 10);
  t.usage.map.set(`refreshes:${day}:alex`, String(REFRESH_DAILY));
  assert.equal((await send(refreshBody)).status, 429);
  assert.equal(sent.length, 0);
});
