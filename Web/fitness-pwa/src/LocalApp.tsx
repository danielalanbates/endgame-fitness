// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.
import { useEffect, useRef, useState } from 'react';
import CloudApp from './App';
import { buildPlan, emptyTraining, localDate, nextLoad, sessionTotals, sessionXP, STORAGE_KEY, streak, validateTraining } from './localTraining';
import type { LocalProfile, LocalTraining, TrainingSession } from './localTraining';

const tabs = ['Home', 'Train', 'Programs', 'Progress', 'You'] as const;
type Tab = typeof tabs[number];
const iconPaths = ['M3 10 12 3l9 7v11h-6v-7H9v7H3Z', 'M4 8v8m4-12v16m8-16v16m4-12v8M8 12h8', 'M4 4h16v16H4ZM4 9h16M9 9v11', 'M4 20V4m0 16h16M8 16l4-5 4 2 4-8', 'M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0ZM4 21v-2a8 8 0 0 1 16 0v2'];
function readSaved(): { data: LocalTraining; error: string } {
  try { const raw = localStorage.getItem(STORAGE_KEY); return { data: raw ? validateTraining(JSON.parse(raw)) : emptyTraining(), error: '' }; }
  catch { return { data: emptyTraining(), error: 'Your saved data could not be read. It has not been replaced. Restore a backup to continue.' }; }
}
function download(data: LocalTraining) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }));
  const a = document.createElement('a'); a.href = url; a.download = `endgame-fitness-${localDate(Date.now())}.json`; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
export default function LocalApp() {
  const [initial] = useState(readSaved);
  const [data, setData] = useState(initial.data);
  const [error, setError] = useState(initial.error);
  const [tab, setTab] = useState<Tab>('Home');
  const [cloud, setCloud] = useState(false);
  const [message, setMessage] = useState('');
  const [name, setName] = useState('');
  const [profile, setProfile] = useState<LocalProfile>(data.profile ?? { name: '', goal: 'muscle', experience: 'beginner', equipment: 'gym', days: 3 });
  const [now, setNow] = useState(Date.now());
  const fileRef = useRef<HTMLInputElement>(null);
  const finishLock = useRef(false);
  useEffect(() => { if (!data.draft) return; const id = window.setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(id); }, [data.draft?.id]);
  useEffect(() => { if (!message) return; const id = window.setTimeout(() => setMessage(''), 5000); return () => clearTimeout(id); }, [message]);
  // Persist before updating UI: storage failures must never masquerade as saves.
  const commit = (next: LocalTraining) => {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(validateTraining(next))); setData(next); setError(''); return true; }
    catch (e) { setError(e instanceof Error ? e.message : 'Cannot save on this device. Export a backup before leaving.'); return false; }
  };
  const restore = async (file?: File) => {
    if (!file) return;
    try {
      if (file.size > 10_000_000) throw new Error('Backup must be smaller than 10 MB.');
      const next = validateTraining(JSON.parse(await file.text()));
      if (!window.confirm('Replace this device’s local profile and workouts with this backup?')) return;
      if (commit(next)) { setProfile(next.profile ?? profile); setMessage('Backup restored.'); }
    } catch (e) { setError(e instanceof Error ? e.message : 'Could not restore backup.'); }
    if (fileRef.current) fileRef.current.value = '';
  };
  const backupControls = <><button className="btn" onClick={() => download(data)}>Export backup</button><button className="btn" onClick={() => fileRef.current?.click()}>Restore backup</button></>;
  const fileInput = <input ref={fileRef} type="file" accept=".json,application/json" hidden onChange={e => void restore(e.target.files?.[0])} />;
  if (cloud) return <><div className="local-cloud-bar"><button className="btn" onClick={() => setCloud(false)}>← Back to local training</button><span>Online community · separate account</span></div><CloudApp /></>;
  if (initial.error && !data.profile && error) return <main className="app-main"><h1>Recover your training</h1><p role="alert" className="error-box">{error}</p><button className="btn" onClick={() => fileRef.current?.click()}>Restore backup</button>{fileInput}</main>;
  if (!data.profile) return <main className="app-main local-onboarding">
    <div className="eyebrow">ENDGAME FITNESS · LOCAL FIRST</div><h1>Your next level<br />starts here.</h1><p className="muted">Build strength. Earn your progress. Your profile and training stay on this device, with no account required.</p>
    <form className="card stack" onSubmit={e => { e.preventDefault(); if (commit({ ...data, profile: { ...profile, name: profile.name.trim() } })) setMessage('Your training profile is ready.'); }}>
      <ProfileFields profile={profile} onChange={setProfile} />
      <button className="btn btn-primary" type="submit">Enter the gym →</button>
    </form><p className="muted">Already trained here? Restore an Endgame Fitness backup. Clearing browser data removes local training; export backups regularly.</p><button className="btn" onClick={() => fileRef.current?.click()}>Restore backup</button><button className="btn btn-ghost" onClick={() => setCloud(true)}>Open existing online account</button>{fileInput}{error && <p role="alert" className="error-box">{error}</p>}
  </main>;
  const xp = data.history.reduce((sum, s) => sum + sessionXP(s), 0);
  const level = Math.floor(Math.sqrt(xp / 100)) + 1;
  const floor = (level - 1) ** 2 * 100, ceiling = level ** 2 * 100;
  const totals = data.history.reduce((a,s) => { const t = sessionTotals(s); return { volume: a.volume + t.volume, reps: a.reps + t.reps }; }, { volume: 0, reps: 0 });
  const plan = buildPlan(data.profile);
  const start = (index?: number) => {
    if (data.draft) { setTab('Train'); return; }
    const selected = index === undefined ? undefined : plan[index];
    const exercises = selected?.exercises.map(ex => {
      const previous = [...data.history].reverse().flatMap(s => s.exercises).find(e => e.name === ex.name);
      const weight = nextLoad(previous, ex.sets[0].reps);
      return { ...ex, sets: ex.sets.map(s => ({ ...s, weight })) };
    }) ?? [];
    const session: TrainingSession = { id: crypto.randomUUID(), name: selected?.name ?? 'Free workout', startedAt: Date.now(), exercises };
    if (commit({ ...data, draft: session })) { setNow(Date.now()); setTab('Train'); }
  };
  const patchDraft = (draft: TrainingSession) => commit({ ...data, draft });
  const finish = () => {
    if (!data.draft || finishLock.current) return;
    if (sessionTotals(data.draft).reps === 0) { setMessage('Complete at least one set with reps first.'); return; }
    finishLock.current = true;
    const finished = { ...data.draft, finishedAt: Date.now() };
    if (commit({ ...data, draft: null, history: [...data.history, finished] })) { setMessage(`Workout saved · +${sessionXP(finished)} local XP`); setTab('Progress'); }
    finishLock.current = false;
  };
  const share = async () => {
    const text = `${data.profile!.name} · Endgame Fitness\nLevel ${level} · ${data.history.length} workouts · ${streak(data.history)} day streak\nTrain with me: https://batesai.org/fitness/`;
    try { if (navigator.share) await navigator.share({ title: 'Endgame Fitness', text }); else { await navigator.clipboard.writeText(text); setMessage('Progress copied. Share it with your friends.'); } }
    catch (e) { if (!(e instanceof DOMException && e.name === 'AbortError')) setMessage('Sharing unavailable. Try exporting a backup instead.'); }
  };
  return <>
    <header className="local-header"><a href="https://batesai.org">BATESAI</a><span>ENDGAME <b>FITNESS</b></span><span className="pill">LOCAL</span></header>
    <main className="app-main local-main">
      {error && <div role="alert" className="error-box">{error}</div>}
      {tab === 'Home' && <>
        <section className="local-hero card"><div className="eyebrow">YOUR TRAINING CAMPAIGN</div><h1>Welcome back,<br />{data.profile.name}.</h1><p className="muted">Small wins. Stronger every week.</p><div className="spread"><strong>LEVEL {level}</strong><span>{xp.toLocaleString()} XP</span></div><progress aria-label="Level progress" value={xp-floor} max={ceiling-floor} /><p className="muted">{ceiling-xp} XP to level {level+1} · local progression</p><button className="btn btn-primary" onClick={() => start(data.history.length % plan.length)}>{data.draft ? 'Resume your workout' : 'Start today’s training →'}</button></section>
        <div className="local-stats"><Stat label="Workouts" value={data.history.length} /><Stat label="Day streak" value={streak(data.history)} /><Stat label="Volume · lb" value={Math.round(totals.volume).toLocaleString()} /></div>
        <section className="card"><div className="eyebrow">WEEKLY QUEST</div><h2>Show up for yourself</h2><p>Complete {data.profile.days} sessions this week. Rest days are part of the plan.</p><WeekQuest history={data.history} days={data.profile.days} /><button className="btn" onClick={() => setTab('Programs')}>View your training plan</button></section>
        <section className="card"><h2>Your party starts with a friend</h2><p className="muted">Share your progress through your phone’s share menu. Your workout details and measurements stay private.</p><button className="btn" onClick={() => void share()}>Share progress</button></section>
      </>}
      {tab === 'Programs' && <><div className="eyebrow">BUILT FOR YOUR GOAL</div><h1>Your training plan</h1><section className="card"><h2>{data.profile.goal === 'strength' ? 'Build strength' : data.profile.goal === 'muscle' ? 'Build muscle' : 'Move with confidence'}</h2><p>{data.profile.days} sessions / week · {data.profile.equipment} · {data.profile.experience}</p><p className="muted">Leave 2–3 reps in reserve. Rest 2–3 minutes between compound sets, 60–90 seconds for accessories. Spread sessions across the week and take rest days. Core exercises use controlled repetitions per side.</p><p className="muted">Loads start at zero. Choose an appropriate load; the next session suggests a 2.5% increase only after all prescribed sets reach the target. Use smaller available increments or repeat a load when needed.</p>{data.profile.equipment === 'bodyweight' && <p className="muted">Prone raises train shoulder control; they do not replace loaded rows. Add pulling equipment when available.</p>}</section>{plan.map((day,i) => <section className="card" key={day.name}><h2>{day.name}</h2>{day.exercises.map(ex => <div className="spread local-plan-row" key={ex.name}><span>{ex.name}</span><strong>{ex.sets.length} × {ex.sets[0].reps}</strong></div>)}<button className="btn btn-primary" onClick={() => start(i)}>{data.draft ? 'Resume current workout' : 'Train this day'}</button></section>)}</>}
      {tab === 'Train' && (!data.draft ? <section className="card"><h1>Ready to train?</h1><p className="muted">Follow your program or log your own session. Sets save as you go.</p><button className="btn btn-primary" onClick={() => start(data.history.length % plan.length)}>Start program session</button><button className="btn" onClick={() => start()}>Start free workout</button></section> : <>
        <section className="card"><div className="eyebrow">LIVE SESSION · SAVED ON DEVICE</div><h1>{data.draft.name}</h1><div className="spread"><strong>{Math.floor(Math.max(0,now-data.draft.startedAt)/60000)} min</strong><span>{sessionTotals(data.draft).sets} sets · {Math.round(sessionTotals(data.draft).volume).toLocaleString()} lb</span></div></section>
        {data.draft.exercises.map((ex,i) => <section className="exercise-block" key={i}><div className="spread"><h2>{ex.name}</h2><button className="btn btn-sm" aria-label={`Remove ${ex.name}`} onClick={() => { if (confirm(`Remove ${ex.name} and its sets?`)) patchDraft({ ...data.draft!, exercises: data.draft!.exercises.filter((_,j) => i!==j) }); }}>✕</button></div><div className="set-row muted"><span>SET</span><span>LB</span><span>REPS</span><span>DONE</span></div>{ex.sets.map((s,k) => <div className={`set-row${s.done ? ' set-done' : ''}`} key={k}><span>{k+1}</span>{(['weight','reps'] as const).map(field => <input key={field} type="number" min="0" max={field==='weight' ? 2000 : 1000} step={field==='weight' ? 0.5 : 1} inputMode={field==='weight' ? 'decimal' : 'numeric'} aria-label={`${ex.name} set ${k+1} ${field}`} value={s[field]} onChange={e => { const value = Number(e.target.value); if (!Number.isFinite(value) || value<0 || value>(field==='weight'?2000:1000) || (field==='reps' && !Number.isInteger(value))) return; patchDraft({ ...data.draft!, exercises: data.draft!.exercises.map((x,j) => j===i ? {...x,sets:x.sets.map((y,l) => l===k ? {...y,[field]:value,done:false}:y)}:x) }); }} />)}<button className="icon-btn" aria-label={`${s.done?'Unmark':'Complete'} ${ex.name} set ${k+1}`} aria-pressed={s.done} onClick={() => { if (!s.done && s.reps<1) { setMessage('Enter at least one rep.'); return; } patchDraft({...data.draft!,exercises:data.draft!.exercises.map((x,j)=>j===i?{...x,sets:x.sets.map((y,l)=>l===k?{...y,done:!y.done}:y)}:x)}); }}>{s.done?'✓':'○'}</button></div>)}<button className="btn btn-sm" disabled={ex.sets.length>=100} onClick={() => patchDraft({...data.draft!,exercises:data.draft!.exercises.map((x,j)=>j===i?{...x,sets:[...x.sets,{weight:x.sets[x.sets.length-1]?.weight??0,reps:x.sets[x.sets.length-1]?.reps??8,done:false}]}:x)})}>+ Add set</button></section>)}
        <form className="card row" onSubmit={e => { e.preventDefault(); if (!name.trim()) return; if (patchDraft({...data.draft!,exercises:[...data.draft!.exercises,{name:name.trim(),sets:[{weight:0,reps:8,done:false}]}]})) setName(''); }}><input className="local-exercise-input" aria-label="Exercise name" maxLength={100} value={name} onChange={e=>setName(e.target.value)} placeholder="Add an exercise" required /><button className="btn" disabled={data.draft.exercises.length>=100}>Add</button></form>
        <button className="btn btn-primary" onClick={finish}>Finish and earn XP</button><button className="btn btn-ghost" onClick={() => { if (confirm('Discard this unfinished workout?')) commit({...data,draft:null}); }}>Discard session</button>
      </>)}
      {tab === 'Progress' && <><div className="eyebrow">PROOF OF YOUR WORK</div><h1>Your progress</h1><div className="local-stats"><Stat label="Level" value={level} /><Stat label="Reps" value={totals.reps} /><Stat label="Workouts" value={data.history.length} /></div><button className="btn" onClick={()=>void share()}>Share your progress</button>{data.history.length===0 && <section className="card"><h2>Your story starts with one session</h2><p className="muted">Finish a workout to start your history.</p></section>}{[...data.history].reverse().map(s=><section className="card" key={s.id}><div className="spread"><h2>{s.name}</h2><span className="pill">+{sessionXP(s)} XP</span></div><p className="muted">{new Date(s.finishedAt!).toLocaleDateString()} · {sessionTotals(s).sets} sets · {Math.round(sessionTotals(s).volume).toLocaleString()} lb</p><details><summary>View completed sets</summary>{s.exercises.map((ex,i)=><p key={i}><strong>{ex.name}</strong> · {ex.sets.filter(x=>x.done).map(x=>`${x.weight} lb × ${x.reps}`).join(', ') || 'No completed sets'}</p>)}</details></section>)}</>}
      {tab === 'You' && <><h1>Your training profile</h1><form className="card stack" onSubmit={e=>{e.preventDefault(); if(commit({...data,profile:{...profile,name:profile.name.trim()}}))setMessage('Profile saved. Your plan has been updated.');}}><ProfileFields profile={profile} onChange={setProfile}/><button className="btn btn-primary">Save profile</button></form><section className="card stack"><h2>Your data, your device</h2><p className="muted">This local profile is separate from your existing online account. Nothing is uploaded. Backups include your name and workouts; keep them private. Local XP is separate from ranked online progression.</p>{backupControls}<button className="btn" onClick={()=>setCloud(true)}>Open online community</button><p className="muted">Existing online friends, guilds and leaderboards require sign-in. Facebook account linking is not configured.</p></section><section className="card"><h2>Support</h2><p><a href="https://batesai.org">batesai.org</a> · <a href="mailto:help@batesai.org">help@batesai.org</a></p></section></>}
    </main>
    <nav className="tabbar" aria-label="Main">{tabs.map((t,i)=><button key={t} className={t===tab?'active':''} aria-current={t===tab?'page':undefined} onClick={()=>setTab(t)}><span className="ico" aria-hidden="true"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d={iconPaths[i]}/></svg></span>{t}</button>)}</nav>
    {message && <div className="success-pop" role="status">{message}</div>}{fileInput}
  </>;
}
function Stat({label,value}:{label:string;value:string|number}) { return <div className="card"><strong>{value}</strong><span className="muted">{label}</span></div>; }
function WeekQuest({history,days}:{history:TrainingSession[];days:number}) {
  const monday = new Date(); monday.setHours(0,0,0,0); monday.setDate(monday.getDate()-((monday.getDay()+6)%7));
  const count = history.filter(s=>s.finishedAt!>=+monday && s.finishedAt!<=Date.now()).length;
  return <><progress aria-label="Weekly training quest" value={Math.min(days,count)} max={days}/><p>{Math.min(days,count)} / {days} sessions{count>=days?' · Quest complete!':''}</p></>;
}
function ProfileFields({profile,onChange}:{profile:LocalProfile;onChange:(p:LocalProfile)=>void}) { return <>
  <label className="field">Your name<input value={profile.name} maxLength={60} required pattern=".*\S.*" autoComplete="given-name" onChange={e=>onChange({...profile,name:e.target.value})}/></label>
  <label className="field">Primary goal<select value={profile.goal} onChange={e=>onChange({...profile,goal:e.target.value as LocalProfile['goal']})}><option value="muscle">Build muscle</option><option value="strength">Build strength</option><option value="fitness">General fitness</option></select></label>
  <label className="field">Experience<select value={profile.experience} onChange={e=>onChange({...profile,experience:e.target.value as LocalProfile['experience']})}><option value="beginner">Beginner</option><option value="intermediate">Intermediate</option><option value="advanced">Advanced</option></select></label>
  <label className="field">Equipment<select value={profile.equipment} onChange={e=>onChange({...profile,equipment:e.target.value as LocalProfile['equipment']})}><option value="gym">Full gym</option><option value="dumbbells">Dumbbells</option><option value="bodyweight">Bodyweight</option></select></label>
  <label className="field">Sessions per week<select value={profile.days} onChange={e=>onChange({...profile,days:Number(e.target.value)})}>{[2,3,4,5].map(n=><option key={n} value={n}>{n} days</option>)}</select></label>
</>; }
