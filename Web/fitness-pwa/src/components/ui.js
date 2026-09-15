import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
export function XpBar({ current, min, max }) {
    const span = Math.max(1, max - min);
    const pct = Math.min(100, Math.max(0, ((current - min) / span) * 100));
    return (_jsx("div", { className: "xp-track", role: "progressbar", "aria-valuenow": Math.round(pct), "aria-valuemin": 0, "aria-valuemax": 100, children: _jsx("div", { className: "xp-fill", style: { width: `${pct}%` } }) }));
}
export function LevelBadge({ level }) {
    return _jsx("div", { className: "level-badge", children: level });
}
export function StatChip({ value, label }) {
    return (_jsxs("div", { className: "stat-chip", children: [_jsx("div", { className: "v", children: value }), _jsx("div", { className: "k", children: label })] }));
}
export function Sheet({ onClose, children, title }) {
    return (_jsx("div", { className: "sheet-backdrop", onClick: onClose, children: _jsxs("div", { className: "sheet", onClick: (e) => e.stopPropagation(), role: "dialog", "aria-modal": "true", children: [_jsx("div", { className: "sheet-handle" }), title && _jsx("h3", { style: { margin: '0 0 12px' }, children: title }), children] }) }));
}
export function Avatar({ name, url, size = 40 }) {
    const initial = (name || 'A').trim().charAt(0).toUpperCase();
    return (_jsx("div", { className: "avatar", style: { width: size, height: size, borderRadius: Math.round(size * 0.35), fontSize: Math.round(size * 0.4) }, children: url ? _jsx("img", { src: url, alt: name }) : initial }));
}
export function Empty({ children }) {
    return _jsx("div", { className: "empty", children: children });
}
export function Loading({ label = 'Loading…' }) {
    return (_jsxs("div", { className: "loading", children: [_jsx("div", { className: "spinner" }), label] }));
}
export function fmtVolume(lb) {
    if (lb >= 1000000)
        return `${(lb / 1000000).toFixed(1)}M`;
    if (lb >= 10000)
        return `${(lb / 1000).toFixed(0)}k`;
    if (lb >= 1000)
        return `${(lb / 1000).toFixed(1)}k`;
    return `${Math.round(lb)}`;
}
export function timeAgo(epochSecs) {
    const s = Math.max(1, Math.floor(Date.now() / 1000) - epochSecs);
    if (s < 60)
        return 'just now';
    const m = Math.floor(s / 60);
    if (m < 60)
        return `${m}m ago`;
    const h = Math.floor(m / 60);
    if (h < 24)
        return `${h}h ago`;
    const d = Math.floor(h / 24);
    if (d < 7)
        return `${d}d ago`;
    const w = Math.floor(d / 7);
    return `${w}w ago`;
}
