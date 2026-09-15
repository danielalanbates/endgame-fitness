import { jsx as _jsx } from "react/jsx-runtime";
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { apiLogin, apiLogout, apiRegister, apiVerify, getToken, setToken } from './api';
const AuthContext = createContext(null);
export function AuthProvider({ children }) {
    const [user, setUser] = useState(null);
    const [ready, setReady] = useState(false);
    const [error, setError] = useState(null);
    useEffect(() => {
        let cancelled = false;
        (async () => {
            if (!getToken()) {
                setReady(true);
                return;
            }
            try {
                const res = await apiVerify();
                if (!cancelled && res.valid && res.user)
                    setUser(res.user);
                else if (!cancelled)
                    setToken(null);
            }
            catch {
                // Network down: keep the token so the app opens; calls will fail
                // loudly later and the user can retry. Don't sign out on a blip.
                if (!cancelled)
                    setError('Could not reach batesai.org. Check your connection and pull to retry.');
            }
            finally {
                if (!cancelled)
                    setReady(true);
            }
        })();
        return () => {
            cancelled = true;
        };
    }, []);
    const login = useCallback(async (email, password) => {
        setError(null);
        try {
            const res = await apiLogin(email.trim(), password);
            setToken(res.token);
            setUser(res.user);
        }
        catch (e) {
            setError(e instanceof Error ? e.message : 'Sign-in failed');
            throw e;
        }
    }, []);
    const register = useCallback(async (email, password, name) => {
        setError(null);
        try {
            const res = await apiRegister(email.trim(), password, name.trim());
            setToken(res.token);
            setUser(res.user);
        }
        catch (e) {
            setError(e instanceof Error ? e.message : 'Registration failed');
            throw e;
        }
    }, []);
    const logout = useCallback(async () => {
        try {
            await apiLogout();
        }
        catch {
            /* best effort */
        }
        setToken(null);
        setUser(null);
    }, []);
    const clearError = useCallback(() => setError(null), []);
    const value = useMemo(() => ({ user, ready, error, login, register, logout, clearError }), [user, ready, error, login, register, logout, clearError]);
    return _jsx(AuthContext.Provider, { value: value, children: children });
}
export function useAuth() {
    const ctx = useContext(AuthContext);
    if (!ctx)
        throw new Error('useAuth must be used inside AuthProvider');
    return ctx;
}
