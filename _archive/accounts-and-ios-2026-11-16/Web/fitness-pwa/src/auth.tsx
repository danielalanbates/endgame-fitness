import React, { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { ApiError, ApiUser, apiLogin, apiLogout, apiRegister, apiVerify, setToken } from './api';

interface AuthState {
  user: ApiUser | null;
  ready: boolean;
  error: string | null;
  login: (email: string, password: string) => Promise<void>;
  register: (email: string, password: string, name: string) => Promise<void>;
  logout: () => Promise<void>;
  clearError: () => void;
}

const AuthContext = createContext<AuthState | null>(null);

// Reasons functions/membership.js can send back as ?signin_error=<reason>
// after a Google or Apple sign-in. Never render the raw value.
const SIGNIN_ERRORS: Record<string, string> = {
  access_denied: 'Sign-in was cancelled.',
  state_mismatch: 'That sign-in attempt expired or was interrupted. Please try again.',
  code_replayed: 'That sign-in link had already been used. Please try again.',
  token_rejected: "The provider's response could not be verified. Please try again.",
  no_identity_token: 'Apple did not return a sign-in token. Please try again.',
  bad_response: 'The response from Apple was malformed. Please try again.',
  not_configured: 'This sign-in method is not available right now. Use email and password instead.',
  account_exists:
    'An account with this email already exists, and the provider has not confirmed the address. Sign in with your password instead.',
  server_error: 'Something went wrong on our end. Please try again.',
};

/** Read and strip the OAuth return markers so a reload does not replay them. */
function takeSigninResult(): string | null {
  try {
    const params = new URLSearchParams(window.location.search);
    const reason = params.get('signin_error');
    if (reason !== null || params.has('signed_in')) {
      params.delete('signin_error');
      params.delete('signed_in');
      const rest = params.toString();
      window.history.replaceState({}, '', `${window.location.pathname}${rest ? `?${rest}` : ''}${window.location.hash}`);
    }
    if (reason === null) return null;
    return SIGNIN_ERRORS[reason] || 'Sign-in did not complete. Please try again.';
  } catch {
    return null;
  }
}

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user, setUser] = useState<ApiUser | null>(null);
  const [ready, setReady] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const signinError = takeSigninResult();
    if (signinError) setError(signinError);
    (async () => {
      // Always ask the backend: it accepts the stored Bearer <redacted> AND the
      // website's batesai_session cookie (same-origin, sent automatically), so
      // an existing batesai.org login restores here even with no local token.
      try {
        const res = await apiVerify();
        if (!cancelled && res.valid && res.user) setUser(res.user);
        else if (!cancelled) setToken(null);
      } catch (e) {
        if (!cancelled) {
          if (e instanceof ApiError && (e.status === 401 || e.status === 403)) {
            // Not signed in (or the token expired) — normal logged-out state.
            setToken(null);
          } else {
            // Network down: keep any stored token so the app opens; calls will
            // fail loudly later and the user can retry. Don't sign out on a blip.
            setError('Could not reach batesai.org. Check your connection and pull to retry.');
          }
        }
      } finally {
        if (!cancelled) setReady(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const login = useCallback(async (email: string, password: string) => {
    setError(null);
    try {
      const res = await apiLogin(email.trim(), password);
      setToken(res.token);
      setUser(res.user);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Sign-in failed');
      throw e;
    }
  }, []);

  const register = useCallback(async (email: string, password: string, name: string) => {
    setError(null);
    try {
      const res = await apiRegister(email.trim(), password, name.trim());
      setToken(res.token);
      setUser(res.user);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Registration failed');
      throw e;
    }
  }, []);

  const logout = useCallback(async () => {
    try {
      await apiLogout();
    } catch {
      /* best effort */
    }
    setToken(null);
    setUser(null);
  }, []);

  const clearError = useCallback(() => setError(null), []);

  const value = useMemo(
    () => ({ user, ready, error, login, register, logout, clearError }),
    [user, ready, error, login, register, logout, clearError],
  );
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used inside AuthProvider');
  return ctx;
}
