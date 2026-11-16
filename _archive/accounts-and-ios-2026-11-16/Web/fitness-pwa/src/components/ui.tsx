import React from 'react';

export function XpBar({ current, min, max }: { current: number; min: number; max: number }) {
  const span = Math.max(1, max - min);
  const pct = Math.min(100, Math.max(0, ((current - min) / span) * 100));
  return (
    <div className="xp-track" role="progressbar" aria-valuenow={Math.round(pct)} aria-valuemin={0} aria-valuemax={100}>
      <div className="xp-fill" style={{ width: `${pct}%` }} />
    </div>
  );
}

export function LevelBadge({ level }: { level: number }) {
  return <div className="level-badge">{level}</div>;
}

export function StatChip({ value, label }: { value: string; label: string }) {
  return (
    <div className="stat-chip">
      <div className="v">{value}</div>
      <div className="k">{label}</div>
    </div>
  );
}

export function Sheet({ onClose, children, title }: { onClose: () => void; children: React.ReactNode; title?: string }) {
  return (
    <div className="sheet-backdrop" onClick={onClose}>
      <div className="sheet" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true">
        <div className="sheet-handle" />
        {title && <h3 style={{ margin: '0 0 12px' }}>{title}</h3>}
        {children}
      </div>
    </div>
  );
}

export function Avatar({ name, url, size = 40 }: { name: string; url?: string | null; size?: number }) {
  const initial = (name || 'A').trim().charAt(0).toUpperCase();
  return (
    <div className="avatar" style={{ width: size, height: size, borderRadius: Math.round(size * 0.35), fontSize: Math.round(size * 0.4) }}>
      {url ? <img src={url} alt={name} /> : initial}
    </div>
  );
}

export function Empty({ children }: { children: React.ReactNode }) {
  return <div className="empty">{children}</div>;
}

export function Loading({ label = 'Loading…' }: { label?: string }) {
  return (
    <div className="loading">
      <div className="spinner" />
      {label}
    </div>
  );
}

export function fmtVolume(lb: number): string {
  if (lb >= 1_000_000) return `${(lb / 1_000_000).toFixed(1)}M`;
  if (lb >= 10_000) return `${(lb / 1000).toFixed(0)}k`;
  if (lb >= 1000) return `${(lb / 1000).toFixed(1)}k`;
  return `${Math.round(lb)}`;
}

export function timeAgo(epochSecs: number): string {
  const s = Math.max(1, Math.floor(Date.now() / 1000) - epochSecs);
  if (s < 60) return 'just now';
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  if (d < 7) return `${d}d ago`;
  const w = Math.floor(d / 7);
  return `${w}w ago`;
}
