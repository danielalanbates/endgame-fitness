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
  raw.exec(readFileSync(new URL("../migrations/0002_batesai_membership.sql", import.meta.url), "utf8"));
  raw.exec(`CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT NOT NULL, name TEXT);
    CREATE TABLE sessions (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, token_hash TEXT NOT NULL, expires_at INTEGER NOT NULL);`);
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
    membershipUserId = crypto.randomUUID(),
    token = "test-session-token";
  DB.raw.prepare("INSERT INTO users VALUES(?,?,?)").run(membershipUserId, "test@example.com", "Test Member");
  DB.raw.prepare("INSERT INTO ef_accounts VALUES(?,?,?,?,?)")
    .run(id, `batesai:${membershipUserId}`, "Test Member", "ABCDEF0123456789", 0);
  DB.raw.prepare("INSERT INTO ef_membership_links VALUES(?,?)").run(membershipUserId, id);
  DB.raw.prepare("INSERT INTO sessions VALUES(?,?,?,?)")
    .run(crypto.randomUUID(), membershipUserId, await hash(token), Math.floor(Date.now() / 1000) + 1000);
  return { DB, id, membershipUserId, token };
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
test("config selects the shared BatesAI Google and Apple sign-in", async () => {
  const r = await request({}, "config");
  assert.deepEqual(await r.json(), { providers: ["google", "apple"], provider: "batesai-membership" });
});
test("Endgame does not expose or start a separate Facebook login", async () => {
  const r = await request({ DB: db() }, "auth/start");
  assert.equal(r.status, 404);
});
test("shared membership session provisions one stable Endgame profile", async () => {
  const DB = db(), membershipUserId = "new-membership-user", token = "new-shared-session";
  DB.raw.prepare("INSERT INTO users VALUES(?,?,?)").run(membershipUserId, "new@example.com", "New Member");
  DB.raw.prepare("INSERT INTO sessions VALUES(?,?,?,?)")
    .run(crypto.randomUUID(), membershipUserId, await hash(token), Math.floor(Date.now() / 1000) + 1000);
  const first = await (await request({ DB }, "me", "GET", null, auth(token))).json();
  const second = await (await request({ DB }, "me", "GET", null, auth(token))).json();
  assert.equal(first.user.id, second.user.id);
  assert.equal(first.user.display_name, "New Member");
  assert.equal(DB.raw.prepare("SELECT count(*) AS n FROM ef_accounts").get().n, 1);
  assert.equal(DB.raw.prepare("SELECT facebook_id FROM ef_accounts").get().facebook_id, `batesai:${membershipUserId}`);
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
    { Origin: "https://evil.example", Cookie: "batesai_session=" + token },
  );
  assert.equal(r.status, 403);
});
test("website BatesAI session cookie authenticates Endgame on the same host", async () => {
  const { DB, token, id } = await setup();
  const response = await request(
    { DB },
    "me",
    "GET",
    null,
    { Cookie: "batesai_session=" + token },
  );
  assert.equal(response.status, 200);
  assert.equal((await response.json()).user.id, id);
});
test("session identity comes from hashed expiring token", async () => {
  const { DB, token, id } = await setup();
  assert.equal(
    (await (await request({ DB }, "me", "GET", null, auth(token))).json()).user
      .id,
    id,
  );
  DB.raw.prepare("UPDATE sessions SET expires_at=0").run();
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
  const friendMembershipId = "friend-membership";
  DB.raw.prepare("INSERT INTO users VALUES(?,?,?)").run(friendMembershipId, "friend@example.com", "Friend");
  DB.raw.prepare("INSERT INTO ef_membership_links VALUES(?,?)").run(friendMembershipId, "friend");
  DB.raw.prepare("INSERT INTO sessions VALUES(?,?,?,?)")
    .run(crypto.randomUUID(), friendMembershipId, await hash(ft), Math.floor(Date.now() / 1000) + 1000);
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
  assert.equal(DB.raw.prepare("SELECT count(*) as n FROM sessions").get().n, 0);
});
test("logout revokes the shared BatesAI session and clears its cookie", async () => {
  const { DB, token } = await setup();
  const response = await request({ DB }, "logout", "POST", {}, auth(token));
  assert.equal(response.status, 200);
  assert.match(response.headers.get("set-cookie"), /batesai_session=.*Path=\//);
  assert.equal((await request({ DB }, "me", "GET", null, auth(token))).status, 401);
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
