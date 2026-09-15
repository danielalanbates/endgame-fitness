import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import { useEffect, useState } from 'react';
import { apiClaimQuest, apiGetProfile, apiGetQuests, apiGetRaid } from '../api';
import { Avatar, Empty, Loading, LevelBadge, StatChip, XpBar, fmtVolume } from '../components/ui';
import { useAuth } from '../auth';
function rankTitle(level) {
    if (level < 5)
        return 'Initiate';
    if (level < 10)
        return 'Apprentice';
    if (level < 20)
        return 'Iron Disciple';
    if (level < 30)
        return 'Ironbound';
    if (level < 45)
        return 'Vanguard';
    if (level < 60)
        return 'Warbringer';
    if (level < 80)
        return 'Champion';
    if (level < 100)
        return 'Ascendant';
    return 'Endgame';
}
export default function Home({ onToast }) {
    const { user } = useAuth();
    const [profile, setProfile] = useState(null);
    const [quests, setQuests] = useState([]);
    const [raid, setRaid] = useState(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState(null);
    const load = async () => {
        setLoading(true);
        setError(null);
        try {
            const [p, q, r] = await Promise.all([apiGetProfile(), apiGetQuests(), apiGetRaid()]);
            setProfile(p.profile);
            setQuests([...q.daily, ...q.weekly]);
            setRaid(r.raid);
        }
        catch (e) {
            setError(e instanceof Error ? e.message : 'Failed to load');
        }
        finally {
            setLoading(false);
        }
    };
    useEffect(() => {
        load();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);
    const claim = async (quest) => {
        try {
            const res = await apiClaimQuest(quest.id);
            setQuests((qs) => qs.map((x) => (x.id === quest.id ? res.quest : x)));
            onToast(`+${res.xp_gained} XP claimed${res.levels_gained > 0 ? ` — LEVEL UP to ${profile ? profile.level + res.levels_gained : ''}!` : ''}`);
            const p = await apiGetProfile();
            setProfile(p.profile);
        }
        catch (e) {
            onToast(e instanceof Error ? e.message : 'Claim failed');
        }
    };
    if (loading)
        return _jsx(Loading, { label: "Loading your profile\u2026" });
    if (error)
        return (_jsxs("div", { className: "card", children: [_jsx("p", { className: "muted", children: error }), _jsx("button", { className: "btn", onClick: load, children: "Retry" })] }));
    if (!profile)
        return _jsx(Empty, { children: "No profile found." });
    const claimable = quests.filter((q) => q.completed_at && !q.claimed);
    const active = quests.filter((q) => !q.completed_at).slice(0, 4);
    return (_jsxs(_Fragment, { children: [_jsxs("div", { className: "card", children: [_jsxs("div", { className: "row", children: [_jsx(LevelBadge, { level: profile.level }), _jsxs("div", { style: { flex: 1, minWidth: 0 }, children: [_jsx("div", { className: "eyebrow", children: profile.title || rankTitle(profile.level) }), _jsx("div", { className: "big", style: { fontSize: 22 }, children: profile.display_name }), _jsxs("div", { className: "muted", style: { fontSize: 13 }, children: [Math.max(0, profile.xp - profile.xp_for_current_level).toLocaleString(), " /", ' ', Math.max(1, profile.xp_for_next_level - profile.xp_for_current_level).toLocaleString(), " XP"] })] })] }), _jsx("div", { style: { marginTop: 12 }, children: _jsx(XpBar, { current: profile.xp, min: profile.xp_for_current_level, max: profile.xp_for_next_level }) }), _jsxs("div", { className: "grid2", style: { marginTop: 14 }, children: [_jsx(StatChip, { value: `🔥 ${profile.current_streak}`, label: `day streak · best ${profile.longest_streak}` }), _jsx(StatChip, { value: `💎 ${profile.talent_points}`, label: "talent points" }), _jsx(StatChip, { value: fmtVolume(profile.total_volume), label: "lb moved all-time" }), _jsx(StatChip, { value: `${profile.total_workouts}`, label: "workouts logged" })] }), profile.friend_code && (_jsxs("div", { className: "muted", style: { marginTop: 12, fontSize: 13 }, children: ["Friend code: ", _jsx("strong", { style: { color: 'var(--text)', letterSpacing: '0.1em' }, children: profile.friend_code })] }))] }), raid && (_jsxs("div", { className: "card", children: [_jsxs("div", { className: "eyebrow", children: ["\u2694\uFE0F Guild raid \u2014 ", raid.boss.name] }), _jsxs("div", { className: "spread", style: { marginBottom: 8 }, children: [_jsxs("span", { style: { fontSize: 15, fontWeight: 700 }, children: [Math.max(0, raid.hp - raid.damage_done).toLocaleString(), " / ", raid.hp.toLocaleString(), " HP"] }), _jsx("span", { className: "muted", style: { fontSize: 12 }, children: raid.defeated ? 'Defeated!' : `${Math.ceil(raid.seconds_left / 3600)}h left` })] }), _jsx("div", { className: "boss-hp", children: _jsx("div", { style: { width: `${Math.min(100, (raid.damage_done / Math.max(1, raid.hp)) * 100)}%` } }) }), _jsxs("div", { className: "muted", style: { marginTop: 8, fontSize: 13 }, children: ["Your damage: ", _jsx("strong", { style: { color: 'var(--text)' }, children: raid.my_damage.toLocaleString() }), " \u00B7 ", raid.member_count, " members in the fight"] })] })), claimable.length > 0 && (_jsxs("div", { className: "card", style: { borderColor: 'var(--gold)' }, children: [_jsx("h3", { children: "\uD83C\uDF81 Rewards ready" }), _jsx("div", { className: "stack", children: claimable.map((q) => (_jsxs("div", { className: "spread", children: [_jsxs("div", { children: [_jsx("div", { style: { fontWeight: 700 }, children: q.title }), _jsxs("div", { className: "muted", style: { fontSize: 12 }, children: ["+", q.xp_reward, " XP"] })] }), _jsx("button", { className: "btn btn-sm btn-primary", onClick: () => claim(q), children: "Claim" })] }, q.id))) })] })), _jsxs("div", { className: "card", children: [_jsxs("div", { className: "spread", children: [_jsx("h3", { style: { margin: 0 }, children: "Quests" }), _jsxs("span", { className: "muted", style: { fontSize: 12 }, children: [quests.filter((q) => q.completed_at && !q.claimed).length, " to claim"] })] }), active.length === 0 && _jsx(Empty, { children: "All quests clear. New ones arrive daily." }), _jsx("div", { className: "stack", children: active.map((q) => (_jsxs("div", { children: [_jsxs("div", { className: "spread", style: { marginBottom: 6 }, children: [_jsx("span", { style: { fontWeight: 600, fontSize: 14 }, children: q.title }), _jsxs("span", { className: "muted", style: { fontSize: 12 }, children: [Math.min(q.progress, q.target), "/", q.target] })] }), _jsx("div", { className: "quest-progress", children: _jsx("div", { style: { width: `${Math.min(100, (q.progress / Math.max(1, q.target)) * 100)}%` } }) })] }, q.id))) })] }), _jsx("div", { className: "card", children: _jsxs("div", { className: "row", children: [_jsx(Avatar, { name: user?.name || profile.display_name, url: user?.avatar_url }), _jsxs("div", { children: [_jsx("div", { style: { fontWeight: 700 }, children: user?.name || profile.display_name }), _jsxs("div", { className: "muted", style: { fontSize: 13 }, children: [user?.email, " \u00B7 ", user?.membership === 'premium' ? '⭐ Premium' : 'Free', " membership"] })] })] }) })] }));
}
