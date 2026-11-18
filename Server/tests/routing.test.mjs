// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
import test from "node:test";
import assert from "node:assert/strict";
import worker from "../worker.mjs";
const ctx = { waitUntil() {} };
test("canonical route preserves invite query", async () => {
  const r = await worker.fetch(
    new Request("https://batesai.org/endgamefitness?invite=ABC"),
    {},
    ctx,
  );
  assert.equal(r.status, 308);
  assert.equal(
    r.headers.get("Location"),
    "https://batesai.org/endgamefitness/?invite=ABC",
  );
});
test("asset HTML canonical redirects remain within Endgame", async () => {
  const env = {
    ASSETS: {
      fetch: async (request) => {
        assert.equal(new URL(request.url).pathname, "/privacy.html");
        return new Response(null, {
          status: 307,
          headers: { Location: "/privacy" },
        });
      },
    },
  };
  const r = await worker.fetch(
    new Request("https://batesai.org/endgamefitness/privacy.html"),
    env,
    ctx,
  );
  assert.equal(r.headers.get("Location"), "/endgamefitness/privacy");
  assert.match(
    r.headers.get("Content-Security-Policy"),
    /frame-ancestors 'none'/,
  );
});
test("root asset response is served with security headers", async () => {
  const r = await worker.fetch(
    new Request("https://batesai.org/endgamefitness/"),
    {
      ASSETS: {
        fetch: async (request) => {
          assert.equal(new URL(request.url).pathname, "/");
          return new Response("Endgame");
        },
      },
    },
    ctx,
  );
  assert.equal(await r.text(), "Endgame");
  assert.equal(r.headers.get("Cache-Control"), "no-cache");
});
test("API config stays separate from asset path rewriting", async () => {
  const r = await worker.fetch(
    new Request("https://batesai.org/api/endgame/config"),
    {},
    ctx,
  );
  assert.equal((await r.json()).facebook, false);
});
test("similar unrelated routes are not served as the app", async () => {
  const r = await worker.fetch(
    new Request("https://batesai.org/endgamefitness-other"),
    {},
    ctx,
  );
  assert.equal(r.status, 404);
});
