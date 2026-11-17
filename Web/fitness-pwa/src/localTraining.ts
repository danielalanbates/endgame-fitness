// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// PolyForm Noncommercial + commercial rider: see LICENSE. https://batesai.org
export interface LocalProfile {
  name: string;
  goal: 'strength' | 'muscle' | 'fitness';
  experience: 'beginner' | 'intermediate' | 'advanced';
  equipment: 'gym' | 'dumbbells' | 'bodyweight';
  days: number;
}
export interface TrainingSet { weight: number; reps: number; done: boolean }
export interface TrainingExercise { name: string; sets: TrainingSet[] }
export interface TrainingSession { id: string; name: string; startedAt: number; finishedAt?: number; exercises: TrainingExercise[] }
export interface LocalTraining {
  version: 1;
  profile: LocalProfile | null;
  history: TrainingSession[];
  draft: TrainingSession | null;
}
export const STORAGE_KEY = 'ef_local_training_v1';
export const emptyTraining = (): LocalTraining => ({ version: 1, profile: null, history: [], draft: null });
const finite = (n: unknown, max: number) => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= max;
export function validateTraining(value: unknown): LocalTraining {
  const data = value as LocalTraining;
  if (!data || data.version !== 1 || !Array.isArray(data.history) || data.history.length > 10000) throw new Error('Unsupported or invalid Endgame Fitness backup.');
  const p = data.profile;
  if (p !== null && (!p || typeof p.name !== 'string' || !p.name.trim() || p.name.length > 60 || !['strength','muscle','fitness'].includes(p.goal) || !['beginner','intermediate','advanced'].includes(p.experience) || !['gym','dumbbells','bodyweight'].includes(p.equipment) || !Number.isInteger(p.days) || p.days < 2 || p.days > 5)) throw new Error('Invalid training profile.');
  const ids = new Set<string>();
  for (const session of [...data.history, ...(data.draft ? [data.draft] : [])]) {
    if (!session || typeof session.id !== 'string' || !session.id || ids.has(session.id) || typeof session.name !== 'string' || session.name.length > 100 || !finite(session.startedAt, 8640000000000000) || !Array.isArray(session.exercises) || session.exercises.length > 100) throw new Error('Invalid workout in backup.');
    ids.add(session.id);
    if (session.finishedAt !== undefined && (!finite(session.finishedAt, 8640000000000000) || session.finishedAt < session.startedAt)) throw new Error('Invalid workout date.');
    for (const ex of session.exercises) {
      if (!ex || typeof ex.name !== 'string' || !ex.name.trim() || ex.name.length > 100 || !Array.isArray(ex.sets) || ex.sets.length > 100) throw new Error('Invalid exercise.');
      for (const set of ex.sets) if (!set || !finite(set.weight, 2000) || !finite(set.reps, 1000) || !Number.isInteger(set.reps) || typeof set.done !== 'boolean') throw new Error('Invalid set.');
    }
  }
  if (data.history.some(s => s.finishedAt === undefined) || (data.draft && data.draft.finishedAt !== undefined)) throw new Error('Invalid session status.');
  // Explicit shape avoids retaining unexpected fields from imported files.
  return { version: 1, profile: p, history: data.history, draft: data.draft ?? null };
}
export function sessionTotals(session: TrainingSession) {
  return session.exercises.flatMap(e => e.sets).filter(s => s.done).reduce((a, s) => ({ volume: a.volume + s.weight * s.reps, reps: a.reps + s.reps, sets: a.sets + 1 }), { volume: 0, reps: 0, sets: 0 });
}
export function sessionXP(session: TrainingSession) {
  const t = sessionTotals(session);
  return t.reps > 0 ? 50 + Math.min(200, t.sets * 10) : 0;
}
export function localDate(time: number): string {
  const date = new Date(time);
  return `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`;
}
export function streak(history: TrainingSession[], now = Date.now()): number {
  const dates = new Set(history.filter(s => sessionTotals(s).reps > 0).map(s => localDate(s.finishedAt ?? s.startedAt)));
  const date = new Date(now);
  if (!dates.has(localDate(+date))) date.setDate(date.getDate()-1);
  let count = 0;
  while (dates.has(localDate(+date))) { count++; date.setDate(date.getDate()-1); }
  return count;
}
// Moderate starting volume, full-body movement coverage, and alternating days.
// No default heavy loads: select a load that leaves the prescribed reps in reserve.
export function buildPlan(profile: LocalProfile) {
  const choices = {
    gym: [['Squat', 'Bench press', 'Cable row', 'Romanian deadlift', 'Plank'], ['Split squat', 'Overhead press', 'Lat pulldown', 'Hip thrust', 'Side plank']],
    dumbbells: [['Goblet squat', 'Dumbbell floor press', 'Dumbbell row', 'Dumbbell Romanian deadlift', 'Plank'], ['Reverse lunge', 'Dumbbell overhead press', 'Dumbbell row', 'Glute bridge', 'Side plank']],
    bodyweight: [['Bodyweight squat', 'Incline push-up', 'Prone Y raise', 'Glute bridge', 'Dead bug'], ['Reverse lunge', 'Push-up', 'Prone W raise', 'Single-leg glute bridge', 'Side plank']],
  }[profile.equipment];
  const sets = profile.experience === 'beginner' || profile.days >= 4 ? 2 : 3;
  const reps = profile.goal === 'strength' && profile.equipment !== 'bodyweight' ? 6 : profile.goal === 'muscle' ? 10 : 12;
  return Array.from({ length: profile.days }, (_, i) => ({ name: `Day ${i+1} · Full body ${i%2 ? 'B' : 'A'}`, exercises: choices[i%2].map((name, index) => ({ name, sets: Array.from({ length: index === 4 ? 2 : sets }, () => ({ weight: 0, reps: index === 4 ? 10 : reps, done: false })) })) }));
}
export function nextLoad(previous: TrainingExercise | undefined, targetReps: number): number {
  if (!previous) return 0;
  const sets = previous.sets;
  const load = Math.max(0, ...sets.map(s => s.weight));
  // Double progression: only increase when every prescribed set was completed.
  return sets.length > 0 && sets.every(s => s.done && s.reps >= targetReps) && load > 0 ? Math.round((load * 1.025) * 2) / 2 : load;
}
