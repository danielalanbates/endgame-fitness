/**
 * Typed client for the real batesai.org API. Same origin as the app
 * (https://batesai.org/fitness -> https://batesai.org/api), so no CORS
 * configuration is required. Nothing here is mocked: every call hits the
 * live membership + fitness backend.
 */
export interface ApiUser {
    id: string;
    email: string;
    name: string;
    avatar_url: string | null;
    membership: string;
}
export interface FitnessProfile {
    user_id: string;
    email: string;
    display_name: string;
    avatar_url: string | null;
    level: number;
    xp: number;
    xp_for_next_level: number;
    xp_for_current_level: number;
    talent_points: number;
    prestige: number;
    current_streak: number;
    longest_streak: number;
    last_workout_date: string | null;
    total_workouts: number;
    total_volume: number;
    total_reps: number;
    training_goal: string | null;
    experience_level: string | null;
    equipment_level: string | null;
    body_weight: number | null;
    height_inches: number | null;
    birth_year: number | null;
    units: string;
    avatar_config: unknown;
    title: string | null;
    is_public: boolean;
    friend_code: string | null;
}
export interface TalentNode {
    id: string;
    branch: string;
    tier: number;
    max_rank: number;
    requires: {
        id: string;
        rank: number;
    }[];
    name: string;
    icon: string;
    description: string;
    effect: Record<string, unknown>;
}
export interface TalentState {
    tree: {
        version: number;
        branches: {
            id: string;
            name: string;
            color: string;
            icon: string;
        }[];
        nodes: TalentNode[];
    };
    ranks: Record<string, number>;
    unspent: number;
    spent: number;
}
export interface Quest {
    id: string;
    quest_key: string;
    kind: 'daily' | 'weekly';
    title: string;
    description: string;
    icon: string;
    metric: string | null;
    target: number;
    progress: number;
    xp_reward: number;
    expires_at: number;
    completed_at: number | null;
    claimed: boolean;
}
export interface Achievement {
    id: string;
    name: string;
    description: string;
    icon: string;
    unlocked: boolean;
    unlocked_at: number | null;
}
export interface WorkoutSet {
    reps: number;
    weight: number;
}
export interface WorkoutExercise {
    name: string;
    sets: WorkoutSet[];
}
export interface OutgoingSession {
    id: string;
    performed_at: number;
    name: string | null;
    program_id: string | null;
    duration_secs: number;
    total_volume: number;
    total_reps: number;
    client_rev: number;
    payload: {
        exercises: WorkoutExercise[];
    };
}
export interface SyncResult {
    accepted: string[];
    xp_gained: number;
    levels_gained: number;
    talent_points_gained: number;
    achievements_unlocked: string[];
    raid: unknown;
    sessions: unknown[];
    has_more: boolean;
    server_time: number;
    profile: FitnessProfile;
}
export interface FeedItem {
    id: string;
    user_id: string;
    display_name: string;
    level: number;
    avatar_url: string | null;
    kind: string;
    summary: string;
    payload: Record<string, unknown> | null;
    created_at: number;
    reactions: {
        emoji: string;
        count: number;
    }[];
    is_self: boolean;
}
export interface LeaderboardEntry {
    rank: number;
    user_id: string;
    display_name: string;
    level: number;
    xp: number;
    current_streak: number;
    total_volume: number;
    total_workouts: number;
    title: string | null;
    avatar_url: string | null;
    is_self: boolean;
}
export interface Friend {
    user_id: string;
    display_name: string;
    level: number;
    current_streak: number;
    xp: number;
    avatar_url: string | null;
    status: string;
    other_id: string;
}
export interface Guild {
    id: string;
    name: string;
    motto: string | null;
    owner_id: string;
    member_count: number;
    members: {
        user_id: string;
        display_name: string;
        level: number;
        role: string;
    }[];
    is_member: boolean;
    is_owner: boolean;
}
export interface RaidInfo {
    id: string;
    boss: {
        id: string;
        name: string;
        flavor: string;
        symbol: string;
        gradient: string;
        reward_xp: number;
        reward_title: string;
        reward_cosmetic: string;
    };
    hp: number;
    damage_done: number;
    hp_remaining: number;
    defeated: boolean;
    seconds_left: number;
    member_count: number;
    my_damage: number;
    my_hits: number;
    contributors: {
        rank: number;
        user_id: string;
        display_name: string;
        level: number;
        damage: number;
        hits: number;
        is_self: boolean;
    }[];
}
export declare function getToken(): string | null;
export declare function setToken(token: string | null): void;
export declare class ApiError extends Error {
    status: number;
    constructor(status: number, message: string);
}
export declare const apiLogin: (email: string, password: string) => Promise<{
    token: string;
    user: ApiUser;
}>;
export declare const apiRegister: (email: string, password: string, name: string) => Promise<{
    token: string;
    user: ApiUser;
}>;
export declare const apiVerify: () => Promise<{
    valid: boolean;
    user?: ApiUser;
}>;
export declare const apiLogout: () => Promise<{
    message: string;
}>;
export declare const apiGetProfile: () => Promise<{
    profile: FitnessProfile;
    talents: unknown[];
    achievements: unknown[];
    personal_records: unknown[];
}>;
export declare const apiUpdateProfile: (patch: Partial<FitnessProfile>) => Promise<{
    profile: FitnessProfile;
}>;
export declare const apiSync: (sessions: OutgoingSession[], since: number) => Promise<SyncResult>;
export declare const apiGetFeed: () => Promise<{
    items: FeedItem[];
}>;
export declare const apiReact: (activityId: string, emoji: string) => Promise<{
    success: boolean;
}>;
export declare const apiLeaderboard: (scope?: string, metric?: string) => Promise<{
    scope: string;
    metric: string;
    entries: LeaderboardEntry[];
    you: LeaderboardEntry | null;
}>;
export declare const apiGetFriends: () => Promise<{
    friends: Friend[];
    pending_in: Friend[];
    pending_out: Friend[];
}>;
export declare const apiFriendRequest: (email?: string, friendCode?: string) => Promise<{
    success: boolean;
}>;
export declare const apiFriendRespond: (userId: string, accept: boolean) => Promise<{
    success: boolean;
}>;
export declare const apiGetGuild: () => Promise<{
    guild: Guild | null;
}>;
export declare const apiCreateGuild: (name: string, motto: string) => Promise<{
    guild: Guild;
}>;
export declare const apiJoinGuild: (guildId: string) => Promise<{
    success: boolean;
}>;
export declare const apiLeaveGuild: () => Promise<{
    success: boolean;
}>;
export declare const apiGetRaid: () => Promise<{
    raid: RaidInfo | null;
    reason?: string;
}>;
export declare const apiGetTalents: () => Promise<TalentState>;
export declare const apiSpendTalent: (talentId: string) => Promise<TalentState & {
    success: boolean;
}>;
export declare const apiGetQuests: () => Promise<{
    daily: Quest[];
    weekly: Quest[];
    server_time: number;
}>;
export declare const apiClaimQuest: (questId: string) => Promise<{
    success: boolean;
    xp_gained: number;
    levels_gained: number;
    quest: Quest;
}>;
export declare const apiGetAchievements: () => Promise<{
    achievements: Achievement[];
    unlocked_count: number;
    total_count: number;
}>;
