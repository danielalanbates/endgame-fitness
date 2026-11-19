// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
import test from "node:test";
import assert from "node:assert/strict";
import * as E from "../engine.mjs";
const p = () => E.newPlayer("Test Adventurer");
const session = (id = "bench", weight = 40, reps = 12, rir = 2) => ({
  id: crypto.randomUUID(),
  name: "Test",
  started: Date.now() - 60000,
  finished: Date.now(),
  day: E.dayKey(),
  exercises: [
    {
      id,
      sets: [
        { weight, reps, rir, done: true },
        { weight, reps, rir, done: true },
      ],
    },
  ],
});
test("fresh profile has no invented history or XP", () => {
  const v = E.stats(p());
  assert.equal(v.sessions, 0);
  assert.equal(v.xp, 0);
  assert.equal(v.level, 1);
});
test("name and preferences validated", () => {
  for (const name of ["", " ".repeat(4), "a".repeat(41)])
    assert.throws(() => E.newPlayer(name));
  assert.throws(() => E.newPlayer("a", "invalid"));
  assert.throws(() => E.newPlayer("a", "muscle", "gym", 7));
  assert.throws(() => E.newPlayer("a", "muscle", "gym", 3, 100));
});
test("equipment and time respected over complete plan matrix", () => {
  for (const equipment of ["gym", "bodyweight", "dumbbells"])
    for (const days of [2, 3, 4, 5, 6])
      for (const minutes of [20, 30, 45, 60])
        for (const goal of ["strength", "muscle", "balanced"]) {
          const v = E.newPlayer("A", goal, equipment, days, minutes),
            plan = E.makePlan(v);
          assert.equal(plan.sessions.length, days);
          for (const s of plan.sessions)
            for (const e of s.exercises) {
              assert.ok(E.byId(e.id));
              assert.ok(
                [equipment, "bodyweight"].includes(E.byId(e.id).equipment),
              );
              assert.equal(e.sets, minutes <= 30 ? 2 : 3);
              assert.ok(e.low < e.high);
            }
        }
});
test("active session resumes without duplicates", () => {
  const v = p(),
    a = E.startWorkout(v);
  assert.equal(E.startWorkout(v).id, a.id);
  assert.equal(v.sessions.length, 0);
});
test("empty sessions cannot earn XP", () => {
  const v = p();
  E.startWorkout(v);
  assert.throws(() => E.finishWorkout(v));
  assert.equal(v.sessions.length, 0);
});
test("finish only awards completed sets and clears active", () => {
  const v = p();
  E.startWorkout(v);
  v.active.exercises[0].sets[0].done = true;
  E.finishWorkout(v);
  assert.equal(v.active, null);
  assert.equal(E.stats(v).sets, 1);
  assert.equal(E.xp(v), 10);
  assert.throws(() => E.finishWorkout(v));
});
test("one successful session increases the upper-body load", () => {
  const v = p();
  v.sessions = [session()];
  assert.equal(E.nextLoad(v, "bench", 8, 12).weight, 42.5);
});
test("repeated equal sessions give the same next load", () => {
  const v = p();
  v.sessions = [session(), session()];
  assert.equal(E.nextLoad(v, "bench", 8, 12).weight, 42.5);
});
test("metric upper-body step is 2.5 kg", () => {
  const v = p();
  v.sessions = [session("bench", 5), session("bench", 5)];
  assert.equal(E.nextLoad(v, "bench", 8, 12).weight, 7.5);
});
test("missed reps keep load and target the next rep", () => {
  const v = p();
  v.sessions = [session("bench", 40, 4, 0)];
  assert.equal(E.nextLoad(v, "bench", 8, 12).weight, 40);
  assert.equal(E.nextLoad(v, "bench", 8, 12).reps, 5);
});
test("bodyweight stays zero external load", () => {
  const v = p();
  v.sessions = [session("pushup", 0), session("pushup", 0)];
  assert.equal(E.nextLoad(v, "pushup", 8, 12).weight, 0);
});
test("low readiness reduces volume and load", () => {
  const v = p();
  v.sessions = [session("squat", 40)];
  const a = E.startWorkout(v, 1);
  assert.equal(a.deload, true);
  assert.equal(a.exercises[0].sets.length, 2);
  assert.equal(a.exercises[0].sets[0].weight, 36);
});
test("session rotation advances after completion only", () => {
  const v = p(),
    a = E.startWorkout(v);
  assert.match(a.name, /A$/);
  a.exercises[0].sets[0].done = true;
  E.finishWorkout(v);
  assert.match(E.startWorkout(v).name, /B$/);
});
test("quest claim is earned once", () => {
  const v = p();
  assert.throws(() => E.claim(v, E.quests(v)[0].id));
  v.sessions = [session()];
  const q = E.quests(v)[0];
  E.claim(v, q.id);
  assert.throws(() => E.claim(v, q.id));
  assert.equal(E.xp(v), 145);
});
test("multiple same-day sessions do not inflate training days", () => {
  const v = p();
  v.sessions = [session(), session()];
  assert.equal(E.stats(v).days, 1);
  assert.equal(E.quests(v)[1].current, 1);
});
test("Unicode snapshot round trips and malformed cards reject", () => {
  const v = E.newPlayer("🏋🏽 Zoë");
  assert.equal(E.decodeCard(E.encodeCard(v)).name, v.name);
  assert.throws(() => E.decodeCard("bad"));
  assert.throws(() => E.decodeCard("EGFW1.???"));
});
test("state validation preserves plan rotation and active session", () => {
  const v = p();
  v.plan = E.makePlan(v);
  const id = v.plan.id;
  E.startWorkout(v);
  const s = { version: 1, selected: v.id, players: [v], rivals: [] };
  const restored = E.validateState(JSON.parse(JSON.stringify(s)));
  assert.equal(restored.players[0].plan.id, id);
  assert.equal(restored.players[0].active.id, v.active.id);
});
test("backup rejects negative weights, duplicates and unknown exercises", () => {
  for (const mode of ["weight", "duplicate", "exercise"]) {
    const v = p();
    v.sessions = [session()];
    if (mode === "weight") v.sessions[0].exercises[0].sets[0].weight = -10;
    if (mode === "duplicate") v.sessions.push(v.sessions[0]);
    if (mode === "exercise") v.sessions[0].exercises[0].id = "<script>";
    assert.throws(() =>
      E.validateState({ version: 1, selected: v.id, players: [v], rivals: [] }),
    );
  }
});
test("storage errors propagate so caller can protect data", () => {
  assert.throws(() => E.load({ getItem: () => "{" }));
  assert.throws(() =>
    E.save(
      {
        setItem: () => {
          throw Error("quota");
        },
      },
      E.fresh(),
    ),
  );
});
test("level boundaries are monotone", () => {
  assert.equal(E.level(-1), 1);
  assert.equal(E.level(99), 1);
  assert.equal(E.level(115), 1);
  assert.equal(E.level(116), 2);
});
