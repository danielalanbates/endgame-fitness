import test from "node:test";
import assert from "node:assert/strict";
import * as E from "../engine.mjs";
import {seasonDefinition} from "../seasons.mjs";

test("season claims survive save, cannot be repeated and reset for the next season", () => {
  const p = E.newPlayer("Lifter");
  const season = seasonDefinition(1);
  const now = (season.starts_at + 3600) * 1000;
  const session = E.startWorkout(p);
  session.exercises[0].sets[0].done = true;
  E.finishWorkout(p);
  p.sessions[0].finished = now;
  p.sessions[0].earnedXP = 300;
  E.claimTier(p, 1, now);
  const restored = E.validateState(JSON.parse(JSON.stringify({version:1,selected:p.id,players:[p],rivals:[]}))).players[0];
  assert.equal(restored.freezes,1);
  assert.throws(() => E.claimTier(restored,1,now));
  assert.equal(E.seasonProgress(restored,season.ends_at * 1000).total,0);
  assert.throws(() => E.spendTalent(restored,"second_wind"));
  E.spendTalent(restored,"momentum");
  assert.equal(restored.ranks.momentum,1);
});

test("a shield covers the first missed day and a banked freeze covers the next", () => {
  const p = E.newPlayer("Lifter");
  const previous = new Date();
  previous.setDate(previous.getDate() - 3);
  p.streak = {current: 5, longest: 5, lastDate: E.dayKey(previous)};
  p.freezes = 1;
  p.ranks = {streak_shield: 1};
  E.startWorkout(p).exercises[0].sets[0].done = true;
  E.finishWorkout(p);
  assert.equal(p.streak.current, 6);
  assert.equal(p.freezes, 0);
  E.startWorkout(p).exercises[0].sets[0].done = true;
  E.finishWorkout(p);
  assert.equal(p.streak.current, 6);
});

test("newly achieved seven-day streak applies Second Wind to this workout", () => {
  const p = E.newPlayer("Lifter");
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate()-1);
  p.streak = {current:6,longest:6,lastDate:E.dayKey(yesterday)};
  p.ranks = {second_wind:3};
  E.startWorkout(p).exercises[0].sets[0].done = true;
  const workout = E.finishWorkout(p);
  assert.equal(workout.earnedXP, 11);
  assert.equal(p.streak.current, 7);
  assert.equal(p.freezes, 1);
});

test("Rally caps friend bonuses at five and Guild Banner requires an active membership", () => {
  const finish = community => {
    const p = E.newPlayer("Lifter");
    p.ranks = {rally:5,guild_banner:3};
    p.community = community;
    const set = E.startWorkout(p).exercises[0].sets[0];
    Object.assign(set,{weight:50,reps:10,done:true});
    return E.finishWorkout(p).earnedXP;
  };
  const base = finish({friends:0,inGuild:false});
  assert.equal(finish({friends:9,inGuild:true}),Math.round(base*1.34));
  assert.equal(finish({friends:1,inGuild:false}),Math.round(base*1.05));
});
