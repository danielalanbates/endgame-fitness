import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import { useEffect, useState } from 'react';
import { useAuth } from '../auth';
import { apiClaimQuest, apiGetAchievements, apiGetProfile, apiGetQuests, apiGetTalents, apiSpendTalent, apiUpdateProfile, } from '../api';
import { Empty, Loading, LevelBadge, XpBar } from '../components/ui';
export default function Profile({ onToast }) {
    const { user, logout } = useAuth();
    const [sub, setSub] = useState('player');
    const [profile, setProfile] = useState(null);
    const [talents, setTalents] = useState(null);
    const [quests, setQuests] = useState(null);
    const [achievements, setAchievements] = useState([]);
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
            if (sub === 'talents')
                setTalents(await apiGetTalents());
            if (sub === 'quests')
                setQuests(await apiGetQuests());
            if (sub === 'achievements')
                setAchievements((await apiGetAchievements()).achievements);
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
    }, [sub]);
    const spend = async (id) => {
        try {
            const res = await apiSpendTalent(id);
            setTalents(res);
            onToast('Talent point spent');
        }
        catch (e) {
            onToast(e instanceof Error ? e.message : 'Cannot spend there yet');
        }
    };
    const claim = async (q) => {
        try {
            const res = await apiClaimQuest(q.id);
            setQuests((qs) => qs && { daily: qs.daily.map((x) => (x.id === q.id ? res.quest : x)), weekly: qs.weekly.map((x) => (x.id === q.id ? res.quest : x)) });
            onToast(`+${res.xp_gained} XP`);
        }
        catch (e) {
            onToast(e instanceof Error ? e.message : 'Claim failed');
        }
    };
    const saveSettings = async () => {
        try {
            const res = await apiUpdateProfile({
                display_name: edit.display_name.trim() || undefined,
                training_goal: edit.training_goal.trim() || undefined,
                units: edit.units,
            });
            setProfile(res.profile);
            onToast('Profile saved');
        }
        catch (e) {
            onToast(e instanceof Error ? e.message : 'Save failed');
        }
    };
    return (_jsxs(_Fragment, { children: [_jsx("div", { className: "seg", children: ['player', 'talents', 'quests', 'achievements', 'settings'].map((s) => (_jsx("button", { className: sub === s ? 'active' : '', onClick: () => setSub(s), children: s === 'player' ? 'Player' : s[0].toUpperCase() + s.slice(1) }, s))) }), loading ? (_jsx(Loading, {})) : (_jsxs(_Fragment, { children: [sub === 'player' && profile && (_jsxs("div", { className: "card", children: [_jsxs("div", { className: "row", children: [_jsx(LevelBadge, { level: profile.level }), _jsxs("div", { style: { flex: 1 }, children: [_jsx("div", { className: "big", style: { fontSize: 22 }, children: profile.display_name }), _jsx("div", { className: "muted", style: { fontSize: 13 }, children: user?.email })] })] }), _jsx("div", { style: { marginTop: 12 }, children: _jsx(XpBar, { current: profile.xp, min: profile.xp_for_current_level, max: profile.xp_for_next_level }) }), _jsxs("div", { className: "grid2", style: { marginTop: 14 }, children: [_jsxs("div", { className: "stat-chip", children: [_jsxs("div", { className: "v", children: ["\uD83D\uDD25 ", profile.current_streak] }), _jsx("div", { className: "k", children: "day streak" })] }), _jsxs("div", { className: "stat-chip", children: [_jsxs("div", { className: "v", children: ["\uD83D\uDC8E ", profile.talent_points] }), _jsx("div", { className: "k", children: "talent points" })] }), _jsxs("div", { className: "stat-chip", children: [_jsx("div", { className: "v", children: profile.total_workouts }), _jsx("div", { className: "k", children: "workouts" })] }), _jsxs("div", { className: "stat-chip", children: [_jsx("div", { className: "v", children: profile.prestige }), _jsx("div", { className: "k", children: "prestige" })] })] }), profile.friend_code && (_jsxs("div", { className: "muted", style: { marginTop: 12, fontSize: 14 }, children: ["Friend code: ", _jsx("strong", { style: { color: 'var(--text)', letterSpacing: '0.12em' }, children: profile.friend_code })] })), _jsx("button", { className: "btn btn-ghost btn-danger", style: { marginTop: 16 }, onClick: logout, children: "Sign out" })] })), sub === 'talents' && talents && (_jsxs(_Fragment, { children: [_jsxs("div", { className: "card", children: [_jsxs("div", { className: "spread", children: [_jsx("h3", { style: { margin: 0 }, children: "Talent tree" }), _jsxs("span", { className: "chip on", children: ["\uD83D\uDC8E ", talents.unspent, " to spend"] })] }), _jsx("p", { className: "muted", style: { fontSize: 13 }, children: "Earn a point every level. Effects apply server-side to your XP." })] }), talents.tree.branches.map((b) => (_jsxs("div", { className: "card", children: [_jsx("div", { className: "eyebrow", children: b.name }), _jsx("div", { className: "stack", children: talents.tree.nodes
                                            .filter((n) => n.branch === b.id)
                                            .sort((a, c) => a.tier - c.tier)
                                            .map((n) => {
                                            const rank = talents.ranks[n.id] || 0;
                                            const maxed = rank >= n.max_rank;
                                            return (_jsxs("div", { className: `talent-node${rank > 0 ? ' unlocked' : ''}${maxed ? ' maxed' : ''}`, children: [_jsxs("div", { className: "spread", children: [_jsxs("div", { children: [_jsx("div", { style: { fontWeight: 700 }, children: n.name }), _jsx("div", { className: "muted", style: { fontSize: 12 }, children: n.description })] }), _jsxs("span", { className: "chip", children: [rank, "/", n.max_rank] })] }), !maxed && talents.unspent > 0 && (_jsx("button", { className: "btn btn-sm", style: { marginTop: 8 }, onClick: () => spend(n.id), children: "Spend point" }))] }, n.id));
                                        }) })] }, b.id)))] })), sub === 'quests' && quests && (_jsx(_Fragment, { children: ['daily', 'weekly'].map((kind) => (_jsxs("div", { className: "card", children: [_jsxs("div", { className: "eyebrow", children: [kind, " quests"] }), quests[kind].length === 0 && _jsx(Empty, { children: "None right now." }), _jsx("div", { className: "stack", children: quests[kind].map((q) => (_jsxs("div", { children: [_jsxs("div", { className: "spread", style: { marginBottom: 6 }, children: [_jsxs("div", { children: [_jsx("div", { style: { fontWeight: 700, fontSize: 14 }, children: q.title }), _jsx("div", { className: "muted", style: { fontSize: 12 }, children: q.description })] }), q.completed_at && !q.claimed ? (_jsxs("button", { className: "btn btn-sm btn-primary", onClick: () => claim(q), children: ["+", q.xp_reward, " XP"] })) : (_jsx("span", { className: "muted", style: { fontSize: 12 }, children: q.claimed ? 'claimed' : `${Math.min(q.progress, q.target)}/${q.target}` }))] }), !q.claimed && (_jsx("div", { className: "quest-progress", children: _jsx("div", { style: { width: `${Math.min(100, (q.progress / Math.max(1, q.target)) * 100)}%` } }) }))] }, q.id))) })] }, kind))) })), sub === 'achievements' && (_jsxs("div", { className: "card", children: [_jsx("h3", { children: "Achievements" }), _jsx("div", { className: "stack", children: achievements.map((a) => (_jsx("div", { className: "spread", style: { opacity: a.unlocked ? 1 : 0.45 }, children: _jsxs("div", { children: [_jsxs("div", { style: { fontWeight: 700, fontSize: 14 }, children: [a.unlocked ? '🏅' : '🔒', " ", a.name] }), _jsx("div", { className: "muted", style: { fontSize: 12 }, children: a.description })] }) }, a.id))) }), achievements.length === 0 && _jsx(Empty, { children: "No achievements yet." })] })), sub === 'settings' && (_jsxs("div", { className: "card", children: [_jsx("h3", { children: "Settings" }), _jsxs("div", { className: "stack", children: [_jsxs("div", { className: "field", children: [_jsx("label", { children: "Display name" }), _jsx("input", { value: edit.display_name, onChange: (e) => setEdit({ ...edit, display_name: e.target.value }), maxLength: 40 })] }), _jsxs("div", { className: "field", children: [_jsx("label", { children: "Training goal" }), _jsx("input", { value: edit.training_goal, onChange: (e) => setEdit({ ...edit, training_goal: e.target.value }), placeholder: "Build strength", maxLength: 80 })] }), _jsxs("div", { className: "field", children: [_jsx("label", { children: "Units" }), _jsxs("select", { value: edit.units, onChange: (e) => setEdit({ ...edit, units: e.target.value }), children: [_jsx("option", { value: "imperial", children: "Imperial (lb)" }), _jsx("option", { value: "metric", children: "Metric (kg)" })] })] }), _jsx("button", { className: "btn btn-primary", onClick: saveSettings, children: "Save" })] })] }))] }))] }));
}
