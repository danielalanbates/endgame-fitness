import { useEffect, useState } from 'react';
import { apiClaimQuest, apiGetProfile, apiGetQuests, apiGetRaid, FitnessProfile, Quest, RaidInfo } from '../api';
import { Avatar, Empty, Loading, LevelBadge, StatChip, XpBar, fmtVolume } from '../components/ui';
import { useAuth } from '../auth';

function rankTitle(level: number): string {
  if (level < 5) return 'Initiate';
  if (level < 10) return 'Apprentice';
  if (level < 20) return 'Iron Disciple';
  if (level < 30) return 'Ironbound';
  if (level < 45) return 'Vanguard';
  if (level < 60) return 'Warbringer';
  if (level < 80) return 'Champion';
  if (level < 100) return 'Ascendant';
  return 'Endgame';
}

export default function Home({ onToast }: { onToast: (msg: string) => void }) {
  const { user } = useAuth();
  const [profile, setProfile] = useState<FitnessProfile | null>(null);
  const [quests, setQuests] = useState<Quest[]>([]);
  const [raid, setRaid] = useState<RaidInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = async () => {
    setLoading(true);
    setError(null);
    try {
      const [p, q, r] = await Promise.all([apiGetProfile(), apiGetQuests(), apiGetRaid()]);
      setProfile(p.profile);
      setQuests([...q.daily, ...q.weekly]);
      setRaid(r.raid);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const claim = async (quest: Quest) => {
    try {
      const res = await apiClaimQuest(quest.id);
      setQuests((qs) => qs.map((x) => (x.id === quest.id ? res.quest : x)));
      onToast(`+${res.xp_gained} XP claimed${res.levels_gained > 0 ? ` — LEVEL UP to ${profile ? profile.level + res.levels_gained : ''}!` : ''}`);
      const p = await apiGetProfile();
      setProfile(p.profile);
    } catch (e) {
      onToast(e instanceof Error ? e.message : 'Claim failed');
    }
  };

  if (loading) return <Loading label="Loading your profile…" />;
  if (error)
    return (
      <div className="card">
        <p className="muted">{error}</p>
        <button className="btn" onClick={load}>Retry</button>
      </div>
    );
  if (!profile) return <Empty>No profile found.</Empty>;

  const claimable = quests.filter((q) => q.completed_at && !q.claimed);
  const active = quests.filter((q) => !q.completed_at).slice(0, 4);

  return (
    <>
      <div className="card">
        <div className="row">
          <LevelBadge level={profile.level} />
          <div style={{ flex: 1, minWidth: 0 }}>
            <div className="eyebrow">{profile.title || rankTitle(profile.level)}</div>
            <div className="big" style={{ fontSize: 22 }}>{profile.display_name}</div>
            <div className="muted" style={{ fontSize: 13 }}>
              {Math.max(0, profile.xp - profile.xp_for_current_level).toLocaleString()} /{' '}
              {Math.max(1, profile.xp_for_next_level - profile.xp_for_current_level).toLocaleString()} XP
            </div>
          </div>
        </div>
        <div style={{ marginTop: 12 }}>
          <XpBar current={profile.xp} min={profile.xp_for_current_level} max={profile.xp_for_next_level} />
        </div>
        <div className="grid2" style={{ marginTop: 14 }}>
          <StatChip value={`🔥 ${profile.current_streak}`} label={`day streak · best ${profile.longest_streak}`} />
          <StatChip value={`💎 ${profile.talent_points}`} label="talent points" />
          <StatChip value={fmtVolume(profile.total_volume)} label="lb moved all-time" />
          <StatChip value={`${profile.total_workouts}`} label="workouts logged" />
        </div>
        {profile.friend_code && (
          <div className="muted" style={{ marginTop: 12, fontSize: 13 }}>
            Friend code: <strong style={{ color: 'var(--text)', letterSpacing: '0.1em' }}>{profile.friend_code}</strong>
          </div>
        )}
      </div>

      {raid && (
        <div className="card">
          <div className="eyebrow">⚔️ Guild raid — {raid.boss.name}</div>
          <div className="spread" style={{ marginBottom: 8 }}>
            <span style={{ fontSize: 15, fontWeight: 700 }}>
              {Math.max(0, raid.hp - raid.damage_done).toLocaleString()} / {raid.hp.toLocaleString()} HP
            </span>
            <span className="muted" style={{ fontSize: 12 }}>
              {raid.defeated ? 'Defeated!' : `${Math.ceil(raid.seconds_left / 3600)}h left`}
            </span>
          </div>
          <div className="boss-hp">
            <div style={{ width: `${Math.min(100, (raid.damage_done / Math.max(1, raid.hp)) * 100)}%` }} />
          </div>
          <div className="muted" style={{ marginTop: 8, fontSize: 13 }}>
            Your damage: <strong style={{ color: 'var(--text)' }}>{raid.my_damage.toLocaleString()}</strong> · {raid.member_count} members in the fight
          </div>
        </div>
      )}

      {claimable.length > 0 && (
        <div className="card" style={{ borderColor: 'var(--gold)' }}>
          <h3>🎁 Rewards ready</h3>
          <div className="stack">
            {claimable.map((q) => (
              <div key={q.id} className="spread">
                <div>
                  <div style={{ fontWeight: 700 }}>{q.title}</div>
                  <div className="muted" style={{ fontSize: 12 }}>+{q.xp_reward} XP</div>
                </div>
                <button className="btn btn-sm btn-primary" onClick={() => claim(q)}>Claim</button>
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="card">
        <div className="spread">
          <h3 style={{ margin: 0 }}>Quests</h3>
          <span className="muted" style={{ fontSize: 12 }}>{quests.filter((q) => q.completed_at && !q.claimed).length} to claim</span>
        </div>
        {active.length === 0 && <Empty>All quests clear. New ones arrive daily.</Empty>}
        <div className="stack">
          {active.map((q) => (
            <div key={q.id}>
              <div className="spread" style={{ marginBottom: 6 }}>
                <span style={{ fontWeight: 600, fontSize: 14 }}>{q.title}</span>
                <span className="muted" style={{ fontSize: 12 }}>
                  {Math.min(q.progress, q.target)}/{q.target}
                </span>
              </div>
              <div className="quest-progress">
                <div style={{ width: `${Math.min(100, (q.progress / Math.max(1, q.target)) * 100)}%` }} />
              </div>
            </div>
          ))}
        </div>
      </div>

      <div className="card">
        <div className="row">
          <Avatar name={user?.name || profile.display_name} url={user?.avatar_url} />
          <div>
            <div style={{ fontWeight: 700 }}>{user?.name || profile.display_name}</div>
            <div className="muted" style={{ fontSize: 13 }}>
              {user?.email} · {user?.membership === 'premium' ? '⭐ Premium' : 'Free'} membership
            </div>
          </div>
        </div>
      </div>
    </>
  );
}
