-- Auth v2: multi-identity linking + native sign-in handoff codes.
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- https://batesai.org · help@batesai.org
--
-- Idempotent: every statement is IF NOT EXISTS / INSERT OR IGNORE, so it is
-- safe to run any number of times (deploy.sh re-runs every migration on each
-- deploy). No ALTER TABLE: D1 has no ADD COLUMN IF NOT EXISTS, so new state
-- lives in new tables instead of new columns on `users`.
--
-- Apply BEFORE deploying the auth worker that references these tables:
--   npx wrangler d1 execute batesai-db --remote --file=App/Backend/migrations/2026-10-27-auth-v2.sql
-- (The worker degrades gracefully if they are missing: sign-in falls back to
-- the legacy users.oauth_* columns and account deletion skips absent tables.
-- Only POST /api/auth/handoff and the native Google/Apple browser flow need
-- auth_handoff_codes to exist.)
--
-- See Docs/API_V2.md §1 and Docs/AUTH_SETUP.md.

-- One row per provider identity (Apple, Google) attached to a membership.
-- Replaces the single users.oauth_provider/oauth_id slot, which could hold only
-- one provider and flip-flopped when a member used both. Those columns are kept
-- and still written when empty, so older code keeps working.
--
-- `verified` = the provider vouched for `email` (email_verified claim). An
-- account with at least one verified identity has proven ownership of its
-- address; the pre-hijack rule (API_V2 §1.2) keys off this.
CREATE TABLE IF NOT EXISTS user_identities (
  provider      TEXT    NOT NULL,                -- 'apple' | 'google'
  provider_sub  TEXT    NOT NULL,                -- the provider's stable subject id
  user_id       TEXT    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  email         TEXT,                            -- as the provider last reported it
  verified      INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL,
  last_used_at  INTEGER,
  PRIMARY KEY (provider, provider_sub)
);
CREATE INDEX IF NOT EXISTS idx_user_identities_user ON user_identities (user_id);

-- Backfill every legacy link. They are recorded as verified: Apple only issues
-- verified addresses, Google accounts are verified in practice, and a member
-- who already signs in both ways must not lose their password on the next
-- sign-in. Placeholder emails (<sub>@apple.local) are stored as NULL.
INSERT OR IGNORE INTO user_identities (provider, provider_sub, user_id, email, verified, created_at, last_used_at)
SELECT oauth_provider,
       oauth_id,
       id,
       CASE WHEN email LIKE '%@apple.local' OR email LIKE '%@google.local' THEN NULL ELSE email END,
       1,
       COALESCE(updated_at, created_at),
       NULL
  FROM users
 WHERE oauth_provider IS NOT NULL AND oauth_provider != ''
   AND oauth_id IS NOT NULL AND oauth_id != '';

-- One-time codes that hand a browser sign-in to the native app
-- (endgamefitness://auth?code=…). Only the SHA-256 of the code is stored; the
-- code lives 120 seconds and redeems once (used_at). Rows older than a day are
-- pruned whenever a new code is minted.
CREATE TABLE IF NOT EXISTS auth_handoff_codes (
  code_hash   TEXT    PRIMARY KEY,               -- SHA-256 hex of the code
  user_id     TEXT    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  scheme      TEXT    NOT NULL,                  -- allow-listed app scheme
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL,
  used_at     INTEGER
);
CREATE INDEX IF NOT EXISTS idx_auth_handoff_user ON auth_handoff_codes (user_id);
CREATE INDEX IF NOT EXISTS idx_auth_handoff_expires ON auth_handoff_codes (expires_at);
