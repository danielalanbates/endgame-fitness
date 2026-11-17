import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildPlan, emptyTraining, nextLoad, sessionTotals, sessionXP, streak, validateTraining } from '../src/localTraining.ts';
const profile = { name:'Test Athlete', goal:'muscle', experience:'beginner', equipment:'gym', days:3 };
const session = (date) => ({ id: date, name:'Session', startedAt:+new Date(date), finishedAt:+new Date(date)+1000, exercises:[{name:'Squat',sets:[{weight:100,reps:10,done:true},{weight:100,reps:10,done:false}]}] });
test('backup round-trip preserves answers, history and unfinished sets',()=>{
 const data = {...emptyTraining(),profile,history:[session('2026-11-16T12:00:00')],draft:{...session('2026-11-17T12:00:00'),finishedAt:undefined}};
 assert.deepEqual(validateTraining(JSON.parse(JSON.stringify(data))),JSON.parse(JSON.stringify(data)));
});
test('malformed backups, invalid loads, duplicate IDs, unfinished history are rejected',()=>{
 for(const value of [null,[],{version:2,history:[]}, {...emptyTraining(),profile:{...profile,days:7}}, {...emptyTraining(),history:[session('2026-11-16'),session('2026-11-16')]}, {...emptyTraining(),history:[{...session('2026-11-16'),finishedAt:undefined}]}]) assert.throws(()=>validateTraining(value));
 const s=session('2026-11-16');s.exercises[0].sets[0].weight=-10;assert.throws(()=>validateTraining({...emptyTraining(),history:[s]}));
});
test('completed sets alone contribute volume, reps and local XP',()=>{
 const s=session('2026-11-16');assert.deepEqual(sessionTotals(s),{volume:1000,reps:10,sets:1}); assert.equal(sessionXP(s),60);
 s.exercises[0].sets[0].done=false;assert.equal(sessionXP(s),0);
});
test('streak allows today as a rest day but breaks after a missed day',()=>{
 const history=['2026-11-14T12:00:00','2026-11-15T12:00:00','2026-11-16T12:00:00'].map(session);
 assert.equal(streak(history,+new Date('2026-11-17T15:00:00')),3);
 assert.equal(streak(history,+new Date('2026-11-18T15:00:00')),0);
 assert.equal(streak([...history,session('2026-11-16T13:00:00')],+new Date('2026-11-17T15:00:00')),3);
});
test('all goal/equipment/frequency combinations produce bounded starting plans',()=>{
 for(const goal of ['strength','muscle','fitness']) for(const equipment of ['gym','dumbbells','bodyweight']) for(const experience of ['beginner','intermediate','advanced']) for(const days of [2,3,4,5]) {
  const plan=buildPlan({...profile,goal,equipment,experience,days}); assert.equal(plan.length,days);
  for(const day of plan) {assert.equal(day.exercises.length,5);for(const ex of day.exercises) for(const set of ex.sets) {assert.equal(set.weight,0);assert.equal(set.done,false);assert.ok(set.reps>=6&&set.reps<=12);}}
 }
});
test('progression holds load for incomplete sessions and increases only at full target',()=>{
 const ex={name:'Squat',sets:[{weight:100,reps:10,done:true},{weight:100,reps:8,done:false}]};
 assert.equal(nextLoad(ex,10),100); ex.sets[1]={weight:100,reps:10,done:true}; assert.equal(nextLoad(ex,10),102.5); assert.equal(nextLoad(undefined,10),0);
});
