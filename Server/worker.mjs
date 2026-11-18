// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
import { onRequest } from "./functions/api/endgame/[[path]].js";
const security = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  "Content-Security-Policy":
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; worker-src 'self'; manifest-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
};
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/api/endgame/"))
      return onRequest({
        request,
        env,
        params: {
          path: url.pathname
            .slice("/api/endgame/".length)
            .split("/")
            .filter(Boolean),
        },
        waitUntil: ctx.waitUntil.bind(ctx),
      });
    if (url.pathname === "/endgamefitness")
      return Response.redirect(
        url.origin + "/endgamefitness/" + url.search,
        308,
      );
    if (!url.pathname.startsWith("/endgamefitness/"))
      return new Response("Not found", { status: 404 });
    const assetURL = new URL(request.url);
    assetURL.pathname = url.pathname.slice("/endgamefitness".length);
    const response = await env.ASSETS.fetch(new Request(assetURL, request));
    const headers = new Headers(response.headers);
    const location = headers.get("Location");
    if (location?.startsWith("/") && !location.startsWith("/endgamefitness/"))
      headers.set("Location", "/endgamefitness" + location);
    for (const [k, v] of Object.entries(security)) headers.set(k, v);
    headers.set("Cache-Control", "no-cache");
    return new Response(response.body, { status: response.status, headers });
  },
};
