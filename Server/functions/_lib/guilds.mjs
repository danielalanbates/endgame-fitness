export async function guildAction(db, user, action, body) {
  const query = (sql,...args) => db.prepare(sql).bind(...args);
  const membership = await query("SELECT g.*,m.role FROM ef_guild_members m JOIN ef_guilds g ON g.id=m.guild_id WHERE m.user_id=?",user).first();
  if (action === "status") {
    if (membership) {
      const {results: members} = await query("SELECT a.display_name AS name,m.role FROM ef_guild_members m JOIN ef_accounts a ON a.id=m.user_id WHERE m.guild_id=? ORDER BY m.role DESC,a.display_name",membership.id).all();
      return {guild:{...membership,members}};
    }
    const {results: open} = await db.prepare("SELECT g.id,g.name,g.motto,g.emblem,count(*) AS members FROM ef_guilds g JOIN ef_guild_members m ON m.guild_id=g.id WHERE is_open=1 GROUP BY g.id HAVING count(*)<50 ORDER BY g.name LIMIT 100").all();
    return {guild:null,open};
  }
  if (action === "leave") {
    await query("DELETE FROM ef_guild_members WHERE user_id=?",user).run();
    return {ok:true};
  }
  if (membership) throw Error("Invalid action: leave your current guild first.");
  if (action === "create") {
    const name = String(body.name || "").trim();
    if (name.length < 3 || name.length > 32) throw Error("Invalid guild name: use 3–32 characters.");
    const id = crypto.randomUUID(), code = crypto.randomUUID().replaceAll("-","").slice(0,16).toUpperCase();
    await db.batch([
      query("INSERT INTO ef_guilds(id,name,motto,emblem,is_open,invite_code) VALUES(?,?,?,?,?,?)",id,name,String(body.motto || "").slice(0,160),String(body.emblem || "").slice(0,16),body.open === true ? 1 : 0,code),
      query("INSERT INTO ef_guild_members(user_id,guild_id,role) VALUES(?,?,'owner')",user,id)
    ]);
    return {ok:true};
  }
  if (action === "join") {
    const result = await query("INSERT OR IGNORE INTO ef_guild_members(user_id,guild_id,role) SELECT ?,g.id,'member' FROM ef_guilds g WHERE ((g.id=? AND g.is_open=1) OR g.invite_code=?) AND (SELECT count(*) FROM ef_guild_members WHERE guild_id=g.id)<50 LIMIT 1", user,String(body.id || ""),String(body.code || "").trim().toUpperCase()).run();
    if (!result.meta.changes) throw Error("Invalid invitation, full guild, or existing membership.");
    return {ok:true};
  }
  throw Error("Invalid guild action.");
}
