import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import { useEffect, useMemo, useRef, useState } from 'react';
import { apiSync } from '../api';
const QUEUE_KEY = 'ef_pending_sessions';
const LAST_SYNC_KEY = 'ef_last_sync';
function loadQueue() {
    try {
        return JSON.parse(localStorage.getItem(QUEUE_KEY) || '[]');
    }
    catch {
        return [];
    }
}
function saveQueue(q) {
    try {
        localStorage.setItem(QUEUE_KEY, JSON.stringify(q));
    }
    catch {
        /* ignore */
    }
}
function uuid() {
    if (typeof crypto !== 'undefined' && 'randomUUID' in crypto)
        return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
        const r = (Math.random() * 16) | 0;
        return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
    });
}
export default function Workout({ onToast, onSynced }) {
    const [exercises, setExercises] = useState([]);
    const [sessionName, setSessionName] = useState('');
    const [active, setActive] = useState(false);
    const [startTime, setStartTime] = useState(0);
    const [elapsed, setElapsed] = useState(0);
    const [newExName, setNewExName] = useState('');
    const [finishing, setFinishing] = useState(false);
    const [pending, setPending] = useState(loadQueue);
    const timerRef = useRef(null);
    useEffect(() => {
        if (active) {
            timerRef.current = window.setInterval(() => setElapsed(Math.floor((Date.now() - startTime) / 1000)), 1000);
        }
        return () => {
            if (timerRef.current)
                window.clearInterval(timerRef.current);
        };
    }, [active, startTime]);
    const totals = useMemo(() => {
        let volume = 0;
        let reps = 0;
        for (const ex of exercises) {
            for (const s of ex.sets) {
                if (!s.done)
                    continue;
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
        if (!name)
            return;
        setExercises((xs) => [...xs, { name, sets: [{ reps: 8, weight: 0, done: false }] }]);
        setNewExName('');
    };
    const addSet = (i) => {
        setExercises((xs) => xs.map((ex, j) => {
            if (j !== i)
                return ex;
            const last = ex.sets[ex.sets.length - 1];
            return { ...ex, sets: [...ex.sets, { reps: last?.reps ?? 8, weight: last?.weight ?? 0, done: false }] };
        }));
    };
    const updateSet = (i, k, patch) => {
        setExercises((xs) => xs.map((ex, j) => (j === i ? { ...ex, sets: ex.sets.map((s, l) => (l === k ? { ...s, ...patch } : s)) } : ex)));
    };
    const removeExercise = (i) => setExercises((xs) => xs.filter((_, j) => j !== i));
    const flushQueue = async (extra) => {
        const batch = [...loadQueue(), ...extra];
        if (batch.length === 0)
            return null;
        const since = Number(localStorage.getItem(LAST_SYNC_KEY) || 0);
        const res = await apiSync(batch, since);
        const accepted = new Set(res.accepted);
        const remaining = batch.filter((s) => !accepted.has(s.id));
        saveQueue(remaining);
        setPending(remaining);
        localStorage.setItem(LAST_SYNC_KEY, String(res.server_time));
        return res;
    };
    const finish = async () => {
        if (totals.reps === 0) {
            onToast('Log at least one completed set first.');
            return;
        }
        setFinishing(true);
        const payloadExercises = exercises
            .map((ex) => ({
            name: ex.name,
            sets: ex.sets.filter((s) => s.done).map((s) => ({ reps: s.reps, weight: s.weight })),
        }))
            .filter((ex) => ex.sets.length > 0);
        const session = {
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
                onToast(res.levels_gained > 0
                    ? `🎉 LEVEL UP! +${res.xp_gained.toLocaleString()} XP`
                    : `+${res.xp_gained.toLocaleString()} XP earned`);
            }
            else {
                onToast('Workout saved — will sync when you are back online.');
            }
        }
        catch (e) {
            // Offline or server hiccup: keep it queued, never lose the workout.
            const q = [...loadQueue(), session];
            saveQueue(q);
            setPending(q);
            setExercises([]);
            setSessionName('');
            setActive(false);
            onToast('No connection — workout queued on this device.');
        }
        finally {
            setFinishing(false);
        }
    };
    const retryPending = async () => {
        try {
            const res = await flushQueue([]);
            if (res) {
                onToast(`Synced ${res.accepted.length} queued workout${res.accepted.length === 1 ? '' : 's'} (+${res.xp_gained} XP)`);
                onSynced();
            }
            else
                onToast('Nothing to sync.');
        }
        catch {
            onToast('Still offline — keeping your workouts safe on this device.');
        }
    };
    const mmss = `${String(Math.floor(elapsed / 60)).padStart(2, '0')}:${String(elapsed % 60).padStart(2, '0')}`;
    if (!active) {
        return (_jsxs(_Fragment, { children: [_jsxs("div", { className: "card", style: { textAlign: 'center', padding: '28px 16px' }, children: [_jsx("div", { style: { fontSize: 44 }, children: "\uD83C\uDFCB\uFE0F" }), _jsx("h3", { style: { fontSize: 18 }, children: "Ready to train?" }), _jsx("p", { className: "muted", style: { fontSize: 14 }, children: "Every set earns XP. The server decides your level \u2014 no cheating, just lifting." }), _jsxs("div", { className: "field", style: { textAlign: 'left', marginBottom: 12 }, children: [_jsx("label", { children: "Session name (optional)" }), _jsx("input", { value: sessionName, onChange: (e) => setSessionName(e.target.value), placeholder: "Push day, Legs, \u2026", maxLength: 60 })] }), _jsx("button", { className: "btn btn-primary", onClick: start, children: "Start workout" })] }), pending.length > 0 && (_jsx("div", { className: "card", style: { borderColor: 'var(--gold)' }, children: _jsxs("div", { className: "spread", children: [_jsxs("div", { children: [_jsxs("strong", { children: [pending.length, " workout", pending.length === 1 ? '' : 's', " waiting to sync"] }), _jsx("div", { className: "muted", style: { fontSize: 13 }, children: "Stored on this device, safe." })] }), _jsx("button", { className: "btn btn-sm btn-primary", onClick: retryPending, children: "Sync now" })] }) }))] }));
    }
    return (_jsxs(_Fragment, { children: [_jsx("div", { className: "card", children: _jsxs("div", { className: "spread", children: [_jsxs("div", { children: [_jsx("div", { className: "eyebrow", children: "Live session" }), _jsx("div", { className: "big", style: { fontVariantNumeric: 'tabular-nums' }, children: mmss })] }), _jsxs("div", { style: { textAlign: 'right' }, children: [_jsxs("div", { style: { fontWeight: 800 }, children: [Math.round(totals.volume).toLocaleString(), " lb"] }), _jsxs("div", { className: "muted", style: { fontSize: 12 }, children: [totals.reps, " reps"] })] })] }) }), exercises.map((ex, i) => (_jsxs("div", { className: "exercise-block", children: [_jsxs("div", { className: "spread", style: { marginBottom: 6 }, children: [_jsx("strong", { children: ex.name }), _jsx("button", { className: "btn-ghost btn btn-sm", onClick: () => removeExercise(i), "aria-label": `Remove ${ex.name}`, children: "\u2715" })] }), _jsxs("div", { className: "set-row", style: { borderBottom: '1px solid var(--line)', paddingBottom: 4 }, children: [_jsx("span", { className: "muted", style: { fontSize: 11 }, children: "SET" }), _jsx("span", { className: "muted", style: { fontSize: 11, textAlign: 'center' }, children: "LB" }), _jsx("span", { className: "muted", style: { fontSize: 11, textAlign: 'center' }, children: "REPS" }), _jsx("span", {})] }), ex.sets.map((s, k) => (_jsxs("div", { className: `set-row${s.done ? ' set-done' : ''}`, children: [_jsx("div", { className: "set-num", children: k + 1 }), _jsx("input", { type: "number", inputMode: "decimal", min: 0, value: s.weight || '', placeholder: "0", onChange: (e) => updateSet(i, k, { weight: Number(e.target.value) || 0 }), "aria-label": `Set ${k + 1} weight` }), _jsx("input", { type: "number", inputMode: "numeric", min: 0, value: s.reps || '', placeholder: "0", onChange: (e) => updateSet(i, k, { reps: Number(e.target.value) || 0 }), "aria-label": `Set ${k + 1} reps` }), _jsx("button", { className: "icon-btn", onClick: () => updateSet(i, k, { done: !s.done }), "aria-label": s.done ? `Unmark set ${k + 1}` : `Mark set ${k + 1} done`, style: s.done ? { background: 'var(--accent-2)', borderColor: 'var(--accent-2)' } : undefined, children: s.done ? '✓' : '○' })] }, k))), _jsx("button", { className: "btn btn-sm", style: { marginTop: 8 }, onClick: () => addSet(i), children: "+ Add set" })] }, i))), _jsx("div", { className: "card", children: _jsxs("div", { className: "row", children: [_jsx("input", { value: newExName, onChange: (e) => setNewExName(e.target.value), placeholder: "Exercise name \u2014 e.g. Barbell Squat", maxLength: 80, style: { flex: 1, minHeight: 48, borderRadius: 12, border: '1px solid var(--line)', background: 'var(--bg-soft)', padding: '0 14px', fontSize: 16 }, onKeyDown: (e) => e.key === 'Enter' && addExercise() }), _jsx("button", { className: "btn btn-sm btn-primary", onClick: addExercise, children: "Add" })] }) }), _jsx("button", { className: "btn btn-primary", disabled: finishing, onClick: finish, children: finishing ? 'Saving…' : 'Finish workout' }), _jsx("button", { className: "btn btn-ghost", onClick: () => setActive(false), children: "Discard session" })] }));
}
