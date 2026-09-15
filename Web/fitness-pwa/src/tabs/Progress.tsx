import { useEffect, useMemo, useState } from 'react';
import { apiGetProfile, apiSync } from '../api';
import { Empty, Loading } from '../components/ui';

interface SessionRow {
  id: string;
  performed_at: number;
  name: string | null;
  total_volume: number;
  total_reps: number;
  xp_earned: number;
  payload: { exercises?: { name: string; sets: { reps: number; weight: number }[] }[] } | null;
}

interface PR {
  exercise: string;
  reps: number;
  weight: number;
  estimated_1rm: number;
  achieved_at: number;
}

function weekKey(epochSecs: number): string {
  const d = new Date(epochSecs * 1000);
  const day = (d.getDay() + 6) % 7; // Monday = 0
  d.setDate(d.getDate() - day);
  return d.toISOString().slice(0, 10);
}

export default function Progress() {
  const [sessions, setSessions] = useState<SessionRow[]>([]);
  const [prs, setPrs] = useState<PR[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      try {
        const [syncRes, prof] = await Promise.all([
          apiSync([], 0),
          apiGetProfile(),
        ]);
        const rows = (syncRes.sessions as SessionRow[]).sort((a, b) => b.performed_at - a.performed_at);
        setSessions(rows);
        setPrs((prof.personal_records as PR[]).sort((a, b) => b.weight - a.weight));
      } catch {
        /* leave empty */
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  const weeks = useMemo(() => {
    const map = new Map<string, number>();
    for (const s of sessions) {
      const k = weekKey(s.performed_at);
      map.set(k, (map.get(k) || 0) + (s.total_volume || 0));
    }
    const keys = [...map.keys()].sort().slice(-12);
    const max = Math.max(1, ...keys.map((k) => map.get(k)!));
    return keys.map((k) => ({ key: k, volume: map.get(k)!, pct: (map.get(k)! / max) * 100 }));
  }, [sessions]);

  if (loading) return <Loading label="Loading your history…" />;

  return (
    <>
      <div className="card">
        <h3>Volume — last {weeks.length} weeks</h3>
        {weeks.length === 0 ? (
          <Empty>Log your first workout and the chart fills in here.</Empty>
        ) : (
          <div style={{ display: 'flex', alignItems: 'flex-end', gap: 6, height: 120 }}>
            {weeks.map((w) => (
              <div key={w.key} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, height: '100%', justifyContent: 'flex-end' }}>
                <div
                  title={`${w.key}: ${Math.round(w.volume).toLocaleString()} lb`}
                  style={{
                    width: '100%',
                    height: `${Math.max(4, w.pct)}%`,
                    borderRadius: 6,
                    background: 'linear-gradient(180deg, var(--accent), #3a2a8f)',
                  }}
                />
                <span className="muted" style={{ fontSize: 9 }}>{w.key.slice(5).replace('-', '/')}</span>
              </div>
            ))}
          </div>
        )}
      </div>

      {prs.length > 0 && (
        <div className="card">
          <h3>🏆 Personal records</h3>
          <div className="stack">
            {prs.slice(0, 10).map((pr, i) => (
              <div key={i} className="spread">
                <span style={{ fontWeight: 600 }}>{pr.exercise}</span>
                <span className="muted" style={{ fontSize: 13 }}>
                  {pr.weight} lb × {pr.reps}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="card">
        <h3>History</h3>
        {sessions.length === 0 && <Empty>No workouts yet — your history lives here.</Empty>}
        <div>
          {sessions.slice(0, 30).map((s) => (
            <div key={s.id} className="feed-item">
              <div className="spread">
                <div>
                  <div style={{ fontWeight: 700 }}>{s.name || 'Workout'}</div>
                  <div className="muted" style={{ fontSize: 12 }}>
                    {new Date(s.performed_at * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })} ·{' '}
                    {Math.round(s.total_volume).toLocaleString()} lb · {s.total_reps} reps
                  </div>
                </div>
                <span className="chip">+{s.xp_earned} XP</span>
              </div>
              {s.payload?.exercises && s.payload.exercises.length > 0 && (
                <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
                  {s.payload.exercises.slice(0, 4).map((e) => e.name).join(' · ')}
                  {s.payload.exercises.length > 4 && ` +${s.payload.exercises.length - 4} more`}
                </div>
              )}
            </div>
          ))}
        </div>
      </div>
    </>
  );
}
