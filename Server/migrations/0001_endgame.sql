-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Isolated tables: existing BatesAI membership and training data are untouched.
CREATE TABLE IF NOT EXISTS ef_accounts (
 id TEXT PRIMARY KEY, facebook_id TEXT NOT NULL UNIQUE, display_name TEXT NOT NULL,
 friend_code TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS ef_sessions (
 token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES ef_accounts(id) ON DELETE CASCADE,
 expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS ef_oauth_states (
 state_hash TEXT PRIMARY KEY, native INTEGER NOT NULL DEFAULT 0, challenge TEXT,
 expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS ef_native_codes (
 code_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES ef_accounts(id) ON DELETE CASCADE,
 challenge TEXT NOT NULL, expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS ef_state (
 user_id TEXT PRIMARY KEY REFERENCES ef_accounts(id) ON DELETE CASCADE,
 data TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1, updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS ef_friendships (
 requester TEXT NOT NULL REFERENCES ef_accounts(id) ON DELETE CASCADE,
 recipient TEXT NOT NULL REFERENCES ef_accounts(id) ON DELETE CASCADE,
 accepted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL,
 PRIMARY KEY(requester, recipient), CHECK(requester <> recipient)
);
CREATE INDEX IF NOT EXISTS ef_session_expiry ON ef_sessions(expires_at);
CREATE INDEX IF NOT EXISTS ef_friend_recipient ON ef_friendships(recipient);
