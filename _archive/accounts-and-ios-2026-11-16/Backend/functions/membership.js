/**
 * /membership — the OAuth landing route for Google (GET) and Sign in with
 * Apple's form_post (POST).
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Ported from production (the website repo's functions/membership.js, live on
 * batesai.org as of 2026-10-27) so this repo can reproduce production auth on
 * its own. The web behaviour below is unchanged from that copy; the additions
 * are the native-app handoff and the Apple return path, both opt-in by cookie.
 *
 * Google is configured to send users back to https://batesai.org/membership
 * (no trailing slash), which Cloudflare Pages would otherwise 308 to
 * /membership/ and serve as a static page. That static page used to redeem the
 * ?code in the browser, which is fragile: authorization codes are single-use,
 * so any reload, back/forward restore, bfcache resume, prefetch or webview
 * replay of that URL redeems an already-spent code and Google answers
 * invalid_grant. The user sees a failure even though the first redemption
 * succeeded.
 *
 * This function shadows the bare /membership path so the code is redeemed
 * server-side, exactly once, and never reaches a document the browser can
 * re-execute. The browser only ever sees /membership/?signed_in=1 (session
 * cookie already set) or /membership/?error=<reason>.
 *
 * Without a ?code this route reproduces the trailing-slash redirect it
 * replaces, so /membership keeps behaving exactly as before.
 *
 * Return path: if sign-in began at /api/auth/oauth/{google,apple}?return_to=<path>,
 * an oauth_return_to cookie names where to land instead of /membership/ —
 * <path>?signed_in=1 on success, <path>?signin_error=<reason> on failure —
 * and is cleared on the way out. Without that cookie every response here is
 * exactly what it was before; DaemonManager's sign-in webview depends on
 * seeing /membership/?signed_in=1. See functions/_lib/return-to.js.
 *
 * Native app (Docs/API_V2.md §1.1): if sign-in began with
 * ?redirect_scheme=endgamefitness, an oauth_app_scheme cookie is present. Then
 * no web session is created; the auth API mints a one-time code instead and
 * this route answers 302 endgamefitness://auth?code=<code> (or
 * endgamefitness://auth?error=<reason> on failure, so the app's sign-in sheet
 * never strands on a web page). The app trades the code for a session with
 * POST /api/auth/handoff. The session token never appears in a URL.
 */

import { RETURN_TO_COOKIE, CLEAR_RETURN_TO_COOKIE, safeReturnPath } from './_lib/return-to.js';

// Must match APP_SCHEMES in functions/api/auth/[[path]].js. The cookie is
// re-validated here because a sibling *.batesai.org host could plant one.
const APP_SCHEMES = ['endgamefitness'];
const APP_SCHEME_COOKIE = 'oauth_app_scheme';

export async function onRequestGet(context) {
  const { request } = context;
  const url = new URL(request.url);
  // Pages also routes /membership/ (trailing slash) to this file. Only the
  // bare path is the OAuth landing; the page itself is the static build. Left
  // to the code below, /membership/ would 308 to itself forever, which is what
  // the 7eea212f deployments did (curl: "Maximum redirects followed").
  if (url.pathname !== '/membership') return context.next();
  const target = new URL('/membership/', url.origin);
  const appScheme = allowedAppScheme(readCookie(request, APP_SCHEME_COOKIE));
  // null unless this sign-in started with ?return_to=; then failures go back
  // to that page rather than to /membership/.
  const returnTo = safeReturnPath(readCookie(request, RETURN_TO_COOKIE));
  const fail = (reason) => {
    if (appScheme) return bounceToApp(appScheme, reason, request, 'Lax');
    return returnTo ? bounceBack(url, returnTo, reason) : bounce(target, reason);
  };

  const code = url.searchParams.get('code');
  if (!code) {
    // A refused consent screen comes back as ?error=… with no code at all.
    if ((appScheme || returnTo) && url.searchParams.get('error')) return fail('access_denied');
    target.search = url.search;
    return Response.redirect(target.toString(), 308);
  }

  // Google reports user-facing failures (consent denied, closed window) here.
  const googleError = url.searchParams.get('error');
  if (googleError) return fail('access_denied');

  // CSRF: the state cookie is set when we send the user to Google. Treat a
  // missing cookie as acceptable (it expires after 5 minutes, and a slow
  // sign-in is not an attack) but a *mismatched* one as hostile.
  const cookieState = readCookie(request, 'google_oauth_state');
  if (cookieState && cookieState !== url.searchParams.get('state')) {
    return fail('state_mismatch');
  }

  const payload = { authorization_code: code };
  if (appScheme) payload.app_scheme = appScheme;

  let res;
  try {
    res = await fetch(`${url.origin}/api/auth/oauth/google`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Cookie: request.headers.get('cookie') || '',
      },
      body: JSON.stringify(payload),
    });
  } catch (e) {
    console.error('membership callback: exchange subrequest failed:', e && e.message);
    return fail('server_error');
  }

  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    console.error('membership callback: exchange rejected:', res.status, detail);
    return fail(detailToReason(detail));
  }

  if (appScheme) {
    return handoffToApp(appScheme, res, request, 'Lax', [
      'google_oauth_state=; Path=/; Max-Age=0; SameSite=Lax; Secure; HttpOnly',
    ]);
  }

  // Hand the browser the session cookie the API just minted, then send it to
  // the real page. The authorization code never appears in a loadable URL.
  const landing = returnTo ? new URL(returnTo, url.origin) : target;
  landing.search = '?signed_in=1';
  const out = new Response(null, { status: 302, headers: { Location: landing.toString() } });
  for (const value of setCookies(res)) out.headers.append('Set-Cookie', value);
  // The one-shot state cookie has done its job.
  out.headers.append('Set-Cookie', 'google_oauth_state=; Path=/; Max-Age=0; SameSite=Lax; Secure; HttpOnly');
  if (returnTo) out.headers.append('Set-Cookie', CLEAR_RETURN_TO_COOKIE);
  return out;
}

/**
 * POST /membership — Sign in with Apple's `form_post` callback.
 *
 * Apple does not redirect back with a query string; it POSTs a form to the
 * return URL from appleid.apple.com, which is a cross-site request. Nothing
 * static can receive that, so before this existed the Apple button led to a
 * dead end. The response asks for "code id_token", so the signed identity
 * token is right here in the body and no client secret is involved.
 *
 * Because the POST is cross-site, only SameSite=None cookies arrive with it;
 * GET /api/auth/oauth/apple sets its state, return-path and app-scheme cookies
 * that way for exactly this reason.
 */
export async function onRequestPost(context) {
  const { request } = context;
  const url = new URL(request.url);
  const target = new URL('/membership/', url.origin);
  const appScheme = allowedAppScheme(readCookie(request, APP_SCHEME_COOKIE));
  const returnTo = safeReturnPath(readCookie(request, RETURN_TO_COOKIE));
  const fail = (reason) => {
    if (appScheme) return bounceToApp(appScheme, reason, request, 'None');
    return returnTo ? bounceBack(url, returnTo, reason) : bounce(target, reason);
  };

  let form;
  try {
    form = await request.formData();
  } catch {
    return fail('bad_response');
  }

  if (form.get('error')) return fail('access_denied');

  const idToken = form.get('id_token');
  const code = form.get('code');
  if (!idToken && !code) return fail('no_identity_token');

  // The state cookie is SameSite=None precisely so it survives this cross-site
  // POST. If it is absent the request may simply have taken longer than five
  // minutes; only a mismatch is treated as hostile.
  const cookieState = readCookie(request, 'apple_oauth_state');
  if (cookieState && cookieState !== form.get('state')) {
    return fail('state_mismatch');
  }

  const payload = { user: parseAppleUser(form.get('user')) };
  if (idToken) payload.id_token = idToken;
  else payload.authorization_code = code;
  if (appScheme) payload.app_scheme = appScheme;

  let res;
  try {
    res = await fetch(`${url.origin}/api/auth/oauth/apple`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Cookie: request.headers.get('cookie') || '',
      },
      body: JSON.stringify(payload),
    });
  } catch (e) {
    console.error('membership callback: apple subrequest failed:', e && e.message);
    return fail('server_error');
  }

  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    console.error('membership callback: apple sign-in rejected:', res.status, detail);
    if (/not fully configured/.test(detail)) return fail('not_configured');
    return fail(/account_exists/.test(detail) ? 'account_exists' : 'token_rejected');
  }

  if (appScheme) {
    return handoffToApp(appScheme, res, request, 'None', [
      'apple_oauth_state=; Path=/; Max-Age=0; SameSite=None; Secure; HttpOnly',
    ]);
  }

  const landing = returnTo ? new URL(returnTo, url.origin) : target;
  landing.search = '?signed_in=1';
  const out = new Response(null, { status: 302, headers: { Location: landing.toString() } });
  for (const value of setCookies(res)) out.headers.append('Set-Cookie', value);
  out.headers.append('Set-Cookie', 'apple_oauth_state=; Path=/; Max-Age=0; SameSite=None; Secure; HttpOnly');
  if (returnTo) out.headers.append('Set-Cookie', CLEAR_RETURN_TO_COOKIE);
  return out;
}

/**
 * Apple sends the user's name exactly once, on the first authorisation, as a
 * JSON string in a form field. Every later sign-in omits it.
 */
function parseAppleUser(raw) {
  if (!raw) return null;
  try { return JSON.parse(raw); } catch { return null; }
}

function bounce(target, reason) {
  target.search = `?error=${encodeURIComponent(reason)}`;
  return Response.redirect(target.toString(), 302);
}

/** Failure with a return path: back to that page, and drop the cookie. */
function bounceBack(url, path, reason) {
  const location = new URL(path, url.origin);
  location.search = `?signin_error=${encodeURIComponent(reason)}`;
  return new Response(null, {
    status: 302,
    headers: [['Location', location.toString()], ['Set-Cookie', CLEAR_RETURN_TO_COOKIE]],
  });
}

/**
 * Success for a native-app sign-in: the auth API answered {handoff_code}
 * instead of a session. Send the code to the app's scheme and drop every
 * one-shot cookie this flow used. No batesai_session cookie is set.
 */
async function handoffToApp(scheme, res, request, sameSite, extraCookies) {
  const data = await res.json().catch(() => null);
  const code = data && typeof data.handoff_code === 'string' ? data.handoff_code : '';
  if (!/^[A-Za-z0-9_-]{43}$/.test(code)) {
    console.error('membership callback: handoff response carried no code');
    return bounceToApp(scheme, 'server_error', request, sameSite);
  }
  const out = appRedirect(`${scheme}://auth?code=${code}`);
  appendAppCleanup(out.headers, request, sameSite);
  for (const value of extraCookies) out.headers.append('Set-Cookie', value);
  return out;
}

/** Failure for a native-app sign-in: tell the app, rather than strand its sheet. */
function bounceToApp(scheme, reason, request, sameSite) {
  const out = appRedirect(`${scheme}://auth?error=${encodeURIComponent(reason)}`);
  appendAppCleanup(out.headers, request, sameSite);
  return out;
}

function appRedirect(location) {
  // Built by hand: Response.redirect() is only specified for http(s) URLs.
  // no-store, because this response carries a live sign-in code.
  return new Response(null, {
    status: 302,
    headers: { Location: location, 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' },
  });
}

function appendAppCleanup(headers, request, sameSite) {
  headers.append('Set-Cookie', `${APP_SCHEME_COOKIE}=; Path=/; Max-Age=0; SameSite=${sameSite}; Secure; HttpOnly`);
  if (readCookie(request, RETURN_TO_COOKIE)) headers.append('Set-Cookie', CLEAR_RETURN_TO_COOKIE);
}

function allowedAppScheme(value) {
  return APP_SCHEMES.includes(value) ? value : null;
}

/** Map Google's OAuth error codes onto the reasons the page knows how to explain. */
function detailToReason(body) {
  if (/invalid_grant/.test(body)) return 'code_replayed';
  if (/redirect_uri_mismatch/.test(body)) return 'not_configured';
  if (/invalid_client/.test(body)) return 'not_configured';
  if (/account_exists/.test(body)) return 'account_exists';
  return 'token_rejected';
}

function setCookies(res) {
  // getSetCookie() is the only correct way to read multiple Set-Cookie headers;
  // fall back to the single-header form on runtimes that lack it.
  if (typeof res.headers.getSetCookie === 'function') return res.headers.getSetCookie();
  const single = res.headers.get('set-cookie');
  return single ? [single] : [];
}

function readCookie(request, name) {
  const header = request.headers.get('cookie') || '';
  for (const part of header.split(';')) {
    const [k, ...v] = part.trim().split('=');
    if (k === name) return v.join('=');
  }
  return '';
}
