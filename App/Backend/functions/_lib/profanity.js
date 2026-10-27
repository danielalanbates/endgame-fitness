/**
 * Basic blocked-term filter for player-visible text (display names, bios,
 * guild names, comments). Import-only (files under functions/_lib/ are not
 * routed). Pure: no DB, no clock.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * The list is deliberately short and stored as hashes, so no blocked word
 * appears in the source. It catches the common cases (leetspeak, stretched
 * letters, spaced-out letters, plurals); it is not a moderation system, which
 * is what reports (ugc_reports) are for.
 *
 * Maintaining it: compute `termKey('<lower-case word>')` in a scratch session
 * and add the key to the right set. Never commit the plain word.
 *   WHOLE     matches only as a whole word (short words that hide inside
 *             ordinary words)
 *   STEMMED   whole word, or the word plus a common suffix (s, ed, ing, ...)
 *   ANYWHERE  anywhere inside a word (distinctive terms used in compounds)
 */

function fnv1a(str, seed) {
  let h = seed >>> 0;
  for (let i = 0; i < str.length; i += 1) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

/** 64-bit key (two FNV-1a passes with different seeds) for one lower-case word. */
export function termKey(word) {
  const s = String(word);
  return fnv1a(s, 0x811c9dc5).toString(16).padStart(8, '0')
    + fnv1a(s, 0x050c5d1f).toString(16).padStart(8, '0');
}

const WHOLE = new Set([
  '3272efdac9b9bb68', '2376218e8e3af524', '1414e96a082af524', '7df6521ecb6954f4',
]);
const STEMMED = new Set([
  'a856eb33a01d4b59', '81602170da50bc7a', 'b99bf986492fa5d8', '6cd5e87bebb1eef9',
  '021aeb2069cd6cea', 'a49a9c692ddab427', 'fd6086e96b9faf3b', '948002a15560f463',
  'dc08ae090a2ab2cb', 'f6a4b84e6c5ef0e0', '36c9c3b051bbddc6', '883eef4177e793b7',
]);
const ANYWHERE = new Set([
  'e6774d4a694fce60', '91b887d3e261db89', '7c9ae63f8ba4f909', '92a4ff90df945492',
  'e8e7a15acd031524', 'a47055598fe91863', 'd9eb56dd6bf015cf', '955b3ec5cfaaddff',
  '91e435487391dfa6', '8519f92b0888b0c5', '9984cfa871b25906',
]);
// Lengths present in ANYWHERE, so the substring scan only hashes useful windows.
const ANYWHERE_LENGTHS = [4, 5, 6, 7, 12];
const SUFFIXES = ['s', 'es', 'ed', 'er', 'ers', 'ing', 'in', 'z', 'y', 'ty'];

const LEET = { 0: 'o', 1: 'i', 3: 'e', 4: 'a', 5: 's', 7: 't', '@': 'a', $: 's' };

/** Lower-case, strip accents, undo common leetspeak. */
export function normalizeForFilter(text) {
  return String(text || '')
    .normalize('NFKD')
    .replace(/\p{M}+/gu, '')
    .toLowerCase()
    .replace(/[013457@$]/g, (c) => LEET[c] || c);
}

/** "heeelloo" -> "helo": catches stretched letters. */
const collapseRuns = (word) => word.replace(/([a-z])\1+/g, '$1');

function wordIsBlocked(word) {
  if (!word) return false;
  for (const w of new Set([word, collapseRuns(word)])) {
    const k = termKey(w);
    if (WHOLE.has(k) || STEMMED.has(k) || ANYWHERE.has(k)) return true;
    for (const suffix of SUFFIXES) {
      if (w.length > suffix.length + 2 && w.endsWith(suffix) && STEMMED.has(termKey(w.slice(0, -suffix.length)))) {
        return true;
      }
    }
    for (const len of ANYWHERE_LENGTHS) {
      for (let i = 0; i + len <= w.length; i += 1) {
        if (ANYWHERE.has(termKey(w.slice(i, i + len)))) return true;
      }
    }
  }
  return false;
}

/**
 * True when `text` contains a blocked term. Words are runs of letters after
 * normalisation; three or more single letters in a row ("x y z") are also
 * joined and checked, so spacing a word out does not slip past.
 */
export function containsBlockedTerm(text) {
  const words = normalizeForFilter(text).split(/[^a-z]+/).filter(Boolean);
  let singles = '';
  for (const word of words) {
    if (wordIsBlocked(word)) return true;
    if (word.length === 1) {
      singles += word;
    } else {
      if (singles.length >= 3 && wordIsBlocked(singles)) return true;
      singles = '';
    }
  }
  return singles.length >= 3 && wordIsBlocked(singles);
}
