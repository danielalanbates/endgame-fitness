import {seasonAt, tierForXp, rewardFor} from "./seasons.mjs";
import {applySessionDay, effectiveStreak} from "./streaks.mjs";
import {streakShieldDays,nodeById, validateSpend, pointsSpent, applyTalentEffects, bonusTalentPoints} from "./talents.mjs";
// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// batesai.org · help@batesai.org · See ../../LICENSE.
import { catalog } from "./native-programs.mjs";
export const VERSION = 1;
export const key = "endgamefitness.local.v1";
export const exercises = [
  [
    "squat",
    "Goblet squat",
    "squat",
    "dumbbells",
    "legs",
    "Hold one dumbbell at your chest. Sit between your hips, keep heels planted, then stand. Use a comfortable depth.",
  ],
  [
    "bsquat",
    "Back squat",
    "squat",
    "gym",
    "legs",
    "Set safety bars. Brace, keep the bar over midfoot, descend under control, then stand.",
  ],
  [
    "split",
    "Split squat",
    "squat",
    "bodyweight",
    "legs",
    "Take a staggered stance. Lower straight down, keep the front foot planted, then push through it to stand.",
  ],
  [
    "rdl",
    "Dumbbell Romanian deadlift",
    "hinge",
    "dumbbells",
    "posterior",
    "With soft knees, push hips back and keep the weights close. Stop before your back rounds; stand by driving hips forward.",
  ],
  [
    "deadlift",
    "Romanian deadlift",
    "hinge",
    "gym",
    "posterior",
    "Brace, hinge at the hips with a slight knee bend, keep the bar close, then stand. Lower only while your back stays controlled.",
  ],
  [
    "bridge",
    "Glute bridge",
    "hinge",
    "bodyweight",
    "posterior",
    "Lie on your back, knees bent. Press through heels, lift hips without arching your lower back, pause and lower.",
  ],
  [
    "bench",
    "Bench press",
    "push",
    "gym",
    "chest",
    "Use a spotter or safeties. Plant feet, control the bar to your chest, then press. Keep shoulders stable.",
  ],
  [
    "dbpress",
    "Dumbbell floor press",
    "push",
    "dumbbells",
    "chest",
    "Lie on the floor with bent knees. Lower until upper arms gently touch down, then press up.",
  ],
  [
    "pushup",
    "Push-up",
    "push",
    "bodyweight",
    "chest",
    "Keep a straight line from head to heels. Lower your chest under control, then press. Raise hands onto a stable surface to make it easier.",
  ],
  [
    "row",
    "Seated cable row",
    "pull",
    "gym",
    "back",
    "Sit tall, brace, and pull toward your lower ribs. Keep shoulders down and avoid leaning back to finish.",
  ],
  [
    "dbrow",
    "One-arm dumbbell row",
    "pull",
    "dumbbells",
    "back",
    "Support yourself on a stable bench, brace, pull elbow toward hip, then lower slowly. Complete both sides; enter reps per side.",
  ],
  [
    "prone",
    "Prone W raise",
    "pull",
    "bodyweight",
    "back",
    "Lie face down, arms in a W. Gently lift elbows and hands, squeeze upper back, and lower. Limited loading: add bands or weights when available.",
  ],
  [
    "ohp",
    "Dumbbell shoulder press",
    "vertical",
    "dumbbells",
    "shoulders",
    "Brace, start weights near shoulders, press overhead without arching your back, then lower.",
  ],
  [
    "machinepress",
    "Machine shoulder press",
    "vertical",
    "gym",
    "shoulders",
    "Adjust the seat so handles start near shoulder height. Press within a comfortable range; lower with control.",
  ],
  [
    "pike",
    "Incline push-up",
    "vertical",
    "bodyweight",
    "shoulders",
    "Place hands on a stable elevated surface, keep your body straight, lower under control and press away.",
  ],
  [
    "calf",
    "Standing calf raise",
    "calf",
    "bodyweight",
    "calves",
    "Use stable support for balance. Rise onto the balls of your feet, pause, then lower slowly.",
  ],
  [
    "deadbug",
    "Dead bug",
    "core",
    "bodyweight",
    "core",
    "Lie on your back, brace gently, extend opposite arm and leg without arching your back. Alternate sides; enter total reps.",
  ],
].map(([id, name, pattern, equipment, muscle, guide]) => ({
  id,
  name,
  pattern,
  equipment,
  muscle,
  guide,
}));
const movements = new Map(exercises.map(e => [e.id, e]));
for (const program of catalog) {
  for (const session of program.sessions) {
    for (const name of session.exercises) {
      const id = "catalog:" + name;
      movements.set(id, { id, name, pattern: "", muscle: "", equipment: "", guide: "" });
    }
  }
}
export const byId = id => movements.get(id);
export const availableMovements = [...movements.values()];
export const dayKey = (d = new Date()) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
export function fresh() {
  return { version: VERSION, selected: null, players: [], rivals: [] };
}
export function newPlayer(
  name,
  goal = "balanced",
  equipment = "dumbbells",
  days = 3,
  minutes = 45,
) {
  if (!name.trim() || name.trim().length > 40)
    throw Error("Use a player name between 1 and 40 characters.");
  if (
    !["balanced", "strength", "muscle"].includes(goal) ||
    !["gym", "dumbbells", "bodyweight"].includes(equipment) ||
    !Number.isInteger(days) ||
    days < 2 ||
    days > 6 ||
    ![20, 30, 45, 60].includes(minutes)
  )
    throw Error("Choose valid training preferences.");
  return {
    id: crypto.randomUUID(),
    name: name.trim(),
    goal,
    equipment,
    days,
    minutes,
    unit: "kg",
    created: Date.now(),
    sessions: [],
    active: null,
    plan: null,
    claimed: [],
    recovery: 3,
  };
}
export function xpForLevel(level) {
  const n = Math.max(0, level - 1);
  return Math.round(100*n + 15*n*n + 0.9*n*n*n);
}
export function level(xp) {
  let rank = 1;
  while (rank < 200 && xp >= xpForLevel(rank + 1)) rank++;
  return rank;
}
export const completedSets = (s) =>
  s.exercises.flatMap((e) =>
    e.sets
      .filter((t) => t.done && t.reps > 0)
      .map((t) => ({ ...t, exercise: e.id })),
  );
const baseSessionXP = (s) =>
  completedSets(s).length
    ? Math.min(350, completedSets(s).length * 10 + 50)
    : 0;
export const sessionXP = s => Number.isSafeInteger(s.earnedXP) && s.earnedXP >= 0 ? s.earnedXP : baseSessionXP(s);
export const xp = (p) =>
  p.sessions.reduce((n, s) => n + sessionXP(s), 0) +
  (p.claimed || []).length * 75 + (p.raidRewards || []).reduce((sum,r) => sum+r.xp,0);
export function stats(p) {
  const sets = p.sessions.flatMap(completedSets);
  return {
    xp: xp(p),
    level: level(xp(p)),
    sessions: p.sessions.length,
    sets: sets.length,
    volume: sets.reduce((n, s) => n + s.weight * s.reps, 0),
    days: new Set(p.sessions.map((s) => s.day)).size,
  };
}
export function weeklySessions(p, now = new Date()) {
  const monday = new Date(now);
  monday.setHours(0, 0, 0, 0);
  monday.setDate(monday.getDate() - ((monday.getDay() + 6) % 7));
  return p.sessions.filter(
    (s) => s.finished >= monday.getTime() && s.finished <= now.getTime(),
  );
}
export function quests(p) {
  const week = weeklySessions(p),
    weekKey = (() => {
      let d = new Date();
      d.setDate(d.getDate() - ((d.getDay() + 6) % 7));
      return dayKey(d);
    })();
  return [
    {
      id: `${dayKey()}:train`,
      title: "Show up for yourself",
      detail: "Finish a workout today",
      current: p.sessions.some((s) => s.day === dayKey()) ? 1 : 0,
      target: 1,
    },
    {
      id: `${weekKey}:consistency`,
      title: "Build your rhythm",
      detail: `Train on ${Math.min(p.days, 3)} different days this week`,
      current: new Set(week.map((s) => s.day)).size,
      target: Math.min(p.days, 3),
    },
    {
      id: `${weekKey}:sets`,
      title: "Quality over chaos",
      detail: "Complete 20 working sets this week",
      current: week.reduce((n, s) => n + completedSets(s).length, 0),
      target: 20,
    },
  ].map((q) => ({ ...q, claimed: p.claimed.includes(q.id) }));
}
export function claim(p, id) {
  const q = quests(p).find((q) => q.id === id);
  if (!q || q.claimed || q.current < q.target)
    throw Error("This quest is not ready to claim.");
  const before = level(xp(p));
  p.claimed.push(id);
  (p.questTimes ||= {})[id] = Date.now();
  p.bonusPoints = (p.bonusPoints || 0) + bonusTalentPoints(p.ranks || {}, before, level(xp(p)));
}
export function seasonProgress(p, now = Date.now()) {
  const season = seasonAt(now / 1000);
  const inSeason = ms => ms >= season.starts_at * 1000 && ms < season.ends_at * 1000;
  const workouts = p.sessions.filter(s => inSeason(s.finished)).reduce((n,s) => n + sessionXP(s), 0);
  const questXP = Object.values(p.questTimes || {}).filter(inSeason).length * 75;
  const total = workouts + questXP + (p.raidRewards || []).filter(r=>inSeason(r.week*1000)).reduce((sum,r)=>sum+r.xp,0);
  return {season, total, tier: tierForXp(total), claims: p.seasonClaims?.[season.id] || []};
}
export function claimTier(p, tier, now = Date.now()) {
  const {season, tier: reached, claims} = seasonProgress(p, now);
  if (!season.active || !Number.isInteger(tier) || tier < 1 || tier > reached || claims.includes(tier))
    throw Error("This tier is unavailable.");
  const reward = rewardFor(season.number, tier);
  if (reward.type === "streak_freeze" && (p.freezes || 0) >= 3) throw Error("Your three streak freezes are full.");
  if (reward.type === "streak_freeze") p.freezes = (p.freezes || 0) + 1;
  if (reward.type === "talent_point") p.rewardPoints = (p.rewardPoints || 0) + 1;
  if (reward.type === "title" || reward.type === "cosmetic") {
    const key = reward.type === "title" ? "titles" : "auras";
    p[key] = [...new Set([...(p[key] || []), reward.value])];
  }
  (p.seasonClaims ||= {})[season.id] = [...claims, tier];
  return reward.label;
}
export function unspentPoints(p) {
  return level(xp(p)) - 1 + (p.rewardPoints || 0) + (p.bonusPoints || 0) - pointsSpent(p.ranks || {});
}
export function spendTalent(p, id) {
  const ranks = p.ranks || {};
  const result = validateSpend(ranks, unspentPoints(p), id);
  if (!result.ok) throw Error(result.error);
  p.ranks = {...ranks, [id]: (ranks[id] || 0) + 1};
}
export function nextLoad(p, id, low, high) {
  const last = p.sessions.filter(session => session.exercises.some(exercise =>
    exercise.id === id && exercise.sets.some(set => set.done && set.reps > 0)))
    .reduce((latest, session) => !latest || session.finished >= latest.finished ? session : latest, null);
  if (!last) return {weight: 0, reps: low, reason: "Choose a comfortable starting load."};
  const sets = last.exercises.filter(exercise => exercise.id === id)
    .flatMap(exercise => exercise.sets.filter(set => set.done && set.reps > 0));
  const weight = Math.max(...sets.map(set => set.weight));
  const working = sets.filter(set => Math.abs(set.weight - weight) < 0.01);
  const bestReps = Math.max(...working.map(set => set.reps));
  if (working.every(set => set.reps >= high && (set.rir ?? 1) >= 1)) {
    if (!weight) return {weight, reps: high, reason: "You reached the top of your bodyweight rep range."};
    const exercise = byId(id);
    const lower = ["squat","hinge","calf"].includes(exercise?.pattern) ||
      /squat|deadlift|lunge|leg |calf|step-up|glute|nordic/i.test(exercise?.name || "");
    const step = (p.unit === "kg" ? 2.5 : 5) * (lower ? 2 : 1);
    return {previousWeight: weight, weight: weight + step, reps: low, reason: "Your top working sets reached the upper rep target with reserve."};
  }
  return {weight, reps: Math.min(high, bestReps + 1), reason: "Keep the load and build repetitions."};
}
const safeLabel = s => typeof s === "string" && /^[^<>"\x27\x00-\x1f]{1,80}$/u.test(s);
export function makePlan(p) {
  if (p.schedule) {
    const { name, sessions } = p.schedule;
    if (!safeLabel(name) || !Array.isArray(sessions) || !sessions.length || sessions.length > 32)
      throw Error("Invalid program.");
    for (const session of sessions) {
      if (!safeLabel(session.name) || !Array.isArray(session.exercises) ||
          !session.exercises.length || session.exercises.length > 40)
        throw Error("Invalid program day.");
      for (const e of session.exercises) {
        if (!byId(e.id) || ![e.sets,e.low,e.high,e.rest].every(Number.isInteger) ||
            e.sets < 1 || e.sets > 15 || e.low < 1 || e.high < e.low || e.high > 100 ||
            e.rest < 0 || e.rest > 900) throw Error("Invalid program exercise.");
      }
    }
    return { id: crypto.randomUUID(), created: Date.now(), split: name, sessions,
      explanation: name + " · " + sessions.length + " scheduled workouts" };
  }
  const split = p.days >= 4 ? "Upper / lower" : "Full body";
  const patterns =
    p.days >= 4
      ? [
          ["push", "pull", "vertical", "core"],
          ["squat", "hinge", "calf", "core"],
        ]
      : [
          ["squat", "push", "pull", "hinge", "core"],
          ["hinge", "vertical", "pull", "squat", "core"],
        ];
  const sets = p.minutes <= 30 ? 2 : 3,
    low = p.goal === "strength" ? 5 : 8,
    high = p.goal === "strength" ? 8 : 12;
  const sessions = Array.from({ length: p.days }, (_, i) => {
    const patternsToday = patterns[i % 2].slice(0, p.minutes === 20 ? 3 : 5);
    return {
      name: `${split === "Full body" ? "Full body" : i % 2 ? "Lower body" : "Upper body"} ${String.fromCharCode(65 + i)}`,
      exercises: patternsToday.map((pattern) => {
        const e =
          exercises.find(
            (e) => e.pattern === pattern && e.equipment === p.equipment,
          ) ||
          exercises.find(
            (e) => e.pattern === pattern && e.equipment === "bodyweight",
          );
        return {
          id: e.id,
          sets,
          low,
          high,
          rest: pattern === "core" ? 60 : p.goal === "strength" ? 150 : 90,
        };
      }),
    };
  });
  return {
    id: crypto.randomUUID(),
    created: Date.now(),
    split,
    sessions,
    explanation: `${p.days} sessions, ${p.minutes} minutes each. ${sets} working sets per exercise, ${low}–${high} reps. Leave 2–3 repetitions in reserve. Allow recovery between demanding sessions. The schedule rotates when you complete a session, so missed days never force catch-up workouts.`,
  };
}
export function startWorkout(p, recovery = 3) {
  if (p.active) return p.active;
  if (!p.plan) p.plan = makePlan(p);
  const slot =
    p.plan.sessions[
      p.sessions.filter((s) => s.planId === p.plan.id).length %
        p.plan.sessions.length
    ];
  const deload =
    recovery <= 2 ||
    (Math.floor(
      p.sessions.filter((s) => s.planId === p.plan.id).length / p.days,
    ) +
      1) %
      5 ===
      0;
  p.active = {
    id: crypto.randomUUID(),
    name: slot.name,
    started: Date.now(),
    planId: p.plan.id,
    deload,
    exercises: slot.exercises.map((e) => {
      const suggested = nextLoad(p, e.id, e.low, e.high);
      return {
        ...e,
        reason: deload
          ? "Recovery session: fewer sets and a lighter load."
          : suggested.reason,
        sets: Array.from(
          { length: deload ? Math.max(1, Math.ceil(e.sets / 2)) : e.sets },
          () => ({
            weight: deload
              ? Math.round((suggested.previousWeight ?? suggested.weight) * 0.9 * 2) / 2
              : suggested.weight,
            reps: deload ? e.low : suggested.reps,
            rir: deload ? 4 : 3,
            done: false,
          }),
        ),
      };
    }),
  };
  return p.active;
}
function storedStreak(p) {
  if (p.streak) return {...p.streak, freezes: p.freezes || 0};
  let state = {};
  for (const day of [...new Set(p.sessions.filter(s => !s.flagged).map(s => s.day))].sort()) {
    state = applySessionDay(state, day);
  }
  return {...state, freezes: Math.min(3, (state.freezes || 0) + (p.freezes || 0))};
}
export function trainingStreak(p, today = dayKey()) {
  const state = storedStreak(p);
  return {...effectiveStreak(state, today, streakShieldDays(p.ranks || {})), longest: state.longest || 0};
}
export function finishWorkout(p) {
  if (!p.active || completedSets(p.active).length === 0)
    throw Error("Complete at least one set before finishing.");
  const done = { ...p.active, finished: Date.now(), day: dayKey() };
  const before = level(xp(p));
  const volume = completedSets(done).reduce((n,t) => n + t.weight * t.reps, 0) * (p.unit === "kg" ? 2.20462 : 1);
  const sets = completedSets(done);
  const reps = sets.reduce((sum, set) => sum + set.reps, 0);
  const duration = Math.max(0, (done.finished - done.started) / 1000);
  const pounds = p.unit === "kg" ? 2.20462 : 1;
  const flagged = volume > 250000 || reps > 5000 || duration > 21600 ||
    sets.some(set => set.reps > 100 || set.weight * pounds > 1500);
  if (flagged) {
    done.earnedXP = 0;
    done.flagged = true;
  } else {
    const streak = applySessionDay(storedStreak(p), done.day, streakShieldDays(p.ranks || {}));
    p.streak = {lastDate: streak.lastDate, current: streak.current, longest: streak.longest};
    p.freezes = streak.freezes;
    const base = Math.max(10, Math.round(volume ** 0.8 * 0.35 + reps * 0.5 + Math.min(duration / 60, 120) * 1.5));
    done.earnedXP = applyTalentEffects(base, p.ranks || {}, {volume, streak: streak.current, friends:p.community?.friends || 0, inGuild:p.community?.inGuild === true});
  }
  p.sessions.push(done);
  p.bonusPoints = (p.bonusPoints || 0) + bonusTalentPoints(p.ranks || {}, before, level(xp(p)));
  p.active = null;
  return done;
}
export function card(p) {
  const s = stats(p);
  return {
    version: 1,
    id: p.id,
    name: p.name,
    level: s.level,
    sessions: s.sessions,
    sets: s.sets,
    issued: Date.now(),
  };
}
export function encodeCard(p) {
  const bytes = new TextEncoder().encode(JSON.stringify(card(p)));
  return "EGFW1." + btoa(String.fromCharCode(...bytes));
}
export function decodeCard(text) {
  if (
    typeof text !== "string" ||
    text.length > 3000 ||
    !text.startsWith("EGFW1.")
  )
    throw Error("Paste an Endgame web player code starting EGFW1.");
  let c;
  try {
    c = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(
        Uint8Array.from(atob(text.slice(6).trim()), (x) => x.charCodeAt(0)),
      ),
    );
  } catch {
    throw Error("This player code is damaged.");
  }
  if (
    c.version !== 1 ||
    typeof c.id !== "string" ||
    c.id.length > 80 ||
    !c.id ||
    typeof c.name !== "string" ||
    !c.name.trim() ||
    c.name.length > 40 ||
    ![c.level, c.sessions, c.sets, c.issued].every(Number.isSafeInteger) ||
    c.level < 1 ||
    c.level > 100000 ||
    c.sessions < 0 ||
    c.sets < 0 ||
    c.issued < 0 ||
    c.issued > Date.now() + 86400000
  )
    throw Error("Invalid player snapshot.");
  return {
    version: 1,
    id: c.id,
    name: c.name,
    level: c.level,
    sessions: c.sessions,
    sets: c.sets,
    issued: c.issued,
  };
}
export function validateState(v) {
  if (
    !v ||
    v.version !== 1 ||
    !Array.isArray(v.players) ||
    v.players.length > 30 ||
    !Array.isArray(v.rivals) ||
    v.rivals.length > 100
  )
    throw Error("Unsupported backup format.");
  const ids = new Set();
  for (const p of v.players) {
    const prefs = newPlayer(p.name, p.goal, p.equipment, p.days, p.minutes);
    if (
      typeof p.id !== "string" ||
      !p.id ||
      p.id.length > 80 ||
      ids.has(p.id) ||
      !["kg", "lb"].includes(p.unit) ||
      !Array.isArray(p.sessions) ||
      p.sessions.length > 20000 ||
      !Array.isArray(p.claimed) ||
      !p.claimed.every((x) => typeof x === "string" && x.length < 100)
    )
      throw Error("Invalid player data.");
    ids.add(p.id);
    const intBetween = (n, min, max) => Number.isSafeInteger(n) && n >= min && n <= max;
    const record = value => value && typeof value === "object" && !Array.isArray(value);
    if (p.community != null && (!record(p.community) || !intBetween(p.community.friends,0,Number.MAX_SAFE_INTEGER) || typeof p.community.inGuild !== "boolean")) throw Error("Invalid community context.");
    if (p.streak != null && (!record(p.streak) || !/^\d{4}-\d{2}-\d{2}$/.test(p.streak.lastDate) ||
        !intBetween(p.streak.current,1,20000) || !intBetween(p.streak.longest,p.streak.current,20000))) throw Error("Invalid streak.");
    if (p.raidRewards != null && (!Array.isArray(p.raidRewards) || p.raidRewards.some(r=>!r || !intBetween(r.xp,0,100000) || !Number.isSafeInteger(r.week)))) throw Error("Invalid raid rewards.");
    if (p.ranks != null && (!record(p.ranks) || Object.entries(p.ranks).some(([id,n]) =>
      !nodeById(id) || !intBetween(n,0,nodeById(id).max_rank)))) throw Error("Invalid talent ranks.");
    for (const key of ["rewardPoints","bonusPoints","freezes"]) {
      if (p[key] != null && !intBetween(p[key],0,key === "freezes" ? 3 : 100000)) throw Error("Invalid reward balance.");
    }
    if (p.seasonClaims != null && (!record(p.seasonClaims) || Object.entries(p.seasonClaims).some(([id,tiers]) =>
      !/^s[1-9]\d*$/.test(id) || !Array.isArray(tiers) || tiers.length > 30 ||
      tiers.some(n => !intBetween(n,1,30)) || new Set(tiers).size !== tiers.length))) throw Error("Invalid season claims.");
    if (p.questTimes != null && (!record(p.questTimes) || Object.entries(p.questTimes).some(([id,time]) =>
      !p.claimed.includes(id) || !Number.isSafeInteger(time)))) throw Error("Invalid quest history.");
    for (const key of ["titles","auras"]) {
      if (p[key] != null && (!Array.isArray(p[key]) || p[key].some(v => typeof v !== "string" || v.length > 100)))
        throw Error("Invalid reward inventory.");
    }
    if (p.schedule) makePlan(p);
    if (p.phases && (!Array.isArray(p.phases) || !p.phases.length || p.phases.length > 24 ||
        p.phases.some(phase => !phase || !Number.isInteger(phase.weeks) || phase.weeks < 1 || phase.weeks > 24 ||
          ![phase.name, phase.reps, phase.focus].every(text => typeof text === "string" && text.length <= 200))))
      throw Error("Invalid training phases.");
    const sessionIds = new Set();
    for (const s of [...p.sessions, ...(p.active ? [p.active] : [])]) {
      if (sessionIds.has(s.id)) throw Error("Invalid duplicate workout");
      sessionIds.add(s.id);
      if (
        typeof s.id !== "string" ||
        typeof s.name !== "string" ||
        s.name.length > 120 ||
        !Number.isFinite(s.started) ||
        !Array.isArray(s.exercises) ||
        s.exercises.length > 50
      )
        throw Error("Invalid workout data.");
      for (const e of s.exercises) {
        if (!byId(e.id) || !Array.isArray(e.sets) || e.sets.length > 30)
          throw Error("Invalid exercise.");
        for (const t of e.sets)
          if (
            !Number.isFinite(t.weight) ||
            t.weight < 0 ||
            t.weight > 2000 ||
            !Number.isInteger(t.reps) ||
            t.reps < 0 ||
            t.reps > 500 ||
            !Number.isInteger(t.rir) ||
            t.rir < 0 ||
            t.rir > 10 ||
            typeof t.done !== "boolean"
          )
            throw Error("Invalid set data.");
      }
      if (
        s !== p.active &&
        (!Number.isFinite(s.finished) ||
          typeof s.day !== "string" ||
          !/^\d{4}-\d{2}-\d{2}$/.test(s.day))
      )
        throw Error("Invalid session date.");
    }
    // Rebuild plans from validated preferences; never execute imported plan instructions.
    if (p.plan && typeof p.plan.id === "string" && p.plan.id.length < 100) {
      const old = p.plan;
      p.plan = makePlan(p);
      p.plan.id = old.id;
      p.plan.created = Number.isFinite(old.created) ? old.created : Date.now();
    } else p.plan = null;
    for (const e of p.active?.exercises || []) {
      const prescribed = p.schedule?.sessions.find(s => s.name === p.active.name)?.exercises.find(item => item.id === e.id);
      if (prescribed) {
        e.low = prescribed.low;
        e.high = prescribed.high;
        e.rest = prescribed.rest;
        e.reason = typeof e.reason === "string" ? e.reason.slice(0, 300) : "";
        continue;
      }
      e.low = p.goal === "strength" ? 5 : 8;
      e.high = p.goal === "strength" ? 8 : 12;
      e.rest =
        byId(e.id).pattern === "core" ? 60 : p.goal === "strength" ? 150 : 90;
      e.reason =
        typeof e.reason === "string"
          ? e.reason.slice(0, 300)
          : "Use a comfortable load.";
    }
    p.recovery =
      Number.isInteger(p.recovery) && p.recovery >= 1 && p.recovery <= 5
        ? p.recovery
        : 3;
  }
  for (const r of v.rivals)
    decodeCard(
      "EGFW1." +
        btoa(
          String.fromCharCode(...new TextEncoder().encode(JSON.stringify(r))),
        ),
    );
  if (v.selected !== null && !ids.has(v.selected))
    throw Error("Selected player is missing.");
  return v;
}
export function load(storage) {
  const raw = storage.getItem(key);
  if (!raw) return fresh();
  return validateState(JSON.parse(raw));
}
export function save(storage, state) {
  storage.setItem(key, JSON.stringify(state));
}
