import {guildAction} from "../../_lib/guilds.mjs";
// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// BatesAI Membership is the sole identity system. Endgame accepts its shared
// Google/Apple session and never receives provider tokens.
import {
  validateState,
  stats,
  weeklySessions,
  completedSets,
} from "../../_lib/endgame-engine.mjs";
const ORIGIN = "https://batesai.org";
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
const authToken = (request) => {
  const authorization = request.headers.get("Authorization") || "";
  return authorization.startsWith("Bearer ")
    ? authorization.slice(7).trim()
    : cookie(request, "batesai_session");
};
const clearSessionCookie =
  "batesai_session=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax";
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
async function session(request, env) {
  const token = authToken(request);
  if (!token) return null;
  const identity = await env.DB.prepare(
    "SELECT u.id AS membership_user_id, COALESCE(NULLIF(u.name,''),u.email) AS display_name,s.expires_at FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.expires_at>?",
  )
    .bind(await hash(token), now())
    .first();
  if (!identity) return null;

  let link = await env.DB.prepare(
    "SELECT a.id,a.display_name,a.friend_code FROM ef_membership_links l JOIN ef_accounts a ON a.id=l.user_id WHERE l.membership_user_id=?",
  )
    .bind(identity.membership_user_id)
    .first();
  if (!link) {
    const id = crypto.randomUUID();
    const displayName = String(identity.display_name || "BatesAI member").trim().slice(0, 80) || "BatesAI member";
    const memberKey = `batesai:${identity.membership_user_id}`;
    await env.DB.prepare(
      "INSERT INTO ef_accounts(id,facebook_id,display_name,friend_code,created_at) VALUES(?,?,?,?,?) ON CONFLICT(facebook_id) DO NOTHING",
    )
      .bind(id, memberKey, displayName, random().slice(0, 16).toUpperCase(), now())
      .run();
    const account = await env.DB.prepare(
      "SELECT id FROM ef_accounts WHERE facebook_id=?",
    )
      .bind(memberKey)
      .first();
    await env.DB.prepare(
      "INSERT INTO ef_membership_links(membership_user_id,user_id) VALUES(?,?) ON CONFLICT(membership_user_id) DO NOTHING",
    )
      .bind(identity.membership_user_id, account.id)
      .run();
    link = await env.DB.prepare(
      "SELECT a.id,a.display_name,a.friend_code FROM ef_membership_links l JOIN ef_accounts a ON a.id=l.user_id WHERE l.membership_user_id=?",
    )
      .bind(identity.membership_user_id)
      .first();
  }
  const displayName = String(identity.display_name || link.display_name || "BatesAI member").trim().slice(0, 80) || "BatesAI member";
  if (link.display_name !== displayName) {
    await env.DB.prepare("UPDATE ef_accounts SET display_name=? WHERE id=?")
      .bind(displayName, link.id)
      .run();
  }
  return {
    id: link.id,
    membership_user_id: identity.membership_user_id,
    display_name: displayName,
    friend_code: link.friend_code,
    expires_at: identity.expires_at,
  };
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
export async function onRequest({ request, env, params }) {
  const path = (params.path || []).join("/");
  try {
    if (path === "config" && request.method === "GET")
      return reply({ providers: ["google", "apple"], provider: "batesai-membership" });
    if (path.startsWith("auth/"))
      return reply({ error: "Use BatesAI Membership to sign in" }, 404);
    if (
      !["GET", "HEAD"].includes(request.method) &&
      !request.headers.get("Authorization")?.startsWith("Bearer ") &&
      !validMutation(request)
    )
      return reply({ error: "Invalid request origin or content type" }, 403);
    if (!env.DB) return reply({ error: "Storage is unavailable" }, 503);
    const user = await session(request, env);
    if (!user)
      return reply({ error: "Sign in with your BatesAI account to continue" }, 401);
    if (path === "me" && request.method === "GET") return reply({ user });
    if (path === "logout" && request.method === "POST") {
      const token = authToken(request);
      await env.DB.prepare("DELETE FROM sessions WHERE token_hash=?")
        .bind(await hash(token))
        .run();
      return reply({ ok: true }, 200, {
        "Set-Cookie": clearSessionCookie,
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
          { error: "State must belong to your BatesAI account" },
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
    if (path === "guild/status" && request.method === "GET")
      return reply(await guildAction(env.DB,user.id,"status",{}));
    if (["guild/create","guild/join","guild/leave"].includes(path) && request.method === "POST")
      return reply(await guildAction(env.DB,user.id,path.split("/")[1],await boundedJSON(request)));
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
      const token = authToken(request);
      await env.DB.batch([
        env.DB.prepare("DELETE FROM sessions WHERE token_hash=?").bind(await hash(token)),
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
        "Set-Cookie": clearSessionCookie,
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
