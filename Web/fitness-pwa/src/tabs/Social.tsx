import { useEffect, useState } from 'react';
import {
  apiCreateGuild, apiFriendRequest, apiFriendRespond, apiGetFeed, apiGetFriends, apiGetGuild,
  apiGetRaid, apiLeaveGuild, apiLeaderboard, apiReact,
  FeedItem, Friend, Guild, LeaderboardEntry, RaidInfo,
} from '../api';
import { Avatar, Empty, Loading, Sheet, timeAgo } from '../components/ui';

type Sub = 'feed' | 'ranks' | 'friends' | 'guild';

const REACTS = ['💪', '🔥', '👏', '⚔️'];

export default function Social({ onToast }: { onToast: (msg: string) => void }) {
  const [sub, setSub] = useState<Sub>('feed');
  const [feed, setFeed] = useState<FeedItem[]>([]);
  const [entries, setEntries] = useState<LeaderboardEntry[]>([]);
  const [scope, setScope] = useState('global');
  const [metric, setMetric] = useState('xp');
  const [friends, setFriends] = useState<Friend[]>([]);
  const [pendingIn, setPendingIn] = useState<Friend[]>([]);
  const [guild, setGuild] = useState<Guild | null>(null);
  const [raid, setRaid] = useState<RaidInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [addOpen, setAddOpen] = useState(false);
  const [addValue, setAddValue] = useState('');
  const [guildForm, setGuildForm] = useState({ name: '', motto: '' });

  const load = async () => {
    setLoading(true);
    try {
      if (sub === 'feed') setFeed((await apiGetFeed()).items);
      if (sub === 'ranks') setEntries((await apiLeaderboard(scope, metric)).entries);
      if (sub === 'friends') {
        const f = await apiGetFriends();
        setFriends(f.friends);
        setPendingIn(f.pending_in || []);
      }
      if (sub === 'guild') {
        const [g, r] = await Promise.all([apiGetGuild(), apiGetRaid()]);
        setGuild(g.guild);
        setRaid(r.raid);
      }
    } catch (e) {
      onToast(e instanceof Error ? e.message : 'Failed to load');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sub, scope, metric]);

  const react = async (item: FeedItem, emoji: string) => {
    try {
      await apiReact(item.id, emoji);
      setFeed((items) =>
        items.map((it) => {
          if (it.id !== item.id) return it;
          const reactions = [...it.reactions];
          const ix = reactions.findIndex((r) => r.emoji === emoji);
          if (ix >= 0) reactions[ix] = { ...reactions[ix], count: reactions[ix].count + 1 };
          else reactions.push({ emoji, count: 1 });
          return { ...it, reactions };
        }),
      );
    } catch (e) {
      onToast(e instanceof Error ? e.message : 'Reaction failed');
    }
  };

  const sendRequest = async () => {
    const v = addValue.trim();
    if (!v) return;
    try {
      const isEmail = v.includes('@');
      await apiFriendRequest(isEmail ? v : undefined, isEmail ? undefined : v.toUpperCase());
      onToast('Friend request sent');
      setAddValue('');
      setAddOpen(false);
      load();
    } catch (e) {
      onToast(e instanceof Error ? e.message : 'Request failed');
    }
  };

  const respond = async (f: Friend, accept: boolean) => {
    try {
      await apiFriendRespond(f.other_id || f.user_id, accept);
      onToast(accept ? 'Friend added' : 'Request declined');
      load();
    } catch (e) {
      onToast(e instanceof Error ? e.message : 'Failed');
    }
  };

  const createGuild = async () => {
    if (!guildForm.name.trim()) return;
    try {
      const res = await apiCreateGuild(guildForm.name.trim(), guildForm.motto.trim());
      setGuild(res.guild);
      onToast(`Guild "${res.guild.name}" created`);
      setGuildForm({ name: '', motto: '' });
    } catch (e) {
      onToast(e instanceof Error ? e.message : 'Failed');
    }
  };

  return (
    <>
      <div className="seg">
        {(['feed', 'ranks', 'friends', 'guild'] as Sub[]).map((s) => (
          <button key={s} className={sub === s ? 'active' : ''} onClick={() => setSub(s)}>
            {s === 'feed' ? 'Feed' : s === 'ranks' ? 'Ranks' : s === 'friends' ? 'Friends' : 'Guild'}
          </button>
        ))}
      </div>

      {loading ? (
        <Loading />
      ) : (
        <>
          {sub === 'feed' && (
            <div className="card">
              {feed.length === 0 && <Empty>Quiet in here. Add friends and your feed comes alive.</Empty>}
              {feed.map((item) => (
                <div key={item.id} className="feed-item">
                  <div className="row" style={{ alignItems: 'flex-start' }}>
                    <Avatar name={item.display_name} url={item.avatar_url} />
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontSize: 13 }}>
                        <strong>{item.display_name}</strong>{' '}
                        <span className="muted">· Lv {item.level} · {timeAgo(item.created_at)}</span>
                      </div>
                      <div style={{ fontSize: 14, marginTop: 2 }}>{item.summary}</div>
                      <div className="row" style={{ marginTop: 8, gap: 6, flexWrap: 'wrap' }}>
                        {REACTS.map((emoji) => {
                          const count = item.reactions.find((r) => r.emoji === emoji)?.count || 0;
                          return (
                            <button
                              key={emoji}
                              className={`chip${count > 0 ? ' on' : ''}`}
                              onClick={() => react(item, emoji)}
                              aria-label={`React ${emoji}`}
                            >
                              {emoji}{count > 0 && ` ${count}`}
                            </button>
                          );
                        })}
                      </div>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}

          {sub === 'ranks' && (
            <>
              <div className="row">
                <div className="seg" style={{ flex: 1 }}>
                  {['global', 'friends', 'guild'].map((s) => (
                    <button key={s} className={scope === s ? 'active' : ''} onClick={() => setScope(s)}>
                      {s[0].toUpperCase() + s.slice(1)}
                    </button>
                  ))}
                </div>
              </div>
              <div className="seg">
                {(['xp', 'streak', 'volume'] as const).map((m) => (
                  <button key={m} className={metric === m ? 'active' : ''} onClick={() => setMetric(m)}>
                    {m === 'xp' ? 'XP' : m === 'streak' ? 'Streak' : 'Volume'}
                  </button>
                ))}
              </div>
              <div className="card">
                {entries.length === 0 && <Empty>No ranked athletes here yet.</Empty>}
                {entries.map((e) => (
                  <div key={e.user_id} className="feed-item">
                    <div className="row">
                      <span style={{ width: 28, fontWeight: 800, color: e.rank <= 3 ? 'var(--gold)' : 'var(--muted)' }}>
                        {e.rank}
                      </span>
                      <Avatar name={e.display_name} url={e.avatar_url} size={36} />
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontWeight: 700, fontSize: 14 }}>
                          {e.display_name} {e.is_self && <span className="muted">(you)</span>}
                        </div>
                        <div className="muted" style={{ fontSize: 12 }}>Level {e.level}</div>
                      </div>
                      <strong style={{ fontSize: 14 }}>
                        {metric === 'xp' ? e.xp.toLocaleString() : metric === 'streak' ? `🔥 ${e.current_streak}` : `${Math.round(e.total_volume).toLocaleString()} lb`}
                      </strong>
                    </div>
                  </div>
                ))}
              </div>
            </>
          )}

          {sub === 'friends' && (
            <>
              {pendingIn.length > 0 && (
                <div className="card" style={{ borderColor: 'var(--gold)' }}>
                  <h3>Requests</h3>
                  <div className="stack">
                    {pendingIn.map((f) => (
                      <div key={f.other_id || f.user_id} className="spread">
                        <div className="row">
                          <Avatar name={f.display_name} url={f.avatar_url} size={36} />
                          <div>
                            <div style={{ fontWeight: 700, fontSize: 14 }}>{f.display_name}</div>
                            <div className="muted" style={{ fontSize: 12 }}>Level {f.level}</div>
                          </div>
                        </div>
                        <div className="row">
                          <button className="btn btn-sm btn-primary" onClick={() => respond(f, true)}>Add</button>
                          <button className="btn btn-sm btn-ghost" onClick={() => respond(f, false)}>✕</button>
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              )}
              <div className="card">
                <div className="spread" style={{ marginBottom: 8 }}>
                  <h3 style={{ margin: 0 }}>Friends ({friends.length})</h3>
                  <button className="btn btn-sm btn-primary" onClick={() => setAddOpen(true)}>+ Add</button>
                </div>
                {friends.length === 0 && <Empty>Share your friend code from the Home tab.</Empty>}
                {friends.map((f) => (
                  <div key={f.other_id || f.user_id} className="feed-item">
                    <div className="row">
                      <Avatar name={f.display_name} url={f.avatar_url} size={36} />
                      <div style={{ flex: 1 }}>
                        <div style={{ fontWeight: 700, fontSize: 14 }}>{f.display_name}</div>
                        <div className="muted" style={{ fontSize: 12 }}>Lv {f.level} · 🔥 {f.current_streak}</div>
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </>
          )}

          {sub === 'guild' && (
            <>
              {raid && (
                <div className="card">
                  <div className="eyebrow">⚔️ This week's boss — {raid.boss.name}</div>
                  <div className="muted" style={{ fontSize: 13, marginBottom: 8 }}>{raid.boss.flavor}</div>
                  <div className="boss-hp">
                    <div style={{ width: `${Math.min(100, (raid.damage_done / Math.max(1, raid.hp)) * 100)}%` }} />
                  </div>
                  <div className="spread" style={{ marginTop: 8, fontSize: 13 }}>
                    <span><strong>{Math.max(0, raid.hp - raid.damage_done).toLocaleString()}</strong> HP left</span>
                    <span className="muted">your damage: {raid.my_damage.toLocaleString()}</span>
                  </div>
                  {raid.contributors.length > 0 && (
                    <div style={{ marginTop: 10 }}>
                      {raid.contributors.slice(0, 5).map((c) => (
                        <div key={c.user_id} className="spread" style={{ fontSize: 13, padding: '4px 0' }}>
                          <span>#{c.rank} {c.display_name} {c.is_self && '(you)'}</span>
                          <span className="muted">{c.damage.toLocaleString()} dmg</span>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              )}
              {!guild ? (
                <div className="card">
                  <h3>Join the war</h3>
                  <p className="muted" style={{ fontSize: 14 }}>Guilds fight a weekly boss together. Your synced volume is your damage.</p>
                  <div className="stack">
                    <div className="field">
                      <label>New guild name</label>
                      <input value={guildForm.name} onChange={(e) => setGuildForm({ ...guildForm, name: e.target.value })} placeholder="Iron Brotherhood" maxLength={40} />
                    </div>
                    <div className="field">
                      <label>Motto</label>
                      <input value={guildForm.motto} onChange={(e) => setGuildForm({ ...guildForm, motto: e.target.value })} placeholder="Lift heavy, laugh often" maxLength={80} />
                    </div>
                    <button className="btn btn-primary" onClick={createGuild}>Create guild</button>
                  </div>
                </div>
              ) : (
                <div className="card">
                  <div className="spread">
                    <div>
                      <h3 style={{ margin: 0 }}>{guild.name}</h3>
                      {guild.motto && <div className="muted" style={{ fontSize: 13 }}>"{guild.motto}"</div>}
                    </div>
                    {!guild.is_owner && (
                      <button className="btn btn-sm btn-ghost" onClick={async () => { await apiLeaveGuild(); load(); }}>Leave</button>
                    )}
                  </div>
                  <div style={{ marginTop: 10 }} className="stack">
                    {(guild.members || []).map((m) => (
                      <div key={m.user_id} className="spread" style={{ fontSize: 14 }}>
                        <span><strong>{m.display_name}</strong> <span className="muted">· Lv {m.level}</span></span>
                        <span className="chip">{m.role}</span>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </>
          )}
        </>
      )}

      {addOpen && (
        <Sheet onClose={() => setAddOpen(false)} title="Add a friend">
          <div className="stack">
            <div className="field">
              <label>Email or friend code</label>
              <input
                value={addValue}
                onChange={(e) => setAddValue(e.target.value)}
                placeholder="friend@example.com or AB12CD"
                autoCapitalize="none"
                onKeyDown={(e) => e.key === 'Enter' && sendRequest()}
              />
            </div>
            <button className="btn btn-primary" onClick={sendRequest}>Send request</button>
          </div>
        </Sheet>
      )}
    </>
  );
}
