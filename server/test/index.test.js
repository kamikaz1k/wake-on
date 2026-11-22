import { test } from "node:test";
import assert from "node:assert/strict";
import { handle, sign } from "../src/index.js";

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
    instructions: "You are Lobby.",
    audio: { output: { voice: "marin" } },
    delegation: { type: "responses", responses: { model: "gpt-5.6-terra", tools: [{ type: "web_search" }] } },
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

const summaryUpstream = (sent) => async (url, init) => {
  sent.push({ url, init });
  return new Response(JSON.stringify({ output: [{ content: [{ type: "output_text", text: " One line. " }] }] }),
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
  assert.equal(body.model, "gpt-5.4-mini");
  assert.equal(body.store, false);
  assert.match(body.instructions, /compress a voice assistant's memory/);
  assert.equal(body.input, "[Nov 1, 2026] a\n[Nov 2, 2026] b");
  assert.equal(sent[0].init.headers.Authorization, "Bearer sk-real");
  await Promise.all(pending);
  assert.equal(t.usage.map.get(`summaries:${t.day}:alex`), "1");
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
  t.usage.map.set(`summaries:${t.day}:alex`, "60");
  assert.equal((await handle(summaryRequest(["a"], t.code), t.env, summaryUpstream(sent))).status, 429);
  assert.equal(sent.length, 0);
});
