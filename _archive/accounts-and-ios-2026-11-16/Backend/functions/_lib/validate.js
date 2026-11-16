/**
 * Input validation for the fitness API: profile patches, guild fields,
 * comments, reports and reaction emoji. Import-only (files under
 * functions/_lib/ are not routed). Pure: no DB, no clock.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Every validator returns { ok: true, ... } or { ok: false, error } where
 * `error` is the machine-readable code the API sends back with a 400. A wrong
 * type is always a 400, never a 500.
 */

import { containsBlockedTerm } from './profanity.js';

/* ------------------------------------------------------------------ */
/* Text helpers                                                        */
/* ------------------------------------------------------------------ */

/** Strip control characters, collapse runs of whitespace, trim. */
export function cleanText(value) {
  return String(value)
    .normalize('NFC')
    .replace(/[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u2028-\u202E\u2060-\u206F\uFEFF]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** Like cleanText but keeps line breaks (bios, comments). */
export function cleanMultiline(value) {
  return String(value)
    .normalize('NFC')
    .replace(/\r\n?/g, '\n')
    .replace(/[\u0000-\u0009\u000B-\u001F\u007F-\u009F\u200B-\u200F\u2028-\u202E\u2060-\u206F\uFEFF]/g, ' ')
    .replace(/[ \t]+/g, ' ')
    .replace(/ ?\n ?/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/** Length in user-perceived characters (an emoji counts once). */
export function charLength(s) {
  return [...String(s)].length;
}

const NAME_PATTERN = /^[\p{L}\p{M}\p{N} _\-.']+$/u;

/** 2–24 characters of letters, digits, space and _-.' with no blocked term. */
export function validateDisplayName(value) {
  if (typeof value !== 'string') return { ok: false, error: 'display_name_invalid' };
  const name = cleanText(value);
  const len = charLength(name);
  if (len < 2 || len > 24) return { ok: false, error: 'display_name_invalid' };
  if (!NAME_PATTERN.test(name)) return { ok: false, error: 'display_name_invalid' };
  if (!/[\p{L}\p{N}]/u.test(name)) return { ok: false, error: 'display_name_invalid' };
  if (containsBlockedTerm(name)) return { ok: false, error: 'display_name_invalid' };
  return { ok: true, value: name };
}

/** Optional free text: null/empty clears it; otherwise ≤ max chars, filtered. */
export function validateOptionalText(value, { max, error, multiline = false }) {
  if (value === null || value === undefined) return { ok: true, value: null };
  if (typeof value !== 'string') return { ok: false, error };
  const text = multiline ? cleanMultiline(value) : cleanText(value);
  if (!text) return { ok: true, value: null };
  if (charLength(text) > max) return { ok: false, error };
  if (containsBlockedTerm(text)) return { ok: false, error };
  return { ok: true, value: text };
}

/* ------------------------------------------------------------------ */
/* Profile                                                             */
/* ------------------------------------------------------------------ */

export const BIO_MAX = 160;
export const AVATAR_CONFIG_MAX_BYTES = 4096;
export const TZ_OFFSET_MIN = -840;
export const TZ_OFFSET_MAX = 840;

// Keys of AvatarBodyProfile (AvatarSystem.swift). Anything else is dropped so
// the blob cannot be used as free storage or to smuggle text onto a card.
export const AVATAR_CONFIG_KEYS = Object.freeze([
  'height', 'bodyType', 'bellySize', 'muscleLevel', 'leanLevel', 'shoulderWidth',
  'legThickness', 'skinColor', 'hasEyes', 'hasMouth', 'outfit',
]);

// v1 clients send imperial/metric (PWA select); v2 sends lb/kg. All four are
// stored as sent so old clients read back the value they wrote.
export const UNIT_VALUES = Object.freeze(['lb', 'kg', 'imperial', 'metric']);
export const weightUnitOf = (units) => (units === 'kg' || units === 'metric' ? 'kg' : 'lb');

/** Parse a tz offset in minutes (−840…840). Returns null when invalid. */
export function parseTzOffset(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null;
  const v = Math.round(value);
  return v >= TZ_OFFSET_MIN && v <= TZ_OFFSET_MAX ? v : null;
}

/**
 * Keep only known keys whose values are short scalars. Returns
 * { ok, value: JSON string | null } — rejects anything that is not a plain
 * object or is over 4 KB once serialised.
 */
export function sanitizeAvatarConfig(value) {
  if (value === null) return { ok: true, value: null };
  if (typeof value !== 'object' || Array.isArray(value)) return { ok: false, error: 'avatar_config_invalid' };
  let raw;
  try { raw = JSON.stringify(value); } catch { return { ok: false, error: 'avatar_config_invalid' }; }
  if (new TextEncoder().encode(raw).length > AVATAR_CONFIG_MAX_BYTES) {
    return { ok: false, error: 'avatar_config_invalid' };
  }
  const out = {};
  for (const key of AVATAR_CONFIG_KEYS) {
    if (!(key in value)) continue;
    const v = value[key];
    if (v === null || typeof v === 'boolean') out[key] = v;
    else if (typeof v === 'number' && Number.isFinite(v)) out[key] = v;
    else if (typeof v === 'string' && charLength(v) <= 40) out[key] = cleanText(v);
  }
  return { ok: true, value: JSON.stringify(out) };
}

/** Every key PUT profile understands; a body with none of them is a 400. */
export const PROFILE_WRITABLE_FIELDS = Object.freeze([
  'display_name', 'bio', 'title', 'cosmetic', 'is_public', 'avatar_config', 'units',
  'training_goal', 'experience_level', 'equipment_level', 'body_weight', 'height_inches',
  'birth_year', 'tz_offset_min',
]);

const numberOrNull = (value, min, max, error, integer = false) => {
  if (value === null) return { ok: true, value: null };
  if (typeof value !== 'number' || !Number.isFinite(value)) return { ok: false, error };
  if (value < min || value > max) return { ok: false, error };
  return { ok: true, value: integer ? Math.round(value) : value };
};

/**
 * Validate a PUT profile body against the stored row. Returns
 * { ok: true, values: {column: value} } or { ok: false, error }.
 *
 * ctx: { current (profile row), earnedTitles: Set, earnedCosmetics: Set, year }
 *
 * Re-sending the value already stored is always allowed, so v1 clients that
 * echo the whole form back (display name + title) keep working even when an
 * older value predates these rules.
 */
export function validateProfilePatch(body, ctx) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { ok: false, error: 'body_invalid' };
  const current = ctx.current || {};
  const values = {};
  const has = (k) => Object.prototype.hasOwnProperty.call(body, k);
  const unchanged = (k) => body[k] === current[k] || (body[k] === null && current[k] == null);

  if (has('display_name') && !unchanged('display_name')) {
    const r = validateDisplayName(body.display_name);
    if (!r.ok) return r;
    values.display_name = r.value;
  }
  if (has('bio')) {
    const r = validateOptionalText(body.bio, { max: BIO_MAX, error: 'bio_invalid', multiline: true });
    if (!r.ok) return r;
    values.bio = r.value;
  }
  if (has('title') && !unchanged('title')) {
    if (body.title === null || body.title === '') values.title = null;
    else if (typeof body.title !== 'string') return { ok: false, error: 'title_invalid' };
    else {
      const t = cleanText(body.title);
      if (!t) values.title = null;
      else if (!ctx.earnedTitles || !ctx.earnedTitles.has(t)) return { ok: false, error: 'title_not_earned' };
      else values.title = t;
    }
  }
  if (has('cosmetic') && !unchanged('cosmetic')) {
    if (body.cosmetic === null || body.cosmetic === '') values.cosmetic = null;
    else if (typeof body.cosmetic !== 'string') return { ok: false, error: 'cosmetic_invalid' };
    else if (!ctx.earnedCosmetics || !ctx.earnedCosmetics.has(body.cosmetic)) {
      return { ok: false, error: 'cosmetic_not_earned' };
    } else values.cosmetic = body.cosmetic;
  }
  if (has('is_public')) {
    const v = body.is_public;
    if (typeof v === 'boolean') values.is_public = v ? 1 : 0;
    else if (v === 0 || v === 1) values.is_public = v;
    else return { ok: false, error: 'is_public_invalid' };
  }
  if (has('avatar_config')) {
    // v1 stored a JSON string; accept a string that parses to an object too.
    let v = body.avatar_config;
    if (typeof v === 'string') {
      try { v = JSON.parse(v); } catch { return { ok: false, error: 'avatar_config_invalid' }; }
    }
    const r = sanitizeAvatarConfig(v);
    if (!r.ok) return r;
    values.avatar_config = r.value;
  }
  if (has('units')) {
    if (!UNIT_VALUES.includes(body.units)) return { ok: false, error: 'units_invalid' };
    values.units = body.units;
  }
  for (const key of ['training_goal', 'experience_level', 'equipment_level']) {
    if (!has(key)) continue;
    const v = body[key];
    if (v === null) { values[key] = null; continue; }
    if (typeof v !== 'string') return { ok: false, error: `${key}_invalid` };
    const t = cleanText(v);
    if (charLength(t) > 80) return { ok: false, error: `${key}_invalid` };
    values[key] = t || null;
  }
  if (has('body_weight')) {
    const r = numberOrNull(body.body_weight, 1, 1500, 'body_weight_invalid');
    if (!r.ok) return r;
    values.body_weight = r.value;
  }
  if (has('height_inches')) {
    const r = numberOrNull(body.height_inches, 20, 120, 'height_inches_invalid');
    if (!r.ok) return r;
    values.height_inches = r.value;
  }
  if (has('birth_year')) {
    const year = ctx.year || new Date().getUTCFullYear();
    const r = numberOrNull(body.birth_year, 1900, year, 'birth_year_invalid', true);
    if (!r.ok) return r;
    values.birth_year = r.value;
  }
  if (has('tz_offset_min')) {
    const v = parseTzOffset(body.tz_offset_min);
    if (v === null) return { ok: false, error: 'tz_offset_invalid' };
    values.tz_offset_min = v;
  }
  return { ok: true, values };
}

/* ------------------------------------------------------------------ */
/* Guilds                                                              */
/* ------------------------------------------------------------------ */

const GUILD_NAME_PATTERN = /^[\p{L}\p{M}\p{N} _\-.'&!]+$/u;

export function validateGuildName(value) {
  if (typeof value !== 'string') return { ok: false, error: 'name_invalid' };
  const name = cleanText(value);
  const len = charLength(name);
  if (len < 3 || len > 32 || !GUILD_NAME_PATTERN.test(name) || !/[\p{L}\p{N}]/u.test(name)) {
    return { ok: false, error: 'name_invalid' };
  }
  if (containsBlockedTerm(name)) return { ok: false, error: 'name_invalid' };
  return { ok: true, value: name };
}

export const validateGuildMotto = (value) =>
  validateOptionalText(value, { max: 80, error: 'motto_invalid' });

/** An emblem is an SF Symbol name or a short emoji/glyph string. */
export function validateGuildEmblem(value) {
  if (value === null || value === undefined || value === '') return { ok: true, value: null };
  if (typeof value !== 'string') return { ok: false, error: 'emblem_invalid' };
  const v = cleanText(value);
  if (!v) return { ok: true, value: null };
  if (charLength(v) > 40 || /\s/.test(v)) return { ok: false, error: 'emblem_invalid' };
  if (containsBlockedTerm(v)) return { ok: false, error: 'emblem_invalid' };
  return { ok: true, value: v };
}

/* ------------------------------------------------------------------ */
/* Social                                                              */
/* ------------------------------------------------------------------ */

export const COMMENT_MAX = 280;

export function validateComment(value) {
  if (typeof value !== 'string') return { ok: false, error: 'text_invalid' };
  const text = cleanMultiline(value);
  const len = charLength(text);
  if (len < 1 || len > COMMENT_MAX) return { ok: false, error: 'text_invalid' };
  if (containsBlockedTerm(text)) return { ok: false, error: 'text_blocked' };
  return { ok: true, value: text };
}

export const REPORT_TARGETS = Object.freeze(['user', 'feed_item', 'comment', 'guild']);

export function validateReport(body) {
  if (!body || typeof body !== 'object') return { ok: false, error: 'body_invalid' };
  if (!REPORT_TARGETS.includes(body.target_type)) return { ok: false, error: 'target_type_invalid' };
  if (typeof body.target_id !== 'string' || !body.target_id || body.target_id.length > 128) {
    return { ok: false, error: 'target_id_invalid' };
  }
  if (typeof body.reason !== 'string') return { ok: false, error: 'reason_invalid' };
  const reason = cleanMultiline(body.reason);
  if (charLength(reason) < 1 || charLength(reason) > 500) return { ok: false, error: 'reason_invalid' };
  return { ok: true, target_type: body.target_type, target_id: body.target_id, reason };
}

// The contract's five, plus ⚔️ which the v1 PWA sends.
export const REACTION_EMOJI = Object.freeze(['💪', '🔥', '👏', '🏆', '⚡', '⚔️']);
const stripVariation = (s) => String(s).replace(/\uFE0F/g, '');

/** Canonical stored form of an allowed reaction, or null. */
export function canonicalEmoji(value) {
  if (typeof value !== 'string') return null;
  const bare = stripVariation(value.trim());
  return REACTION_EMOJI.find((e) => stripVariation(e) === bare) || null;
}

/** Search query: 2–32 chars after trim, or null. */
export function cleanSearchQuery(value) {
  if (typeof value !== 'string') return null;
  const q = cleanText(value);
  const len = charLength(q);
  return len >= 2 && len <= 32 ? q : null;
}

/** Escape LIKE wildcards for use with `ESCAPE '\'`. */
export const escapeLike = (s) => String(s).replace(/[\\%_]/g, (c) => `\\${c}`);
