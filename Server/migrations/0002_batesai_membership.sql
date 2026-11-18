-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- Map BatesAI Membership users to stable Endgame profiles. The legacy
-- facebook_id column remains an internal required key in the initial schema;
-- new rows use a synthetic batesai:<membership-user-id> value and never store
-- a Facebook identifier.
CREATE TABLE IF NOT EXISTS ef_membership_links (
  membership_user_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL UNIQUE REFERENCES ef_accounts(id) ON DELETE CASCADE
);
