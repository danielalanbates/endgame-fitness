import { useEffect, useState } from 'react';
import { useAuth } from '../auth';
import {
  apiClaimQuest, apiGetAchievements, apiGetProfile, apiGetQuests, apiGetTalents, apiSpendTalent,
  apiUpdateProfile, Achievement, FitnessProfile, Quest, TalentState,
} from '../api';
import { Empty, Loading, LevelBadge, XpBar } from '../components/ui';

type Sub = 'player' | 'talents' | 'quests' | 'achievements' | 'settings';

export default function Profile({ onToast }: { onToast: (msg: string) => void }) {
  const { user, logout } = useAuth();
  const [sub, setSub] = useState<Sub>('player');
  const [profile, setProfile] = useState<FitnessProfile | null>(null);
  const [talents, setTalents] = useState<TalentState | null>(null);
  const [quests, setQuests] = useState<{ daily: Quest[]; weekly: Quest[] } | null>(null);
  const [achievements, setAchievements] = useState<Achievement[]>([]);
  const [loading, setLoading] = useState(true);
  const [edit, setEdit] = useState({ display_name: '', training_goal: '', units: 'imperial' });

  const load = async () => {
    setLoading(true);
    try {
      const p = await apiGetProfile();
      setProfile(p.profile);
      setEdit({
        display_name: p.profile.display_name,
        training_goal: p.profile.training_goal || '',
        units: p.profile.units || 'imperial',
      });
      if (sub === 'talents') setTalents(await apiGetTalents());
      if (sub === 'quests') setQuests(await apiGetQuests());
      if (sub === 'achievements') setAchievements((await apiGetAchievements()).achievements);
    } catch (e) {
      onToast(e instanceof Error ? e.message : 'Failed to load');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sub]);

  const spend = async (id: string) => {
    try {
      const res = await apiSpendTalent(id);
      setTalents(res);
      onToast('Talent point spent');
    } catch (e) {
      onToast(e instanceof Error ? e.message : 'Cannot spend there yet');
    }
  };

  const claim = async (q: Quest) => {
    try {
      const res = await apiClaimQuest(q.id);
      setQuests((qs) =>
        qs && { daily: qs.daily.map((x) => (x.id === q.id ? res.quest : x)), weekly: qs.weekly.map((x) => (x.id === q.id ? res.quest : x)) },
      );
      onToast(`+${res.xp_gained} XP`);
    } catch (e) {
      onToast(e instanceof Error ? e.message : 'Claim failed');
    }
  };

  const saveSettings = async () => {
    try {
      const res = await apiUpdateProfile({
        display_name: edit.display_name.trim() || undefined,
        training_goal: edit.training_goal.trim() || undefined,
        units: edit.units,
      } as Partial<FitnessProfile>);
      setProfile(res.profile);
      onToast('Profile saved');
    } catch (e) {
      onToast(e instanceof Error ? e.message : 'Save failed');
    }
  };

  return (
    <>
      <div className="seg">
        {(['player', 'talents', 'quests', 'achievements', 'settings'] as Sub[]).map((s) => (
          <button key={s} className={sub === s ? 'active' : ''} onClick={() => setSub(s)}>
            {s === 'player' ? 'Player' : s[0].toUpperCase() + s.slice(1)}
          </button>
        ))}
      </div>

      {loading ? (
        <Loading />
      ) : (
        <>
          {sub === 'player' && profile && (
            <div className="card">
              <div className="row">
                <LevelBadge level={profile.level} />
                <div style={{ flex: 1 }}>
                  <div className="big" style={{ fontSize: 22 }}>{profile.display_name}</div>
                  <div className="muted" style={{ fontSize: 13 }}>{user?.email}</div>
                </div>
              </div>
              <div style={{ marginTop: 12 }}>
                <XpBar current={profile.xp} min={profile.xp_for_current_level} max={profile.xp_for_next_level} />
              </div>
              <div className="grid2" style={{ marginTop: 14 }}>
                <div className="stat-chip"><div className="v">🔥 {profile.current_streak}</div><div className="k">day streak</div></div>
                <div className="stat-chip"><div className="v">💎 {profile.talent_points}</div><div className="k">talent points</div></div>
                <div className="stat-chip"><div className="v">{profile.total_workouts}</div><div className="k">workouts</div></div>
                <div className="stat-chip"><div className="v">{profile.prestige}</div><div className="k">prestige</div></div>
              </div>
              {profile.friend_code && (
                <div className="muted" style={{ marginTop: 12, fontSize: 14 }}>
                  Friend code: <strong style={{ color: 'var(--text)', letterSpacing: '0.12em' }}>{profile.friend_code}</strong>
                </div>
              )}
              <button className="btn btn-ghost btn-danger" style={{ marginTop: 16 }} onClick={logout}>
                Sign out
              </button>
            </div>
          )}

          {sub === 'talents' && talents && (
            <>
              <div className="card">
                <div className="spread">
                  <h3 style={{ margin: 0 }}>Talent tree</h3>
                  <span className="chip on">💎 {talents.unspent} to spend</span>
                </div>
                <p className="muted" style={{ fontSize: 13 }}>Earn a point every level. Effects apply server-side to your XP.</p>
              </div>
              {talents.tree.branches.map((b) => (
                <div key={b.id} className="card">
                  <div className="eyebrow">{b.name}</div>
                  <div className="stack">
                    {talents.tree.nodes
                      .filter((n) => n.branch === b.id)
                      .sort((a, c) => a.tier - c.tier)
                      .map((n) => {
                        const rank = talents.ranks[n.id] || 0;
                        const maxed = rank >= n.max_rank;
                        return (
                          <div key={n.id} className={`talent-node${rank > 0 ? ' unlocked' : ''}${maxed ? ' maxed' : ''}`}>
                            <div className="spread">
                              <div>
                                <div style={{ fontWeight: 700 }}>{n.name}</div>
                                <div className="muted" style={{ fontSize: 12 }}>{n.description}</div>
                              </div>
                              <span className="chip">{rank}/{n.max_rank}</span>
                            </div>
                            {!maxed && talents.unspent > 0 && (
                              <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={() => spend(n.id)}>
                                Spend point
                              </button>
                            )}
                          </div>
                        );
                      })}
                  </div>
                </div>
              ))}
            </>
          )}

          {sub === 'quests' && quests && (
            <>
              {(['daily', 'weekly'] as const).map((kind) => (
                <div key={kind} className="card">
                  <div className="eyebrow">{kind} quests</div>
                  {quests[kind].length === 0 && <Empty>None right now.</Empty>}
                  <div className="stack">
                    {quests[kind].map((q) => (
                      <div key={q.id}>
                        <div className="spread" style={{ marginBottom: 6 }}>
                          <div>
                            <div style={{ fontWeight: 700, fontSize: 14 }}>{q.title}</div>
                            <div className="muted" style={{ fontSize: 12 }}>{q.description}</div>
                          </div>
                          {q.completed_at && !q.claimed ? (
                            <button className="btn btn-sm btn-primary" onClick={() => claim(q)}>+{q.xp_reward} XP</button>
                          ) : (
                            <span className="muted" style={{ fontSize: 12 }}>
                              {q.claimed ? 'claimed' : `${Math.min(q.progress, q.target)}/${q.target}`}
                            </span>
                          )}
                        </div>
                        {!q.claimed && (
                          <div className="quest-progress">
                            <div style={{ width: `${Math.min(100, (q.progress / Math.max(1, q.target)) * 100)}%` }} />
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              ))}
            </>
          )}

          {sub === 'achievements' && (
            <div className="card">
              <h3>Achievements</h3>
              <div className="stack">
                {achievements.map((a) => (
                  <div key={a.id} className="spread" style={{ opacity: a.unlocked ? 1 : 0.45 }}>
                    <div>
                      <div style={{ fontWeight: 700, fontSize: 14 }}>{a.unlocked ? '🏅' : '🔒'} {a.name}</div>
                      <div className="muted" style={{ fontSize: 12 }}>{a.description}</div>
                    </div>
                  </div>
                ))}
              </div>
              {achievements.length === 0 && <Empty>No achievements yet.</Empty>}
            </div>
          )}

          {sub === 'settings' && (
            <div className="card">
              <h3>Settings</h3>
              <div className="stack">
                <div className="field">
                  <label>Display name</label>
                  <input value={edit.display_name} onChange={(e) => setEdit({ ...edit, display_name: e.target.value })} maxLength={40} />
                </div>
                <div className="field">
                  <label>Training goal</label>
                  <input value={edit.training_goal} onChange={(e) => setEdit({ ...edit, training_goal: e.target.value })} placeholder="Build strength" maxLength={80} />
                </div>
                <div className="field">
                  <label>Units</label>
                  <select value={edit.units} onChange={(e) => setEdit({ ...edit, units: e.target.value })}>
                    <option value="imperial">Imperial (lb)</option>
                    <option value="metric">Metric (kg)</option>
                  </select>
                </div>
                <button className="btn btn-primary" onClick={saveSettings}>Save</button>
              </div>
            </div>
          )}
        </>
      )}
    </>
  );
}
