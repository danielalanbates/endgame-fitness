import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import { useEffect, useState } from 'react';
import { apiCreateGuild, apiFriendRequest, apiFriendRespond, apiGetFeed, apiGetFriends, apiGetGuild, apiGetRaid, apiLeaveGuild, apiLeaderboard, apiReact, } from '../api';
import { Avatar, Empty, Loading, Sheet, timeAgo } from '../components/ui';
const REACTS = ['💪', '🔥', '👏', '⚔️'];
export default function Social({ onToast }) {
    const [sub, setSub] = useState('feed');
    const [feed, setFeed] = useState([]);
    const [entries, setEntries] = useState([]);
    const [scope, setScope] = useState('global');
    const [metric, setMetric] = useState('xp');
    const [friends, setFriends] = useState([]);
    const [pendingIn, setPendingIn] = useState([]);
    const [guild, setGuild] = useState(null);
    const [raid, setRaid] = useState(null);
    const [loading, setLoading] = useState(true);
    const [addOpen, setAddOpen] = useState(false);
    const [addValue, setAddValue] = useState('');
    const [guildForm, setGuildForm] = useState({ name: '', motto: '' });
    const load = async () => {
        setLoading(true);
        try {
            if (sub === 'feed')
                setFeed((await apiGetFeed()).items);
            if (sub === 'ranks')
                setEntries((await apiLeaderboard(scope, metric)).entries);
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
        }
        catch (e) {
            onToast(e instanceof Error ? e.message : 'Failed to load');
        }
        finally {
            setLoading(false);
        }
    };
    useEffect(() => {
        load();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [sub, scope, metric]);
    const react = async (item, emoji) => {
        try {
            await apiReact(item.id, emoji);
            setFeed((items) => items.map((it) => {
                if (it.id !== item.id)
                    return it;
                const reactions = [...it.reactions];
                const ix = reactions.findIndex((r) => r.emoji === emoji);
                if (ix >= 0)
                    reactions[ix] = { ...reactions[ix], count: reactions[ix].count + 1 };
                else
                    reactions.push({ emoji, count: 1 });
                return { ...it, reactions };
            }));
        }
        catch (e) {
            onToast(e instanceof Error ? e.message : 'Reaction failed');
        }
    };
    const sendRequest = async () => {
        const v = addValue.trim();
        if (!v)
            return;
        try {
            const isEmail = v.includes('@');
            await apiFriendRequest(isEmail ? v : undefined, isEmail ? undefined : v.toUpperCase());
            onToast('Friend request sent');
            setAddValue('');
            setAddOpen(false);
            load();
        }
        catch (e) {
            onToast(e instanceof Error ? e.message : 'Request failed');
        }
    };
    const respond = async (f, accept) => {
        try {
            await apiFriendRespond(f.other_id || f.user_id, accept);
            onToast(accept ? 'Friend added' : 'Request declined');
            load();
        }
        catch (e) {
            onToast(e instanceof Error ? e.message : 'Failed');
        }
    };
    const createGuild = async () => {
        if (!guildForm.name.trim())
            return;
        try {
            const res = await apiCreateGuild(guildForm.name.trim(), guildForm.motto.trim());
            setGuild(res.guild);
            onToast(`Guild "${res.guild.name}" created`);
            setGuildForm({ name: '', motto: '' });
        }
        catch (e) {
            onToast(e instanceof Error ? e.message : 'Failed');
        }
    };
    return (_jsxs(_Fragment, { children: [_jsx("div", { className: "seg", children: ['feed', 'ranks', 'friends', 'guild'].map((s) => (_jsx("button", { className: sub === s ? 'active' : '', onClick: () => setSub(s), children: s === 'feed' ? 'Feed' : s === 'ranks' ? 'Ranks' : s === 'friends' ? 'Friends' : 'Guild' }, s))) }), loading ? (_jsx(Loading, {})) : (_jsxs(_Fragment, { children: [sub === 'feed' && (_jsxs("div", { className: "card", children: [feed.length === 0 && _jsx(Empty, { children: "Quiet in here. Add friends and your feed comes alive." }), feed.map((item) => (_jsx("div", { className: "feed-item", children: _jsxs("div", { className: "row", style: { alignItems: 'flex-start' }, children: [_jsx(Avatar, { name: item.display_name, url: item.avatar_url }), _jsxs("div", { style: { flex: 1, minWidth: 0 }, children: [_jsxs("div", { style: { fontSize: 13 }, children: [_jsx("strong", { children: item.display_name }), ' ', _jsxs("span", { className: "muted", children: ["\u00B7 Lv ", item.level, " \u00B7 ", timeAgo(item.created_at)] })] }), _jsx("div", { style: { fontSize: 14, marginTop: 2 }, children: item.summary }), _jsx("div", { className: "row", style: { marginTop: 8, gap: 6, flexWrap: 'wrap' }, children: REACTS.map((emoji) => {
                                                        const count = item.reactions.find((r) => r.emoji === emoji)?.count || 0;
                                                        return (_jsxs("button", { className: `chip${count > 0 ? ' on' : ''}`, onClick: () => react(item, emoji), "aria-label": `React ${emoji}`, children: [emoji, count > 0 && ` ${count}`] }, emoji));
                                                    }) })] })] }) }, item.id)))] })), sub === 'ranks' && (_jsxs(_Fragment, { children: [_jsx("div", { className: "row", children: _jsx("div", { className: "seg", style: { flex: 1 }, children: ['global', 'friends', 'guild'].map((s) => (_jsx("button", { className: scope === s ? 'active' : '', onClick: () => setScope(s), children: s[0].toUpperCase() + s.slice(1) }, s))) }) }), _jsx("div", { className: "seg", children: ['xp', 'streak', 'volume'].map((m) => (_jsx("button", { className: metric === m ? 'active' : '', onClick: () => setMetric(m), children: m === 'xp' ? 'XP' : m === 'streak' ? 'Streak' : 'Volume' }, m))) }), _jsxs("div", { className: "card", children: [entries.length === 0 && _jsx(Empty, { children: "No ranked athletes here yet." }), entries.map((e) => (_jsx("div", { className: "feed-item", children: _jsxs("div", { className: "row", children: [_jsx("span", { style: { width: 28, fontWeight: 800, color: e.rank <= 3 ? 'var(--gold)' : 'var(--muted)' }, children: e.rank }), _jsx(Avatar, { name: e.display_name, url: e.avatar_url, size: 36 }), _jsxs("div", { style: { flex: 1, minWidth: 0 }, children: [_jsxs("div", { style: { fontWeight: 700, fontSize: 14 }, children: [e.display_name, " ", e.is_self && _jsx("span", { className: "muted", children: "(you)" })] }), _jsxs("div", { className: "muted", style: { fontSize: 12 }, children: ["Level ", e.level] })] }), _jsx("strong", { style: { fontSize: 14 }, children: metric === 'xp' ? e.xp.toLocaleString() : metric === 'streak' ? `🔥 ${e.current_streak}` : `${Math.round(e.total_volume).toLocaleString()} lb` })] }) }, e.user_id)))] })] })), sub === 'friends' && (_jsxs(_Fragment, { children: [pendingIn.length > 0 && (_jsxs("div", { className: "card", style: { borderColor: 'var(--gold)' }, children: [_jsx("h3", { children: "Requests" }), _jsx("div", { className: "stack", children: pendingIn.map((f) => (_jsxs("div", { className: "spread", children: [_jsxs("div", { className: "row", children: [_jsx(Avatar, { name: f.display_name, url: f.avatar_url, size: 36 }), _jsxs("div", { children: [_jsx("div", { style: { fontWeight: 700, fontSize: 14 }, children: f.display_name }), _jsxs("div", { className: "muted", style: { fontSize: 12 }, children: ["Level ", f.level] })] })] }), _jsxs("div", { className: "row", children: [_jsx("button", { className: "btn btn-sm btn-primary", onClick: () => respond(f, true), children: "Add" }), _jsx("button", { className: "btn btn-sm btn-ghost", onClick: () => respond(f, false), children: "\u2715" })] })] }, f.other_id || f.user_id))) })] })), _jsxs("div", { className: "card", children: [_jsxs("div", { className: "spread", style: { marginBottom: 8 }, children: [_jsxs("h3", { style: { margin: 0 }, children: ["Friends (", friends.length, ")"] }), _jsx("button", { className: "btn btn-sm btn-primary", onClick: () => setAddOpen(true), children: "+ Add" })] }), friends.length === 0 && _jsx(Empty, { children: "Share your friend code from the Home tab." }), friends.map((f) => (_jsx("div", { className: "feed-item", children: _jsxs("div", { className: "row", children: [_jsx(Avatar, { name: f.display_name, url: f.avatar_url, size: 36 }), _jsxs("div", { style: { flex: 1 }, children: [_jsx("div", { style: { fontWeight: 700, fontSize: 14 }, children: f.display_name }), _jsxs("div", { className: "muted", style: { fontSize: 12 }, children: ["Lv ", f.level, " \u00B7 \uD83D\uDD25 ", f.current_streak] })] })] }) }, f.other_id || f.user_id)))] })] })), sub === 'guild' && (_jsxs(_Fragment, { children: [raid && (_jsxs("div", { className: "card", children: [_jsxs("div", { className: "eyebrow", children: ["\u2694\uFE0F This week's boss \u2014 ", raid.boss.name] }), _jsx("div", { className: "muted", style: { fontSize: 13, marginBottom: 8 }, children: raid.boss.flavor }), _jsx("div", { className: "boss-hp", children: _jsx("div", { style: { width: `${Math.min(100, (raid.damage_done / Math.max(1, raid.hp)) * 100)}%` } }) }), _jsxs("div", { className: "spread", style: { marginTop: 8, fontSize: 13 }, children: [_jsxs("span", { children: [_jsx("strong", { children: Math.max(0, raid.hp - raid.damage_done).toLocaleString() }), " HP left"] }), _jsxs("span", { className: "muted", children: ["your damage: ", raid.my_damage.toLocaleString()] })] }), raid.contributors.length > 0 && (_jsx("div", { style: { marginTop: 10 }, children: raid.contributors.slice(0, 5).map((c) => (_jsxs("div", { className: "spread", style: { fontSize: 13, padding: '4px 0' }, children: [_jsxs("span", { children: ["#", c.rank, " ", c.display_name, " ", c.is_self && '(you)'] }), _jsxs("span", { className: "muted", children: [c.damage.toLocaleString(), " dmg"] })] }, c.user_id))) }))] })), !guild ? (_jsxs("div", { className: "card", children: [_jsx("h3", { children: "Join the war" }), _jsx("p", { className: "muted", style: { fontSize: 14 }, children: "Guilds fight a weekly boss together. Your synced volume is your damage." }), _jsxs("div", { className: "stack", children: [_jsxs("div", { className: "field", children: [_jsx("label", { children: "New guild name" }), _jsx("input", { value: guildForm.name, onChange: (e) => setGuildForm({ ...guildForm, name: e.target.value }), placeholder: "Iron Brotherhood", maxLength: 40 })] }), _jsxs("div", { className: "field", children: [_jsx("label", { children: "Motto" }), _jsx("input", { value: guildForm.motto, onChange: (e) => setGuildForm({ ...guildForm, motto: e.target.value }), placeholder: "Lift heavy, laugh often", maxLength: 80 })] }), _jsx("button", { className: "btn btn-primary", onClick: createGuild, children: "Create guild" })] })] })) : (_jsxs("div", { className: "card", children: [_jsxs("div", { className: "spread", children: [_jsxs("div", { children: [_jsx("h3", { style: { margin: 0 }, children: guild.name }), guild.motto && _jsxs("div", { className: "muted", style: { fontSize: 13 }, children: ["\"", guild.motto, "\""] })] }), !guild.is_owner && (_jsx("button", { className: "btn btn-sm btn-ghost", onClick: async () => { await apiLeaveGuild(); load(); }, children: "Leave" }))] }), _jsx("div", { style: { marginTop: 10 }, className: "stack", children: (guild.members || []).map((m) => (_jsxs("div", { className: "spread", style: { fontSize: 14 }, children: [_jsxs("span", { children: [_jsx("strong", { children: m.display_name }), " ", _jsxs("span", { className: "muted", children: ["\u00B7 Lv ", m.level] })] }), _jsx("span", { className: "chip", children: m.role })] }, m.user_id))) })] }))] }))] })), addOpen && (_jsx(Sheet, { onClose: () => setAddOpen(false), title: "Add a friend", children: _jsxs("div", { className: "stack", children: [_jsxs("div", { className: "field", children: [_jsx("label", { children: "Email or friend code" }), _jsx("input", { value: addValue, onChange: (e) => setAddValue(e.target.value), placeholder: "friend@example.com or AB12CD", autoCapitalize: "none", onKeyDown: (e) => e.key === 'Enter' && sendRequest() })] }), _jsx("button", { className: "btn btn-primary", onClick: sendRequest, children: "Send request" })] }) }))] }));
}
