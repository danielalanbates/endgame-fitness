ALTER TABLE ef_state ADD COLUMN write_id TEXT;
CREATE TABLE ef_raids (
 owner TEXT NOT NULL, week INTEGER NOT NULL, boss TEXT NOT NULL, hp INTEGER NOT NULL,
 damage INTEGER NOT NULL DEFAULT 0, defeated INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(owner,week)
);
CREATE TABLE ef_raid_hits (
 user_id TEXT NOT NULL REFERENCES ef_accounts(id) ON DELETE CASCADE,
 workout TEXT NOT NULL, owner TEXT NOT NULL, week INTEGER NOT NULL, damage INTEGER NOT NULL,
 PRIMARY KEY(user_id,workout), FOREIGN KEY(owner,week) REFERENCES ef_raids(owner,week)
);
CREATE INDEX ef_raid_contributors ON ef_raid_hits(owner,week,user_id);
CREATE TABLE ef_raid_rewards (
 user_id TEXT NOT NULL REFERENCES ef_accounts(id) ON DELETE CASCADE,
 owner TEXT NOT NULL, week INTEGER NOT NULL, boss TEXT NOT NULL, won INTEGER NOT NULL,
 PRIMARY KEY(user_id,owner,week)
);
CREATE TRIGGER ef_apply_raid_damage AFTER INSERT ON ef_raid_hits BEGIN
 UPDATE ef_raids SET damage=damage+NEW.damage WHERE owner=NEW.owner AND week=NEW.week;
 INSERT OR IGNORE INTO ef_raid_rewards(user_id,owner,week,boss,won)
 SELECT DISTINCT h.user_id,r.owner,r.week,r.boss,1 FROM ef_raids r
 JOIN ef_raid_hits h ON h.owner=r.owner AND h.week=r.week
 WHERE r.owner=NEW.owner AND r.week=NEW.week AND r.defeated=0 AND r.damage>=r.hp AND h.damage>0;
 UPDATE ef_raids SET defeated=1 WHERE owner=NEW.owner AND week=NEW.week AND damage>=hp;
 INSERT OR IGNORE INTO ef_raid_rewards(user_id,owner,week,boss,won)
 SELECT NEW.user_id,owner,week,boss,0 FROM ef_raids WHERE owner=NEW.owner AND week=NEW.week AND defeated=1 AND NEW.damage>0;
END;
