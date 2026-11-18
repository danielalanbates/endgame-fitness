// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { onRequest, hash } from "../functions/api/endgame/[[path]].js";
import * as E from "../../Web/local-app/engine.mjs";
function db() {
  const raw = new DatabaseSync(":memory:");
  raw.exec(
    readFileSync(
      new URL("../migrations/0001_endgame.sql", import.meta.url),
      "utf8",
    ),
  );
  return {
    raw,
    prepare(sql) {
      return {
        bind(...args) {
          const statement = raw.prepare(sql);
          return {
            async first() {
              return statement.get(...args) || null;
            },
            async all() {
              return { results: statement.all(...args) };
            },
            async run() {
              const r = statement.run(...args);
              return { meta: { changes: Number(r.changes) } };
            },
          };
        },
      };
    },
    async batch(statements) {
      raw.exec("BEGIN");
      try {
        const out = [];
        for (const s of statements) out.push(await s.run());
        raw.exec("COMMIT");
        return out;
      } catch (e) {
        raw.exec("ROLLBACK");
        throw e;
      }
    },
  };
}
async function setup() {
  const DB = db(),
    id = crypto.randomUUID(),
    token = "test-session-token";
  DB.raw
    .prepare("INSERT INTO ef_accounts VALUES(?,?,?,?,?)")
    .run(id, "1000", "Test", "ABCDEF0123456789", 0);
  DB.raw
    .prepare("INSERT INTO ef_sessions VALUES(?,?,?)")
    .run(await hash(token), id, Math.floor(Date.now() / 1000) + 1000);
  return { DB, id, token };
}
async function request(env, path, method = "GET", body, extra = {}) {
  return onRequest({
    env,
    params: { path: path.split("?")[0].split("/") },
    request: new Request("https://batesai.org/api/endgame/" + path, {
      method,
      headers: {
        ...(body
          ? {
              "Content-Type": "application/json",
              Origin: "https://batesai.org",
            }
          : {}),
        ...extra,
      },
      body: body ? JSON.stringify(body) : undefined,
    }),
  });
}
const auth = (token) => ({ Authorization: "Bearer " + token });
test("missing Facebook configuration explicitly returns 503", async () => {
  const r = await request({}, "auth/start");
  assert.equal(r.status, 503);
  assert.equal((await r.json()).code, "FACEBOOK_NOT_CONFIGURED");
});
test("config never exposes secrets", async () => {
  const r = await request(
    { FACEBOOK_APP_ID: "123", FACEBOOK_APP_SECRET: "secret" },
    "config",
  );
  assert.deepEqual(await r.json(), { facebook: true, provider: "facebook" });
});
test("Facebook is the only login route", async () => {
  const r = await request(
    { FACEBOOK_APP_ID: "123", FACEBOOK_APP_SECRET: "secret" },
    "auth/apple",
  );
  assert.equal(r.status, 404);
});
test("callback rejects missing state before exchange", async () => {
  const r = await request(
    { FACEBOOK_APP_ID: "123", FACEBOOK_APP_SECRET: "secret" },
    "auth/callback",
  );
  assert.equal(r.status, 400);
});
test("login state is persisted and callback cookie protected", async () => {
  const DB = db(),
    env = { DB, FACEBOOK_APP_ID: "123", FACEBOOK_APP_SECRET: "secret" };
  const r = await request(env, "auth/start");
  assert.equal(r.status, 302);
  assert.match(
    r.headers.get("location"),
    /^https:\/\/www.facebook.com\/v27.0\/dialog\/oauth/,
  );
  assert.match(r.headers.get("set-cookie"), /HttpOnly; Secure; SameSite=Lax/);
  assert.equal(
    DB.raw.prepare("SELECT count(*) as n FROM ef_oauth_states").get().n,
    1,
  );
  const state = new URL(r.headers.get("location")).searchParams.get("state");
  const bad = await request(env, "auth/callback?state=" + state);
  assert.equal(bad.status, 400);
});
test("native start requires PKCE challenge", async () => {
  const r = await onRequest({
    env: { FACEBOOK_APP_ID: "123", FACEBOOK_APP_SECRET: "secret" },
    params: { path: ["auth", "start"] },
    request: new Request("https://batesai.org/api/endgame/auth/start?native=1"),
  });
  assert.equal(r.status, 400);
});
test("state and social reject anonymous users", async () => {
  const DB = db();
  for (const path of ["state", "social", "me"])
    assert.equal((await request({ DB }, path)).status, 401);
});
test("cookie auth requires same-origin JSON for mutations", async () => {
  const { DB, token } = await setup();
  const r = await request(
    { DB },
    "state",
    "PUT",
    { revision: 0, state: E.fresh() },
    { Origin: "https://evil.example", Cookie: "__Secure-ef_session=" + token },
  );
  assert.equal(r.status, 403);
});
test("session identity comes from hashed expiring token", async () => {
  const { DB, token, id } = await setup();
  assert.equal(
    (await (await request({ DB }, "me", "GET", null, auth(token))).json()).user
      .id,
    id,
  );
  DB.raw.prepare("UPDATE ef_sessions SET expires_at=0").run();
  assert.equal(
    (await request({ DB }, "me", "GET", null, auth(token))).status,
    401,
  );
});
test("cloud writes enforce ownership and optimistic concurrency", async () => {
  const { DB, token, id } = await setup(),
    p = E.newPlayer("A");
  p.id = id;
  const state = { version: 1, players: [p], selected: id, rivals: [] };
  let r = await request(
    { DB },
    "state",
    "PUT",
    { revision: 0, state },
    auth(token),
  );
  assert.equal(r.status, 200);
  assert.equal((await r.json()).revision, 1);
  r = await request(
    { DB },
    "state",
    "PUT",
    { revision: 0, state },
    auth(token),
  );
  assert.equal(r.status, 409);
  r = await request(
    { DB },
    "state",
    "PUT",
    { revision: 1, state },
    auth(token),
  );
  assert.equal((await r.json()).revision, 2);
  state.players[0].id = "someone-else";
  state.selected = "someone-else";
  assert.equal(
    (await request({ DB }, "state", "PUT", { revision: 2, state }, auth(token)))
      .status,
    400,
  );
});
test("invalid data never enters account storage", async () => {
  const { DB, token, id } = await setup();
  assert.equal(
    (
      await request(
        { DB },
        "state",
        "PUT",
        { revision: 0, state: { version: 999, players: [], rivals: [] } },
        auth(token),
      )
    ).status,
    400,
  );
  assert.equal(DB.raw.prepare("SELECT count(*) as n FROM ef_state").get().n, 0);
});
test("friends require mutual acceptance before stats visibility", async () => {
  const { DB, token, id } = await setup();
  DB.raw
    .prepare("INSERT INTO ef_accounts VALUES(?,?,?,?,?)")
    .run("friend", "2000", "Friend", "1111111111111111", 0);
  assert.equal(
    (
      await request(
        { DB },
        "friends",
        "POST",
        { code: "1111111111111111" },
        auth(token),
      )
    ).status,
    200,
  );
  let social = await (
    await request({ DB }, "social", "GET", null, auth(token))
  ).json();
  assert.equal(social.friends.length, 0);
  assert.equal(social.outgoing.length, 1);
  const ft = "friend-token";
  DB.raw
    .prepare("INSERT INTO ef_sessions VALUES(?,?,?)")
    .run(await hash(ft), "friend", Math.floor(Date.now() / 1000) + 1000);
  social = await (
    await request({ DB }, "social", "GET", null, auth(ft))
  ).json();
  assert.equal(social.incoming.length, 1);
  await request(
    { DB },
    "friends/respond",
    "POST",
    { id, accept: true },
    auth(ft),
  );
  social = await (
    await request({ DB }, "social", "GET", null, auth(token))
  ).json();
  assert.equal(social.friends[0].name, "Friend");
  assert.equal("data" in social.friends[0], false);
  assert.equal("facebook_id" in social.friends[0], false);
  await request(
    { DB },
    "friends/remove",
    "POST",
    { id: "friend" },
    auth(token),
  );
  assert.equal(
    (await (await request({ DB }, "social", "GET", null, auth(token))).json())
      .friends.length,
    0,
  );
});
test("logout revokes current session", async () => {
  const { DB, token } = await setup();
  assert.equal(
    (await request({ DB }, "logout", "POST", {}, auth(token))).status,
    200,
  );
  assert.equal(
    (await request({ DB }, "me", "GET", null, auth(token))).status,
    401,
  );
});
test("account deletion removes private state and sessions", async () => {
  const { DB, token } = await setup();
  assert.equal(
    (await request({ DB }, "account", "DELETE", { confirm: "NO" }, auth(token)))
      .status,
    400,
  );
  assert.equal(
    (
      await request(
        { DB },
        "account",
        "DELETE",
        { confirm: "DELETE" },
        auth(token),
      )
    ).status,
    200,
  );
  assert.equal(
    DB.raw.prepare("SELECT count(*) as n FROM ef_accounts").get().n,
    0,
  );
  assert.equal(
    DB.raw.prepare("SELECT count(*) as n FROM ef_sessions").get().n,
    0,
  );
});
test("native exchange rejects wrong verifier without consuming code", async () => {
  const { DB, id } = await setup(),
    code = "a".repeat(64),
    verifier = "b".repeat(64),
    bytes = new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)),
    ),
    challenge = Buffer.from(bytes).toString("base64url");
  DB.raw
    .prepare("INSERT INTO ef_native_codes VALUES(?,?,?,?)")
    .run(await hash(code), id, challenge, Math.floor(Date.now() / 1000) + 60);
  assert.equal(
    (
      await request({ DB }, "native/exchange", "POST", {
        code,
        verifier: "c".repeat(64),
      })
    ).status,
    401,
  );
  assert.equal(
    DB.raw.prepare("SELECT count(*) as n FROM ef_native_codes").get().n,
    1,
  );
  assert.equal(
    (await request({ DB }, "native/exchange", "POST", { code, verifier }))
      .status,
    200,
  );
  assert.equal(
    (await request({ DB }, "native/exchange", "POST", { code, verifier }))
      .status,
    401,
  );
});
test("OAuth callback exchanges once, binds Facebook ID, and never returns provider token", async () => {
  const DB = db(),
    env = { DB, FACEBOOK_APP_ID: "123", FACEBOOK_APP_SECRET: "secret" },
    start = await request(env, "auth/start");
  const state = new URL(start.headers.get("location")).searchParams.get(
    "state",
  );
  const headers = { Cookie: "__Secure-ef_oauth=" + state };
  const previous = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (url, options) => {
    calls++;
    if (String(url).includes("oauth/access_token")) {
      assert.equal(options.method, "POST");
      return Response.json({ access_token: "provider-secret-token" });
    }
    assert.match(String(url), /appsecret_proof=/);
    assert.equal(options.headers.Authorization, "Bearer provider-secret-token");
    return Response.json({ id: "99887766", name: "Facebook Athlete" });
  };
  try {
    const response = await request(
      env,
      "auth/callback?state=" + state + "&code=real-code",
      "GET",
      null,
      headers,
    );
    assert.equal(response.status, 302);
    assert.equal(
      response.headers.get("location"),
      "https://batesai.org/endgamefitness/",
    );
    assert.match(response.headers.get("set-cookie"), /__Secure-ef_session=/);
    assert.equal(
      response.headers.get("set-cookie").includes("provider-secret-token"),
      false,
    );
    assert.equal(
      DB.raw.prepare("SELECT facebook_id FROM ef_accounts").get().facebook_id,
      "99887766",
    );
    assert.equal(
      (
        await request(
          env,
          "auth/callback?state=" + state + "&code=real-code",
          "GET",
          null,
          headers,
        )
      ).status,
      400,
    );
    assert.equal(calls, 2);
  } finally {
    globalThis.fetch = previous;
  }
});
test("cancelled OAuth consumes state without creating an account", async () => {
  const DB = db(),
    env = { DB, FACEBOOK_APP_ID: "123", FACEBOOK_APP_SECRET: "secret" },
    start = await request(env, "auth/start"),
    state = new URL(start.headers.get("location")).searchParams.get("state");
  const r = await request(
    env,
    "auth/callback?state=" + state + "&error=access_denied",
    "GET",
    null,
    { Cookie: "__Secure-ef_oauth=" + state },
  );
  assert.equal(r.status, 302);
  assert.match(r.headers.get("location"), /auth=cancelled/);
  assert.equal(
    DB.raw.prepare("SELECT count(*) as n FROM ef_accounts").get().n,
    0,
  );
  assert.equal(
    DB.raw.prepare("SELECT count(*) as n FROM ef_oauth_states").get().n,
    0,
  );
});
test("opposite invitations cannot create duplicate friendship rows", async () => {
  const { DB, id } = await setup();
  DB.raw
    .prepare("INSERT INTO ef_accounts VALUES(?,?,?,?,?)")
    .run("friend", "2000", "Friend", "1111111111111111", 0);
  DB.raw
    .prepare("INSERT INTO ef_friendships VALUES(?,?,0,0)")
    .run(id, "friend");
  assert.throws(() =>
    DB.raw
      .prepare("INSERT INTO ef_friendships VALUES(?,?,0,0)")
      .run("friend", id),
  );
});
