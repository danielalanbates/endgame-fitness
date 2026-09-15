import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import { useEffect, useMemo, useState } from 'react';
import { apiGetProfile, apiSync } from '../api';
import { Empty, Loading } from '../components/ui';
function weekKey(epochSecs) {
    const d = new Date(epochSecs * 1000);
    const day = (d.getDay() + 6) % 7; // Monday = 0
    d.setDate(d.getDate() - day);
    return d.toISOString().slice(0, 10);
}
export default function Progress() {
    const [sessions, setSessions] = useState([]);
    const [prs, setPrs] = useState([]);
    const [loading, setLoading] = useState(true);
    useEffect(() => {
        (async () => {
            try {
                const [syncRes, prof] = await Promise.all([
                    apiSync([], 0),
                    apiGetProfile(),
                ]);
                const rows = syncRes.sessions.sort((a, b) => b.performed_at - a.performed_at);
                setSessions(rows);
                setPrs(prof.personal_records.sort((a, b) => b.weight - a.weight));
            }
            catch {
                /* leave empty */
            }
            finally {
                setLoading(false);
            }
        })();
    }, []);
    const weeks = useMemo(() => {
        const map = new Map();
        for (const s of sessions) {
            const k = weekKey(s.performed_at);
            map.set(k, (map.get(k) || 0) + (s.total_volume || 0));
        }
        const keys = [...map.keys()].sort().slice(-12);
        const max = Math.max(1, ...keys.map((k) => map.get(k)));
        return keys.map((k) => ({ key: k, volume: map.get(k), pct: (map.get(k) / max) * 100 }));
    }, [sessions]);
    if (loading)
        return _jsx(Loading, { label: "Loading your history\u2026" });
    return (_jsxs(_Fragment, { children: [_jsxs("div", { className: "card", children: [_jsxs("h3", { children: ["Volume \u2014 last ", weeks.length, " weeks"] }), weeks.length === 0 ? (_jsx(Empty, { children: "Log your first workout and the chart fills in here." })) : (_jsx("div", { style: { display: 'flex', alignItems: 'flex-end', gap: 6, height: 120 }, children: weeks.map((w) => (_jsxs("div", { style: { flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4, height: '100%', justifyContent: 'flex-end' }, children: [_jsx("div", { title: `${w.key}: ${Math.round(w.volume).toLocaleString()} lb`, style: {
                                        width: '100%',
                                        height: `${Math.max(4, w.pct)}%`,
                                        borderRadius: 6,
                                        background: 'linear-gradient(180deg, var(--accent), #3a2a8f)',
                                    } }), _jsx("span", { className: "muted", style: { fontSize: 9 }, children: w.key.slice(5).replace('-', '/') })] }, w.key))) }))] }), prs.length > 0 && (_jsxs("div", { className: "card", children: [_jsx("h3", { children: "\uD83C\uDFC6 Personal records" }), _jsx("div", { className: "stack", children: prs.slice(0, 10).map((pr, i) => (_jsxs("div", { className: "spread", children: [_jsx("span", { style: { fontWeight: 600 }, children: pr.exercise }), _jsxs("span", { className: "muted", style: { fontSize: 13 }, children: [pr.weight, " lb \u00D7 ", pr.reps] })] }, i))) })] })), _jsxs("div", { className: "card", children: [_jsx("h3", { children: "History" }), sessions.length === 0 && _jsx(Empty, { children: "No workouts yet \u2014 your history lives here." }), _jsx("div", { children: sessions.slice(0, 30).map((s) => (_jsxs("div", { className: "feed-item", children: [_jsxs("div", { className: "spread", children: [_jsxs("div", { children: [_jsx("div", { style: { fontWeight: 700 }, children: s.name || 'Workout' }), _jsxs("div", { className: "muted", style: { fontSize: 12 }, children: [new Date(s.performed_at * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }), " \u00B7", ' ', Math.round(s.total_volume).toLocaleString(), " lb \u00B7 ", s.total_reps, " reps"] })] }), _jsxs("span", { className: "chip", children: ["+", s.xp_earned, " XP"] })] }), s.payload?.exercises && s.payload.exercises.length > 0 && (_jsxs("div", { className: "muted", style: { fontSize: 12, marginTop: 4 }, children: [s.payload.exercises.slice(0, 4).map((e) => e.name).join(' · '), s.payload.exercises.length > 4 && ` +${s.payload.exercises.length - 4} more`] }))] }, s.id))) })] })] }));
}
