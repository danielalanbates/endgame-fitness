import { BOSS_CATALOG, bossForWeek, hpForGuild, weekStart, raidDamage } from "./raid-rules.mjs";
import { completedSets } from "./endgame-engine.mjs";

// Derive current-week contributions from the work log. Older workouts establish PR baselines.
export function workoutHits(player, epoch) {
  const records = new Map(), hits = [];
  const factor = player.unit === "kg" ? 2.20462 : 1;
  for (const s of [...player.sessions].sort((a,b) => a.finished-b.finished)) {
    const sets = completedSets(s);
    const volume = sets.reduce((total,t) => total+t.weight*factor*t.reps,0);
    if (s.finished > (epoch+600)*1000 || s.finished < s.started || s.finished-s.started>21600000 ||
        volume>250000 || sets.reduce((sum,t)=>sum+t.reps,0)>5000 ||
        sets.some(t=>t.reps>100 || t.weight*factor>1500)) continue;
    const best = new Map();
    for (const t of sets) {
      if (!t.weight) continue;
      const key=t.exercise, row=best.get(key) || new Map();
      row.set(t.reps,Math.max(row.get(t.reps)||0,t.weight*factor)); best.set(key,row);
    }
    let prs=0;
    for (const [exercise,row] of best) {
      const history=records.get(exercise) || new Map();
      const previousMax=Math.max(0,...Array.from(history,([r,w])=>Math.round(w*(1+r/30))));
      for (const [r,w] of row) {
        if (previousMax && (history.has(r) ? w>history.get(r) : Math.round(w*(1+r/30))>previousMax)) prs++;
        history.set(r,Math.max(history.get(r)||0,w));
      }
      records.set(exercise,history);
    }
    if (weekStart(s.finished/1000)===weekStart(epoch))
      hits.push({id:s.id,damage:raidDamage({total_volume:volume,pr_count:prs})});
  }
  return hits;
}
const ownerSQL = "coalesce((SELECT guild_id FROM ef_guild_members WHERE user_id=?),'solo:'||?)";

export function raidWrites(db, user, writeId, player, epoch) {
  const hits=workoutHits(player,epoch);
  if (!hits.length) return [];
  const week=weekStart(epoch), boss=bossForWeek(epoch);
  const guard="EXISTS(SELECT 1 FROM ef_state WHERE user_id=? AND write_id=?)";
  return [
    db.prepare(`INSERT OR IGNORE INTO ef_raids(owner,week,boss,hp)
      SELECT ${ownerSQL},?,?,?*max(1,(SELECT count(*) FROM ef_guild_members WHERE guild_id=(SELECT guild_id FROM ef_guild_members WHERE user_id=?)))
      WHERE ${guard}`).bind(user,user,week,boss.id,boss.base_hp,user,user,writeId),
    db.prepare(`INSERT OR IGNORE INTO ef_raid_hits(user_id,workout,owner,week,damage)
      SELECT ?,json_extract(value,'$.id'),${ownerSQL},?,json_extract(value,'$.damage') FROM json_each(?) WHERE ${guard}`)
      .bind(user,user,user,week,JSON.stringify(hits),user,writeId)
  ];
}
export async function raidStatus(db,user,epoch) {
  const week=weekStart(epoch),boss=bossForWeek(epoch);
  const guild=await db.prepare("SELECT guild_id,(SELECT count(*) FROM ef_guild_members g WHERE g.guild_id=m.guild_id) AS members FROM ef_guild_members m WHERE user_id=?").bind(user).first();
  const owner=guild?.guild_id || "solo:"+user;
  const raid=await db.prepare("SELECT hp,damage,defeated FROM ef_raids WHERE owner=? AND week=?").bind(owner,week).first();
  const rewards=await raidRewards(db,user);
  return {boss:boss.name,group:guild?"Guild":"Solo",hp:raid?.hp??hpForGuild(boss,guild?.members||1),damage:raid?.damage||0,
    rewards};
}
export async function raidRewards(db,user) {
  const {results} = await db.prepare("SELECT owner,week,boss,won FROM ef_raid_rewards WHERE user_id=? ORDER BY week DESC").bind(user).all();
  return results.map(r=>{
    const boss=BOSS_CATALOG.find(b=>b.id===r.boss);
    return {id:r.owner+"|"+r.week,week:r.week,title:boss.reward_title,aura:boss.reward_cosmetic,xp:r.won?boss.reward_xp:0};
  });
}
