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
  requires: { id: string; rank: number }[];
  name: string;
  icon: string;
  description: string;
  effect: Record<string, unknown>;
}

export interface TalentState {
  tree: { version: number; branches: { id: string; name: string; color: string; icon: string }[]; nodes: TalentNode[] };
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
  payload: { exercises: WorkoutExercise[] };
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
  reactions: { emoji: string; count: number }[];
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
  xp: number;
  current_streak: number;
  avatar_url: string | null;
}

export interface Guild {
  id: string;
  name: string;
  motto: string | null;
  owner_id: string;
  member_count: number;
  members: { user_id: string; display_name: string; level: number; role: string }[];
  is_member: boolean;
  is_owner: boolean;
}

export interface RaidInfo {
  id: string;
  boss: { id: string; name: string; flavor: string; symbol: string; gradient: string; reward_xp: number; reward_title: string; reward_cosmetic: string };
  hp: number;
  damage_done: number;
  hp_remaining: number;
  defeated: boolean;
  seconds_left: number;
  member_count: number;
  my_damage: number;
  my_hits: number;
  contributors: { rank: number; user_id: string; display_name: string; level: number; damage: number; hits: number; is_self: boolean }[];
}

const TOKEN_KEY = 'ef_token';

export function getToken(): string | null {
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function setToken(token: string | null) {
  try {
    if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
  } catch {
    /* private mode: auth simply won't persist */
  }
}

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const token = getToken();
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  // Same-origin: always send the batesai_session cookie when present so an
  // existing website login restores the session even without a stored token.
  const res = await fetch(path, {
    ...options,
    credentials: 'same-origin',
    headers: { ...headers, ...(options.headers as Record<string, string>) },
  });
  let body: unknown = null;
  try {
    body = await res.json();
  } catch {
    /* non-JSON body */
  }
  if (!res.ok) {
    const msg = (body as { error?: string } | null)?.error || `Request failed (${res.status})`;
    throw new ApiError(res.status, msg);
  }
  return body as T;
}

const get = <T>(path: string) => request<T>(path, { method: 'GET' });
const post = <T>(path: string, body?: unknown) =>
  request<T>(path, { method: 'POST', body: body === undefined ? undefined : JSON.stringify(body) });
const put = <T>(path: string, body: unknown) =>
  request<T>(path, { method: 'PUT', body: JSON.stringify(body) });

// ---- Auth (batesai.org membership) ----

export const apiLogin = (email: string, password: string) =>
  post<{ token: string; user: ApiUser }>('/api/auth/login', { email, password });

export const apiRegister = (email: string, password: string, name: string) =>
  post<{ token: string; user: ApiUser }>('/api/auth/register', { email, password, name });

export const apiVerify = () => get<{ valid: boolean; user?: ApiUser }>('/api/auth/verify');

export const apiLogout = () => post<{ message: string }>('/api/auth/logout');

// ---- Fitness ----

export const apiGetProfile = () =>
  get<{ profile: FitnessProfile; talents: unknown[]; achievements: unknown[]; personal_records: unknown[] }>(
    '/api/fitness/profile',
  );

export const apiUpdateProfile = (patch: Partial<FitnessProfile>) =>
  put<{ profile: FitnessProfile }>('/api/fitness/profile', patch);

export const apiSync = (sessions: OutgoingSession[], since: number) =>
  post<SyncResult>('/api/fitness/sync', { sessions, since });

export const apiGetFeed = () => get<{ items: FeedItem[] }>('/api/fitness/feed');

export const apiReact = (activityId: string, emoji: string) =>
  post<{ success: boolean }>(`/api/fitness/feed/${activityId}/react`, { emoji });

export const apiLeaderboard = (scope = 'global', metric = 'xp') =>
  get<{ scope: string; metric: string; entries: LeaderboardEntry[]; you: LeaderboardEntry | null }>(
    `/api/fitness/leaderboard?scope=${scope}&metric=${metric}`,
  );

export const apiGetFriends = () =>
  get<{ friends: Friend[]; incoming_requests: Friend[]; outgoing_requests: Friend[] }>('/api/fitness/friends');

export const apiFriendRequest = (email?: string, friendCode?: string) =>
  // Backend reads `code` (friend code) or `email` — not `friend_code`.
  post<{ success: boolean; status: string }>('/api/fitness/friends/request', email ? { email } : { code: friendCode });

export const apiFriendRespond = (userId: string, accept: boolean) =>
  post<{ success: boolean }>('/api/fitness/friends/respond', { user_id: userId, accept });

interface GuildRow {
  id: string;
  name: string;
  motto: string | null;
  owner_id: string;
  emblem: string | null;
  member_cap: number;
  created_at: number;
}

interface GuildResponse {
  guild: GuildRow | null;
  members: { user_id: string; display_name: string; level: number; role: string }[];
  your_role?: string;
}

// The backend returns { guild, members, your_role } with the guild as a raw
// DB row (or null when not a member). Reshape it into the Guild view model
// the UI consumes so Social.tsx doesn't have to know the wire shape.
function toGuild(res: GuildResponse): Guild | null {
  if (!res.guild) return null;
  const g = res.guild;
  return {
    id: g.id,
    name: g.name,
    motto: g.motto,
    owner_id: g.owner_id,
    member_count: res.members.length,
    members: res.members,
    is_member: true,
    is_owner: res.your_role === 'owner',
  };
}

export const apiGetGuild = async (): Promise<{ guild: Guild | null }> => {
  const res = await get<GuildResponse>('/api/fitness/guild');
  return { guild: toGuild(res) };
};

export const apiCreateGuild = async (name: string, motto: string): Promise<{ guild: Guild }> => {
  // Create returns { success, guild_id }; re-read to get the shaped guild.
  await post<{ success: boolean; guild_id: string }>('/api/fitness/guild', { name, motto });
  const { guild } = await apiGetGuild();
  if (!guild) throw new ApiError(500, 'Guild was created but could not be loaded');
  return { guild };
};

export const apiJoinGuild = (guildId: string) => post<{ success: boolean }>('/api/fitness/guild/join', { guild_id: guildId });

export const apiLeaveGuild = () => post<{ success: boolean }>('/api/fitness/guild/leave');

export const apiGetRaid = () => get<{ raid: RaidInfo | null; reason?: string }>('/api/fitness/raid');

export const apiGetTalents = () => get<TalentState>('/api/fitness/talents');

export const apiSpendTalent = (talentId: string) =>
  post<TalentState & { success: boolean }>('/api/fitness/talents/spend', { talent_id: talentId });

export const apiGetQuests = () => get<{ daily: Quest[]; weekly: Quest[]; server_time: number }>('/api/fitness/quests');

export const apiClaimQuest = (questId: string) =>
  post<{ success: boolean; xp_gained: number; levels_gained: number; quest: Quest }>(`/api/fitness/quests/${questId}/claim`);

export const apiGetAchievements = () =>
  get<{ achievements: Achievement[]; unlocked_count: number; total_count: number }>('/api/fitness/achievements');
