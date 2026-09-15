import React from 'react';
export declare function XpBar({ current, min, max }: {
    current: number;
    min: number;
    max: number;
}): React.JSX.Element;
export declare function LevelBadge({ level }: {
    level: number;
}): React.JSX.Element;
export declare function StatChip({ value, label }: {
    value: string;
    label: string;
}): React.JSX.Element;
export declare function Sheet({ onClose, children, title }: {
    onClose: () => void;
    children: React.ReactNode;
    title?: string;
}): React.JSX.Element;
export declare function Avatar({ name, url, size }: {
    name: string;
    url?: string | null;
    size?: number;
}): React.JSX.Element;
export declare function Empty({ children }: {
    children: React.ReactNode;
}): React.JSX.Element;
export declare function Loading({ label }: {
    label?: string;
}): React.JSX.Element;
export declare function fmtVolume(lb: number): string;
export declare function timeAgo(epochSecs: number): string;
