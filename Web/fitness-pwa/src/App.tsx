import { useCallback, useState } from 'react';
import { AuthProvider, useAuth } from './auth';
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
      <p className="muted" style={{ fontSize: 12, textAlign: 'center' }}>
        Same login as the native app — your level, streak and guild carry over.
      </p>
    </div>
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
