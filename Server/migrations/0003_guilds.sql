CREATE TABLE IF NOT EXISTS ef_guilds (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL CHECK(length(name) BETWEEN 3 AND 32),
  motto TEXT NOT NULL DEFAULT '',
  emblem TEXT NOT NULL DEFAULT '',
  is_open INTEGER NOT NULL CHECK(is_open IN (0,1)),
  invite_code TEXT UNIQUE NOT NULL
);
CREATE TABLE IF NOT EXISTS ef_guild_members (
  user_id TEXT PRIMARY KEY REFERENCES ef_accounts(id) ON DELETE CASCADE,
  guild_id TEXT NOT NULL REFERENCES ef_guilds(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK(role IN ('owner','member'))
);
CREATE INDEX IF NOT EXISTS ef_guild_roster ON ef_guild_members(guild_id,user_id);
CREATE TRIGGER IF NOT EXISTS ef_guild_after_leave AFTER DELETE ON ef_guild_members
BEGIN
  UPDATE ef_guild_members SET role='owner'
    WHERE OLD.role='owner' AND user_id=(SELECT min(user_id) FROM ef_guild_members WHERE guild_id=OLD.guild_id);
  DELETE FROM ef_guilds WHERE id=OLD.guild_id AND NOT EXISTS
    (SELECT 1 FROM ef_guild_members WHERE guild_id=OLD.guild_id);
END;
