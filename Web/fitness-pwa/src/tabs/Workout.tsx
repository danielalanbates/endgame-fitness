import { useEffect, useMemo, useRef, useState } from 'react';
import { apiSync, OutgoingSession, SyncResult, WorkoutExercise, WorkoutSet } from '../api';
import { useAuth } from '../auth';

interface DraftSet extends WorkoutSet {
  done: boolean;
}
interface DraftExercise {
  name: string;
  sets: DraftSet[];
}

// Queued workouts and the sync watermark are kept per member, so on a shared
// browser one person's offline workouts never upload into someone else's
// account. Builds before this used one global key; the first member to open
// the Train tab afterwards adopts it (on a personal phone, its owner).
const LEGACY_QUEUE_KEY = 'ef_pending_sessions';
const LEGACY_LAST_SYNC_KEY = 'ef_last_sync';
const queueKey = (userId: string) => `${LEGACY_QUEUE_KEY}:${userId}`;
const lastSyncKey = (userId: string) => `${LEGACY_LAST_SYNC_KEY}:${userId}`;

function loadQueue(userId: string): OutgoingSession[] {
  try {
    const legacy = localStorage.getItem(LEGACY_QUEUE_KEY);
    if (legacy !== null) {
      const mine: OutgoingSession[] = JSON.parse(localStorage.getItem(queueKey(userId)) || '[]');
      localStorage.setItem(queueKey(userId), JSON.stringify([...mine, ...JSON.parse(legacy)]));
      localStorage.removeItem(LEGACY_QUEUE_KEY);
      localStorage.removeItem(LEGACY_LAST_SYNC_KEY);
    }
    return JSON.parse(localStorage.getItem(queueKey(userId)) || '[]');
  } catch {
    return [];
  }
}
function saveQueue(userId: string, q: OutgoingSession[]) {
  try {
    localStorage.setItem(queueKey(userId), JSON.stringify(q));
  } catch {
    /* ignore */
  }
}

function uuid(): string {
  if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) return crypto.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

export default function Workout({ onToast, onSynced }: { onToast: (msg: string) => void; onSynced: () => void }) {
  const { user } = useAuth();
  const userId = user?.id || 'anonymous';
  const [exercises, setExercises] = useState<DraftExercise[]>([]);
  const [sessionName, setSessionName] = useState('');
  const [active, setActive] = useState(false);
  const [startTime, setStartTime] = useState(0);
  const [elapsed, setElapsed] = useState(0);
  const [newExName, setNewExName] = useState('');
  const [finishing, setFinishing] = useState(false);
  const [pending, setPending] = useState<OutgoingSession[]>(() => loadQueue(userId));
  const timerRef = useRef<number | null>(null);

  const flushQueue = async (extra: OutgoingSession[]): Promise<SyncResult | null> => {
    const batch = [...loadQueue(userId), ...extra];
    if (batch.length === 0) return null;
    // This tab only pushes; the Progress tab pulls history. server_time as the
    // watermark keeps these responses from re-sending rows nobody reads here.
    const since = Number(localStorage.getItem(lastSyncKey(userId)) || 0);
    const res = await apiSync(batch, since);
    const accepted = new Set(res.accepted);
    const remaining = batch.filter((s) => !accepted.has(s.id));
    saveQueue(userId, remaining);
    setPending(remaining);
    localStorage.setItem(lastSyncKey(userId), String(res.server_time));
    return res;
  };

  // Drain any queue left from a previous offline session, and whenever the
  // device comes back online — the user shouldn't have to remember to tap.
  const flushRef = useRef(flushQueue);
  flushRef.current = flushQueue;
  useEffect(() => {
    flushRef.current([]).catch(() => {
      /* still offline; the queue stays on-device */
    });
    const onOnline = () => {
      flushRef.current([]).catch(() => {
        /* dropped again; queue stays on-device */
      });
    };
    window.addEventListener('online', onOnline);
    return () => window.removeEventListener('online', onOnline);
  }, []);

  useEffect(() => {
    if (active) {
      timerRef.current = window.setInterval(() => setElapsed(Math.floor((Date.now() - startTime) / 1000)), 1000);
    }
    return () => {
      if (timerRef.current) window.clearInterval(timerRef.current);
    };
  }, [active, startTime]);

  const totals = useMemo(() => {
    let volume = 0;
    let reps = 0;
    for (const ex of exercises) {
      for (const s of ex.sets) {
        if (!s.done) continue;
        volume += s.weight * s.reps;
        reps += s.reps;
      }
    }
    return { volume, reps };
  }, [exercises]);

  const start = () => {
    setActive(true);
    setStartTime(Date.now());
    setElapsed(0);
  };

  const addExercise = () => {
    const name = newExName.trim();
    if (!name) return;
    setExercises((xs) => [...xs, { name, sets: [{ reps: 8, weight: 0, done: false }] }]);
    setNewExName('');
  };

  const addSet = (i: number) => {
    setExercises((xs) =>
      xs.map((ex, j) => {
        if (j !== i) return ex;
        const last = ex.sets[ex.sets.length - 1];
        return { ...ex, sets: [...ex.sets, { reps: last?.reps ?? 8, weight: last?.weight ?? 0, done: false }] };
      }),
    );
  };

  const updateSet = (i: number, k: number, patch: Partial<DraftSet>) => {
    setExercises((xs) =>
      xs.map((ex, j) => (j === i ? { ...ex, sets: ex.sets.map((s, l) => (l === k ? { ...s, ...patch } : s)) } : ex)),
    );
  };

  const removeExercise = (i: number) => setExercises((xs) => xs.filter((_, j) => j !== i));

  const finish = async () => {
    if (totals.reps === 0) {
      onToast('Log at least one completed set first.');
      return;
    }
    setFinishing(true);
    const payloadExercises: WorkoutExercise[] = exercises
      .map((ex) => ({
        name: ex.name,
        sets: ex.sets.filter((s) => s.done).map((s) => ({ reps: s.reps, weight: s.weight })),
      }))
      .filter((ex) => ex.sets.length > 0);

    const session: OutgoingSession = {
      id: uuid(),
      performed_at: Math.floor(startTime / 1000),
      name: sessionName.trim() || null,
      program_id: null,
      duration_secs: elapsed,
      total_volume: Math.round(totals.volume),
      total_reps: totals.reps,
      client_rev: 1,
      payload: { exercises: payloadExercises },
    };

    try {
      const res = await flushQueue([session]);
      setExercises([]);
      setSessionName('');
      setActive(false);
      onSynced();
      if (res) {
        onToast(
          res.levels_gained > 0
            ? `🎉 LEVEL UP! +${res.xp_gained.toLocaleString()} XP`
            : `+${res.xp_gained.toLocaleString()} XP earned`,
        );
      } else {
        onToast('Workout saved — will sync when you are back online.');
      }
    } catch (e) {
      // Offline or server hiccup: keep it queued, never lose the workout.
      const q = [...loadQueue(userId), session];
      saveQueue(userId, q);
      setPending(q);
      setExercises([]);
      setSessionName('');
      setActive(false);
      onToast('No connection — workout queued on this device.');
    } finally {
      setFinishing(false);
    }
  };

  const retryPending = async () => {
    try {
      const res = await flushQueue([]);
      if (res) {
        onToast(`Synced ${res.accepted.length} queued workout${res.accepted.length === 1 ? '' : 's'} (+${res.xp_gained} XP)`);
        onSynced();
      } else onToast('Nothing to sync.');
    } catch {
      onToast('Still offline — keeping your workouts safe on this device.');
    }
  };

  const mmss = `${String(Math.floor(elapsed / 60)).padStart(2, '0')}:${String(elapsed % 60).padStart(2, '0')}`;

  if (!active) {
    return (
      <>
        <div className="card" style={{ textAlign: 'center', padding: '28px 16px' }}>
          <div style={{ fontSize: 44 }}>🏋️</div>
          <h3 style={{ fontSize: 18 }}>Ready to train?</h3>
          <p className="muted" style={{ fontSize: 14 }}>
            Every set earns XP. The server decides your level — no cheating, just lifting.
          </p>
          <div className="field" style={{ textAlign: 'left', marginBottom: 12 }}>
            <label>Session name (optional)</label>
            <input
              value={sessionName}
              onChange={(e) => setSessionName(e.target.value)}
              placeholder="Push day, Legs, …"
              maxLength={60}
            />
          </div>
          <button className="btn btn-primary" onClick={start}>Start workout</button>
        </div>
        {pending.length > 0 && (
          <div className="card" style={{ borderColor: 'var(--gold)' }}>
            <div className="spread">
              <div>
                <strong>{pending.length} workout{pending.length === 1 ? '' : 's'} waiting to sync</strong>
                <div className="muted" style={{ fontSize: 13 }}>Stored on this device, safe.</div>
              </div>
              <button className="btn btn-sm btn-primary" onClick={retryPending}>Sync now</button>
            </div>
          </div>
        )}
      </>
    );
  }

  return (
    <>
      <div className="card">
        <div className="spread">
          <div>
            <div className="eyebrow">Live session</div>
            <div className="big" style={{ fontVariantNumeric: 'tabular-nums' }}>{mmss}</div>
          </div>
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontWeight: 800 }}>{Math.round(totals.volume).toLocaleString()} lb</div>
            <div className="muted" style={{ fontSize: 12 }}>{totals.reps} reps</div>
          </div>
        </div>
      </div>

      {exercises.map((ex, i) => (
        <div key={i} className="exercise-block">
          <div className="spread" style={{ marginBottom: 6 }}>
            <strong>{ex.name}</strong>
            <button className="btn-ghost btn btn-sm" onClick={() => removeExercise(i)} aria-label={`Remove ${ex.name}`}>✕</button>
          </div>
          <div className="set-row" style={{ borderBottom: '1px solid var(--line)', paddingBottom: 4 }}>
            <span className="muted" style={{ fontSize: 11 }}>SET</span>
            <span className="muted" style={{ fontSize: 11, textAlign: 'center' }}>LB</span>
            <span className="muted" style={{ fontSize: 11, textAlign: 'center' }}>REPS</span>
            <span />
          </div>
          {ex.sets.map((s, k) => (
            <div key={k} className={`set-row${s.done ? ' set-done' : ''}`}>
              <div className="set-num">{k + 1}</div>
              <input
                type="number"
                inputMode="decimal"
                min={0}
                value={s.weight || ''}
                placeholder="0"
                onChange={(e) => updateSet(i, k, { weight: Number(e.target.value) || 0 })}
                aria-label={`Set ${k + 1} weight`}
              />
              <input
                type="number"
                inputMode="numeric"
                min={0}
                value={s.reps || ''}
                placeholder="0"
                onChange={(e) => updateSet(i, k, { reps: Number(e.target.value) || 0 })}
                aria-label={`Set ${k + 1} reps`}
              />
              <button
                className="icon-btn"
                onClick={() => updateSet(i, k, { done: !s.done })}
                aria-label={s.done ? `Unmark set ${k + 1}` : `Mark set ${k + 1} done`}
                style={s.done ? { background: 'var(--accent-2)', borderColor: 'var(--accent-2)' } : undefined}
              >
                {s.done ? '✓' : '○'}
              </button>
            </div>
          ))}
          <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={() => addSet(i)}>+ Add set</button>
        </div>
      ))}

      <div className="card">
        <div className="row">
          <input
            value={newExName}
            onChange={(e) => setNewExName(e.target.value)}
            placeholder="Exercise name — e.g. Barbell Squat"
            maxLength={80}
            style={{ flex: 1, minHeight: 48, borderRadius: 12, border: '1px solid var(--line)', background: 'var(--bg-soft)', padding: '0 14px', fontSize: 16 }}
            onKeyDown={(e) => e.key === 'Enter' && addExercise()}
          />
          <button className="btn btn-sm btn-primary" onClick={addExercise}>Add</button>
        </div>
      </div>

      <button className="btn btn-primary" disabled={finishing} onClick={finish}>
        {finishing ? 'Saving…' : 'Finish workout'}
      </button>
      <button className="btn btn-ghost" onClick={() => setActive(false)}>Discard session</button>
    </>
  );
}
