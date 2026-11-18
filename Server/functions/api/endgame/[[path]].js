// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// Facebook is the sole identity provider. Provider tokens never reach clients or storage.
import {
  validateState,
  stats,
  weeklySessions,
  completedSets,
} from "../../_lib/endgame-engine.mjs";
const ORIGIN = "https://batesai.org",
  COOKIE = "__Secure-ef_session",
  STATE = "__Secure-ef_oauth";
const TTL = 30 * 86400;
const now = () => Math.floor(Date.now() / 1000);
const random = () =>
  Array.from(crypto.getRandomValues(new Uint8Array(32)), (x) =>
    x.toString(16).padStart(2, "0"),
  ).join("");
export const hash = async (s) =>
  Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)),
    ),
    (x) => x.toString(16).padStart(2, "0"),
  ).join("");
const cookie = (r, k) =>
  (r.headers.get("Cookie") || "")
    .split(";")
    .map((x) => x.trim())
    .find((x) => x.startsWith(k + "="))
    ?.slice(k.length + 1) || "";
const cookieValue = (name, value, ttl) =>
  `${name}=${value}; Path=/api/endgame; Max-Age=${ttl}; HttpOnly; Secure; SameSite=Lax`;
function reply(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...headers,
    },
  });
}
function redirect(url, cookies = []) {
  const h = new Headers({
    Location: url,
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
  });
  for (const c of cookies) h.append("Set-Cookie", c);
  return new Response(null, { status: 302, headers: h });
}
const configured = (env) =>
  /^\d+$/.test(env.FACEBOOK_APP_ID || "") && !!env.FACEBOOK_APP_SECRET;
const apiVersion = (env) =>
  /^v\d+\.0$/.test(env.FACEBOOK_GRAPH_VERSION || "")
    ? env.FACEBOOK_GRAPH_VERSION
    : "v27.0";
async function session(request, env) {
  const token =
    (request.headers.get("Authorization") || "").replace(/^Bearer /, "") ||
    cookie(request, COOKIE);
  if (!token) return null;
  return env.DB.prepare(
    "SELECT a.id,a.display_name,a.friend_code,s.expires_at FROM ef_sessions s JOIN ef_accounts a ON a.id=s.user_id WHERE s.token_hash=? AND s.expires_at>?",
  )
    .bind(await hash(token), now())
    .first();
}
async function issue(env, id) {
  const token = random();
  await env.DB.prepare(
    "INSERT INTO ef_sessions(token_hash,user_id,expires_at) VALUES(?,?,?)",
  )
    .bind(await hash(token), id, now() + TTL)
    .run();
  return token;
}
export function validMutation(request) {
  return (
    request.headers.get("Origin") === ORIGIN &&
    request.headers.get("Content-Type")?.startsWith("application/json")
  );
}
async function boundedJSON(request) {
  const text = await request.text();
  if (text.length > 3000000) throw Error("Payload too large");
  return JSON.parse(text);
}
async function graph(env, path, token) {
  const url = new URL(`https://graph.facebook.com/${apiVersion(env)}/${path}`);
  const proofKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.FACEBOOK_APP_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const proof = await crypto.subtle.sign(
    "HMAC",
    proofKey,
    new TextEncoder().encode(token),
  );
  url.searchParams.set(
    "appsecret_proof",
    Array.from(new Uint8Array(proof), (x) =>
      x.toString(16).padStart(2, "0"),
    ).join(""),
  );
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(10000),
  });
  if (!res.ok) throw Error("Facebook verification failed");
  return res.json();
}
async function oauth(request, env, path) {
  if (!configured(env))
    return reply(
      {
        error: "Facebook sign-in is awaiting Meta app configuration.",
        code: "FACEBOOK_NOT_CONFIGURED",
      },
      503,
    );
  const url = new URL(request.url),
    callback = ORIGIN + "/api/endgame/auth/callback";
  if (path === "start") {
    if (request.method !== "GET")
      return reply({ error: "Method not allowed" }, 405);
    const native = url.searchParams.get("native") === "1",
      challenge = url.searchParams.get("challenge");
    if (native && !/^[A-Za-z0-9_-]{43}$/.test(challenge || ""))
      return reply({ error: "Invalid native verifier challenge" }, 400);
    const state = random();
    await env.DB.prepare("DELETE FROM ef_oauth_states WHERE expires_at<?")
      .bind(now())
      .run();
    await env.DB.prepare(
      "INSERT INTO ef_oauth_states(state_hash,native,challenge,expires_at) VALUES(?,?,?,?)",
    )
      .bind(await hash(state), native ? 1 : 0, challenge || null, now() + 600)
      .run();
    const target = new URL(
      `https://www.facebook.com/${apiVersion(env)}/dialog/oauth`,
    );
    for (const [k, v] of Object.entries({
      client_id: env.FACEBOOK_APP_ID,
      redirect_uri: callback,
      response_type: "code",
      state,
      scope: "public_profile",
    }))
      target.searchParams.set(k, v);
    return redirect(target.toString(), [cookieValue(STATE, state, 600)]);
  }
  if (path !== "callback" || request.method !== "GET")
    return reply({ error: "Unknown authentication endpoint" }, 404);
  const state = url.searchParams.get("state") || "";
  if (!/^[a-f0-9]{64}$/.test(state) || cookie(request, STATE) !== state)
    return reply(
      {
        error:
          "Sign-in state expired or invalid. Start again from Endgame Fitness.",
      },
      400,
    );
  const entry = await env.DB.prepare(
    "DELETE FROM ef_oauth_states WHERE state_hash=? AND expires_at>? RETURNING native,challenge",
  )
    .bind(await hash(state), now())
    .first();
  if (!entry)
    return reply({ error: "This sign-in has expired. Please try again." }, 400);
  const clear = cookieValue(STATE, "", 0);
  if (url.searchParams.has("error"))
    return redirect(ORIGIN + "/endgamefitness/?auth=cancelled", [clear]);
  const code = url.searchParams.get("code");
  if (!code || code.length > 4096)
    return reply({ error: "Missing authorization code" }, 400);
  const tokenResponse = await fetch(
    `https://graph.facebook.com/${apiVersion(env)}/oauth/access_token`,
    {
      method: "POST",
      body: new URLSearchParams({
        client_id: env.FACEBOOK_APP_ID,
        client_secret: env.FACEBOOK_APP_SECRET,
        redirect_uri: callback,
        code,
      }),
      signal: AbortSignal.timeout(10000),
    },
  );
  const tokens = await tokenResponse.json();
  if (!tokenResponse.ok || !tokens.access_token)
    return reply(
      { error: "Facebook could not complete sign-in. Try again." },
      401,
      { "Set-Cookie": clear },
    );
  const me = await graph(env, "me?fields=id,name", tokens.access_token);
  if (!/^\d+$/.test(me.id || "") || typeof me.name !== "string")
    return reply({ error: "Invalid Facebook identity" }, 401);
  let account = await env.DB.prepare(
    "SELECT id FROM ef_accounts WHERE facebook_id=?",
  )
    .bind(me.id)
    .first();
  if (!account) {
    const id = crypto.randomUUID();
    await env.DB.prepare(
      "INSERT INTO ef_accounts(id,facebook_id,display_name,friend_code,created_at) VALUES(?,?,?,?,?) ON CONFLICT(facebook_id) DO NOTHING",
    )
      .bind(
        id,
        me.id,
        me.name.slice(0, 80),
        random().slice(0, 16).toUpperCase(),
        now(),
      )
      .run();
    account = await env.DB.prepare(
      "SELECT id FROM ef_accounts WHERE facebook_id=?",
    )
      .bind(me.id)
      .first();
  }
  if (entry.native) {
    const code = random();
    await env.DB.prepare(
      "INSERT INTO ef_native_codes(code_hash,user_id,challenge,expires_at) VALUES(?,?,?,?)",
    )
      .bind(await hash(code), account.id, entry.challenge, now() + 60)
      .run();
    return redirect("endgamefitness://auth?code=" + code, [clear]);
  }
  const token = await issue(env, account.id);
  return redirect(ORIGIN + "/endgamefitness/", [
    clear,
    cookieValue(COOKIE, token, TTL),
  ]);
}
export async function onRequest({ request, env, params }) {
  const path = (params.path || []).join("/");
  try {
    if (path === "config" && request.method === "GET")
      return reply({ facebook: configured(env), provider: "facebook" });
    if (path.startsWith("auth/"))
      return await oauth(request, env, path.slice(5));
    if (path === "native/exchange" && request.method === "POST") {
      const b = await boundedJSON(request);
      if (
        !/^[a-f0-9]{64}$/.test(b.code || "") ||
        !/^[A-Za-z0-9_-]{43,128}$/.test(b.verifier || "")
      )
        return reply({ error: "Invalid exchange" }, 400);
      const bytes = new Uint8Array(
        await crypto.subtle.digest(
          "SHA-256",
          new TextEncoder().encode(b.verifier),
        ),
      );
      const challenge = btoa(String.fromCharCode(...bytes))
        .replace(/\+/g, "-")
        .replace(/\//g, "_")
        .replace(/=+$/, "");
      // Wrong verifiers cannot consume a legitimate code.
      const entry = await env.DB.prepare(
        "DELETE FROM ef_native_codes WHERE code_hash=? AND challenge=? AND expires_at>? RETURNING user_id",
      )
        .bind(await hash(b.code), challenge, now())
        .first();
      if (!entry)
        return reply({ error: "Sign-in code expired or invalid" }, 401);
      return reply({ token: await issue(env, entry.user_id), expires_in: TTL });
    }
    if (
      !["GET", "HEAD"].includes(request.method) &&
      !request.headers.get("Authorization")?.startsWith("Bearer ") &&
      !validMutation(request)
    )
      return reply({ error: "Invalid request origin or content type" }, 403);
    if (!env.DB) return reply({ error: "Storage is unavailable" }, 503);
    const user = await session(request, env);
    if (!user)
      return reply({ error: "Sign in with Facebook to continue" }, 401);
    if (path === "me" && request.method === "GET") return reply({ user });
    if (path === "logout" && request.method === "POST") {
      const token =
        (request.headers.get("Authorization") || "").replace(/^Bearer /, "") ||
        cookie(request, COOKIE);
      await env.DB.prepare("DELETE FROM ef_sessions WHERE token_hash=?")
        .bind(await hash(token))
        .run();
      return reply({ ok: true }, 200, {
        "Set-Cookie": cookieValue(COOKIE, "", 0),
      });
    }
    if (path === "state" && request.method === "GET") {
      const row = await env.DB.prepare(
        "SELECT data,revision FROM ef_state WHERE user_id=?",
      )
        .bind(user.id)
        .first();
      return reply({
        state: row ? JSON.parse(row.data) : null,
        revision: row?.revision || 0,
      });
    }
    if (path === "state" && request.method === "PUT") {
      const b = await boundedJSON(request);
      if (!Number.isSafeInteger(b.revision) || b.revision < 0)
        return reply({ error: "Invalid revision" }, 400);
      const v = validateState(b.state);
      if (
        v.players.length !== 1 ||
        v.players[0].id !== user.id ||
        v.selected !== user.id ||
        v.rivals.length
      )
        return reply(
          { error: "State must belong to your Facebook account" },
          400,
        );
      let result;
      if (b.revision === 0)
        result = await env.DB.prepare(
          "INSERT INTO ef_state(user_id,data,revision,updated_at) VALUES(?,?,1,?) ON CONFLICT(user_id) DO NOTHING",
        )
          .bind(user.id, JSON.stringify(v), now())
          .run();
      else
        result = await env.DB.prepare(
          "UPDATE ef_state SET data=?,revision=revision+1,updated_at=? WHERE user_id=? AND revision=?",
        )
          .bind(JSON.stringify(v), now(), user.id, b.revision)
          .run();
      if (!result.meta.changes)
        return reply(
          {
            error:
              "Another device saved changes. Reload cloud data before saving again.",
          },
          409,
        );
      return reply({ revision: b.revision + 1 });
    }
    if (path === "friends" && request.method === "POST") {
      const b = await boundedJSON(request),
        code = String(b.code || "")
          .trim()
          .toUpperCase();
      if (!/^[A-F0-9]{16}$/.test(code))
        return reply({ error: "Enter a valid 16-character friend code" }, 400);
      const target = await env.DB.prepare(
        "SELECT id FROM ef_accounts WHERE friend_code=?",
      )
        .bind(code)
        .first();
      if (!target || target.id === user.id)
        return reply({ error: "Friend code not found" }, 404);
      const reverse = await env.DB.prepare(
        "SELECT requester FROM ef_friendships WHERE requester=? AND recipient=?",
      )
        .bind(target.id, user.id)
        .first();
      if (reverse)
        await env.DB.prepare(
          "UPDATE ef_friendships SET accepted=1 WHERE requester=? AND recipient=?",
        )
          .bind(target.id, user.id)
          .run();
      else
        await env.DB.prepare(
          "INSERT INTO ef_friendships(requester,recipient,accepted,created_at) VALUES(?,?,0,?) ON CONFLICT DO NOTHING",
        )
          .bind(user.id, target.id, now())
          .run();
      return reply({ ok: true });
    }
    if (path === "friends/respond" && request.method === "POST") {
      const b = await boundedJSON(request);
      if (typeof b.id !== "string" || typeof b.accept !== "boolean")
        return reply({ error: "Invalid response" }, 400);
      await env.DB.prepare(
        b.accept
          ? "UPDATE ef_friendships SET accepted=1 WHERE requester=? AND recipient=?"
          : "DELETE FROM ef_friendships WHERE requester=? AND recipient=?",
      )
        .bind(b.id, user.id)
        .run();
      return reply({ ok: true });
    }
    if (path === "friends/remove" && request.method === "POST") {
      const b = await boundedJSON(request);
      if (typeof b.id !== "string")
        return reply({ error: "Invalid friend" }, 400);
      await env.DB.prepare(
        "DELETE FROM ef_friendships WHERE (requester=? AND recipient=?) OR (requester=? AND recipient=?)",
      )
        .bind(user.id, b.id, b.id, user.id)
        .run();
      return reply({ ok: true });
    }
    if (path === "social" && request.method === "GET") {
      const { results } = await env.DB.prepare(
        "SELECT f.requester,f.recipient,f.accepted,a.id,a.display_name,s.data FROM ef_friendships f JOIN ef_accounts a ON a.id=CASE WHEN f.requester=? THEN f.recipient ELSE f.requester END LEFT JOIN ef_state s ON s.user_id=a.id WHERE f.requester=? OR f.recipient=?",
      )
        .bind(user.id, user.id, user.id)
        .all();
      const friends = [],
        incoming = [],
        outgoing = [];
      for (const row of results) {
        if (!row.accepted) {
          (row.recipient === user.id ? incoming : outgoing).push({
            id: row.id,
            name: row.display_name,
          });
          continue;
        }
        let p;
        try {
          p = JSON.parse(row.data || "null")?.players?.[0];
        } catch {}
        const s = p ? stats(p) : { xp: 0, level: 1, sessions: 0, sets: 0 };
        const week = p ? weeklySessions(p) : [];
        friends.push({
          id: row.id,
          name: row.display_name,
          ...s,
          weeklyDays: new Set(week.map((s) => s.day)).size,
          weeklySets: week.reduce((n, s) => n + completedSets(s).length, 0),
        });
      }
      return reply({ friends, incoming, outgoing, verified: false });
    }
    if (path === "account" && request.method === "DELETE") {
      const b = await boundedJSON(request);
      if (b.confirm !== "DELETE")
        return reply({ error: "Confirmation required" }, 400);
      await env.DB.batch([
        env.DB.prepare(
          "DELETE FROM ef_friendships WHERE requester=? OR recipient=?",
        ).bind(user.id, user.id),
        env.DB.prepare("DELETE FROM ef_state WHERE user_id=?").bind(user.id),
        env.DB.prepare("DELETE FROM ef_native_codes WHERE user_id=?").bind(
          user.id,
        ),
        env.DB.prepare("DELETE FROM ef_sessions WHERE user_id=?").bind(user.id),
        env.DB.prepare("DELETE FROM ef_accounts WHERE id=?").bind(user.id),
      ]);
      return reply({ ok: true }, 200, {
        "Set-Cookie": cookieValue(COOKIE, "", 0),
      });
    }
    return reply({ error: "Unknown endpoint" }, 404);
  } catch (e) {
    if (
      e instanceof SyntaxError ||
      /Invalid|Unsupported|Choose|Use a player|Selected|Payload/.test(
        e.message || "",
      )
    )
      return reply({ error: e.message }, 400);
    return reply(
      {
        error:
          "Endgame Fitness could not complete this request. Please try again.",
      },
      500,
    );
  }
}
