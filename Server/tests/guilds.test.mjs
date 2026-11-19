import test from "node:test";
import assert from "node:assert/strict";
import {DatabaseSync} from "node:sqlite";
import {readFileSync} from "node:fs";
import {guildAction} from "../functions/_lib/guilds.mjs";

test("closed guild requires invitation and transfers ownership on account deletion", async () => {
  const sqlite = new DatabaseSync(":memory:");
  sqlite.exec("PRAGMA foreign_keys=ON; CREATE TABLE ef_accounts(id TEXT PRIMARY KEY, display_name TEXT); INSERT INTO ef_accounts VALUES ('a','Ada'),('b','Bea')");
  sqlite.exec(readFileSync(new URL("../migrations/0003_guilds.sql",import.meta.url),"utf8"));
  function prepare(sql,args=[]) {
    const stmt=sqlite.prepare(sql);
    return {bind:(...args)=>prepare(sql,args),first:()=>stmt.get(...args),all:()=>({results:stmt.all(...args)}),run:()=>({meta:stmt.run(...args)})};
  }
  const db={prepare,batch:statements=>{
    sqlite.exec("BEGIN");
    try { statements.forEach(stmt=>stmt.run()); sqlite.exec("COMMIT"); }
    catch(e) { sqlite.exec("ROLLBACK"); throw e; }
  }};
  await guildAction(db,"a","create",{name:"The Dragons"});
  const {guild} = await guildAction(db,"a","status",{});
  assert.equal(guild.members.length,1);
  assert.deepEqual((await guildAction(db,"b","status",{})).open,[]);
  await assert.rejects(guildAction(db,"b","join",{id:guild.id}));
  await guildAction(db,"b","join",{code:guild.invite_code.toLowerCase()});
  sqlite.exec("DELETE FROM ef_accounts WHERE id='a'");
  assert.equal((await guildAction(db,"b","status",{})).guild.role,"owner");
  await guildAction(db,"b","leave",{});
  assert.equal(sqlite.prepare("SELECT count(*) AS n FROM ef_guilds").get().n,0);
  sqlite.close();
});
