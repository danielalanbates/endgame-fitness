import { useCallback, useState } from 'react';
import { AuthProvider, useAuth } from './auth';
import { oauthStartUrl } from './api';
import Home from './tabs/Home';
import Workout from './tabs/Workout';
import Progress from './tabs/Progress';
import Social from './tabs/Social';
import Profile from './tabs/Profile';

type Tab = 'home' | 'workout' | 'progress' | 'social' | 'profile';

const TABS: { id: Tab; label: string; icon: string }[] = [
  { id: 'home', label: 'Home', icon: '🏠' },
  { id: 'workout', label: 'Train', icon: '🏋️' },
  { id: 'progress', label: 'Progress', icon: '📈' },
  { id: 'social', label: 'Social', icon: '👥' },
  { id: 'profile', label: 'You', icon: '⭐' },
];

function LoginScreen() {
  const { login, register, error, clearError } = useAuth();
  const [mode, setMode] = useState<'login' | 'register'>('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    if (!email.trim() || !password) return;
    setBusy(true);
    try {
      if (mode === 'login') await login(email, password);
      else await register(email, password, name || email.split('@')[0]);
    } catch {
      /* error surfaced via context */
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="auth-wrap">
      <div className="auth-logo">🏋️</div>
      <div style={{ textAlign: 'center' }}>
        <h1 style={{ margin: '0 0 6px', fontSize: 28 }}>Endgame Fitness</h1>
        <p className="muted" style={{ margin: 0, fontSize: 14 }}>
          Strength training that plays like a game.<br />Sign in with your batesai.org membership.
        </p>
      </div>
      {error && <div className="error-box">{error}</div>}
      <ProviderButtons />
      <div className="auth-divider" role="separator"><span>or use email</span></div>
      <div className="stack">
        {mode === 'register' && (
          <div className="field">
            <label>Display name</label>
            <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Daniel" maxLength={40} autoComplete="name" />
          </div>
        )}
        <div className="field">
          <label>Email</label>
          <input
            value={email}
            onChange={(e) => { setEmail(e.target.value); clearError(); }}
            placeholder="you@example.com"
            autoCapitalize="none"
            autoComplete="email"
            inputMode="email"
          />
        </div>
        <div className="field">
          <label>Password</label>
          <input
            value={password}
            onChange={(e) => { setPassword(e.target.value); clearError(); }}
            type="password"
            placeholder={mode === 'register' ? '8+ characters' : 'Your password'}
            autoComplete={mode === 'register' ? 'new-password' : 'current-password'}
            onKeyDown={(e) => e.key === 'Enter' && submit()}
          />
        </div>
        <button className="btn btn-primary" disabled={busy} onClick={submit}>
          {busy ? 'Connecting…' : mode === 'login' ? 'Sign in' : 'Create account'}
        </button>
        <button
          className="btn btn-ghost"
          style={{ width: '100%', color: 'var(--muted)' }}
          onClick={() => { setMode(mode === 'login' ? 'register' : 'login'); clearError(); }}
        >
          {mode === 'login' ? 'New here? Create an account' : 'Have an account? Sign in'}
        </button>
      </div>
      {mode === 'login' && (
        <p className="muted" style={{ fontSize: 12, textAlign: 'center', margin: 0 }}>
          Forgot your password? Sign in with Apple or Google using the same email, or write to{' '}
          <a href="mailto:help@batesai.org">help@batesai.org</a>.
        </p>
      )}
      <p className="muted" style={{ fontSize: 12, textAlign: 'center' }}>
        Same login as the native app — your level, streak and guild carry over.
      </p>
    </div>
  );
}

/**
 * Google and Apple sign-in through batesai.org membership. Plain links: the
 * whole page goes to the provider and comes back to /fitness/ signed in.
 */
function ProviderButtons() {
  return (
    <div className="stack">
      <a className="btn btn-provider" href={oauthStartUrl('apple')}>
        <AppleLogo />
        Continue with Apple
      </a>
      <a className="btn btn-provider" href={oauthStartUrl('google')}>
        <GoogleLogo />
        Continue with Google
      </a>
    </div>
  );
}

function AppleLogo() {
  return (
    <svg className="provider-logo" viewBox="0 0 814 1000" aria-hidden="true">
      <path
        fill="currentColor"
        d="M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9 134.2 202.2-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5 123.1s-85.5-39.5-164-39.5c-76.5 0-103.7 40.8-165.9 40.8s-105.6-57-155.5-127C46.7 790.7 0 663 0 541.8c0-194.4 126.4-297.5 250.8-297.5 66.1 0 121.2 43.4 162.7 43.4 39.5 0 101.1-46 176.3-46 28.5 0 130.9 2.6 198.3 99.2zm-234-181.5c31.1-36.9 53.1-88.1 53.1-139.3 0-7.1-.6-14.3-1.9-20.1-50.6 1.9-110.8 33.7-147.1 75.8-28.5 32.4-55.1 83.6-55.1 135.5 0 7.8 1.3 15.6 1.9 18.1 3.2.6 8.4 1.3 13.6 1.3 45.4 0 102.5-30.4 135.5-71.3z"
      />
    </svg>
  );
}

function GoogleLogo() {
  return (
    <svg className="provider-logo" viewBox="0 0 48 48" aria-hidden="true">
      <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z" />
      <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z" />
      <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z" />
      <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z" />
    </svg>
  );
}

function Shell() {
  const { user, ready } = useAuth();
  const [tab, setTab] = useState<Tab>('home');
  const [toast, setToast] = useState<string | null>(null);
  const [homeKey, setHomeKey] = useState(0);

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 3200);
  }, []);

  if (!ready) {
    return (
      <div className="auth-wrap">
        <div className="auth-logo">🏋️</div>
        <p className="muted" style={{ textAlign: 'center' }}>Waking up the gym…</p>
      </div>
    );
  }
  if (!user) return <LoginScreen />;

  return (
    <>
      <main className="app-main">
        {tab === 'home' && <Home key={homeKey} onToast={showToast} />}
        {tab === 'workout' && <Workout onToast={showToast} onSynced={() => setHomeKey((k) => k + 1)} />}
        {tab === 'progress' && <Progress />}
        {tab === 'social' && <Social onToast={showToast} />}
        {tab === 'profile' && <Profile onToast={showToast} />}
      </main>
      <nav className="tabbar" aria-label="Main">
        {TABS.map((t) => (
          <button key={t.id} className={tab === t.id ? 'active' : ''} onClick={() => setTab(t.id)} aria-current={tab === t.id}>
            <span className="ico">{t.icon}</span>
            {t.label}
          </button>
        ))}
      </nav>
      {toast && <div className="success-pop">{toast}</div>}
    </>
  );
}

export default function App() {
  return (
    <AuthProvider>
      <Shell />
    </AuthProvider>
  );
}
