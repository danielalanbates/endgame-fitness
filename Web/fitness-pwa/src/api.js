/**
 * Typed client for the real batesai.org API. Same origin as the app
 * (https://batesai.org/fitness -> https://batesai.org/api), so no CORS
 * configuration is required. Nothing here is mocked: every call hits the
 * live membership + fitness backend.
 */
const TOKEN_KEY = 'ef_token';
export function getToken() {
    try {
        return localStorage.getItem(TOKEN_KEY);
    }
    catch {
        return null;
    }
}
export function setToken(token) {
    try {
        if (token)
            localStorage.setItem(TOKEN_KEY, token);
        else
            localStorage.removeItem(TOKEN_KEY);
    }
    catch {
        /* private mode: auth simply won't persist */
    }
}
export class ApiError extends Error {
    constructor(status, message) {
        super(message);
        this.status = status;
    }
}
async function request(path, options = {}) {
    const token = getToken();
    const headers = { 'Content-Type': 'application/json' };
    if (token)
        headers['Authorization'] = `Bearer ${token}`;
    const res = await fetch(path, { ...options, headers: { ...headers, ...options.headers } });
    let body = null;
    try {
        body = await res.json();
    }
    catch {
        /* non-JSON body */
    }
    if (!res.ok) {
        const msg = body?.error || `Request failed (${res.status})`;
        throw new ApiError(res.status, msg);
    }
    return body;
}
const get = (path) => request(path, { method: 'GET' });
const post = (path, body) => request(path, { method: 'POST', body: body === undefined ? undefined : JSON.stringify(body) });
const put = (path, body) => request(path, { method: 'PUT', body: JSON.stringify(body) });
// ---- Auth (batesai.org membership) ----
export const apiLogin = (email, password) => post('/api/auth/login', { email, password });
export const apiRegister = (email, password, name) => post('/api/auth/register', { email, password, name });
export const apiVerify = () => get('/api/auth/verify');
export const apiLogout = () => post('/api/auth/logout');
// ---- Fitness ----
export const apiGetProfile = () => get('/api/fitness/profile');
export const apiUpdateProfile = (patch) => put('/api/fitness/profile', patch);
export const apiSync = (sessions, since) => post('/api/fitness/sync', { sessions, since });
export const apiGetFeed = () => get('/api/fitness/feed');
export const apiReact = (activityId, emoji) => post(`/api/fitness/feed/${activityId}/react`, { emoji });
export const apiLeaderboard = (scope = 'global', metric = 'xp') => get(`/api/fitness/leaderboard?scope=${scope}&metric=${metric}`);
export const apiGetFriends = () => get('/api/fitness/friends');
export const apiFriendRequest = (email, friendCode) => post('/api/fitness/friends/request', email ? { email } : { friend_code: friendCode });
export const apiFriendRespond = (userId, accept) => post('/api/fitness/friends/respond', { user_id: userId, accept });
export const apiGetGuild = () => get('/api/fitness/guild');
export const apiCreateGuild = (name, motto) => post('/api/fitness/guild', { name, motto });
export const apiJoinGuild = (guildId) => post('/api/fitness/guild/join', { guild_id: guildId });
export const apiLeaveGuild = () => post('/api/fitness/guild/leave');
export const apiGetRaid = () => get('/api/fitness/raid');
export const apiGetTalents = () => get('/api/fitness/talents');
export const apiSpendTalent = (talentId) => post('/api/fitness/talents/spend', { talent_id: talentId });
export const apiGetQuests = () => get('/api/fitness/quests');
export const apiClaimQuest = (questId) => post(`/api/fitness/quests/${questId}/claim`);
export const apiGetAchievements = () => get('/api/fitness/achievements');
