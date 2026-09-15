import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import { useCallback, useState } from 'react';
import { AuthProvider, useAuth } from './auth';
import Home from './tabs/Home';
import Workout from './tabs/Workout';
import Progress from './tabs/Progress';
import Social from './tabs/Social';
import Profile from './tabs/Profile';
const TABS = [
    { id: 'home', label: 'Home', icon: '🏠' },
    { id: 'workout', label: 'Train', icon: '🏋️' },
    { id: 'progress', label: 'Progress', icon: '📈' },
    { id: 'social', label: 'Social', icon: '👥' },
    { id: 'profile', label: 'You', icon: '⭐' },
];
function LoginScreen() {
    const { login, register, error, clearError } = useAuth();
    const [mode, setMode] = useState('login');
    const [email, setEmail] = useState('');
    const [password, setPassword] = useState('');
    const [name, setName] = useState('');
    const [busy, setBusy] = useState(false);
    const submit = async () => {
        if (!email.trim() || !password)
            return;
        setBusy(true);
        try {
            if (mode === 'login')
                await login(email, password);
            else
                await register(email, password, name || email.split('@')[0]);
        }
        catch {
            /* error surfaced via context */
        }
        finally {
            setBusy(false);
        }
    };
    return (_jsxs("div", { className: "auth-wrap", children: [_jsx("div", { className: "auth-logo", children: "\uD83C\uDFCB\uFE0F" }), _jsxs("div", { style: { textAlign: 'center' }, children: [_jsx("h1", { style: { margin: '0 0 6px', fontSize: 28 }, children: "Endgame Fitness" }), _jsxs("p", { className: "muted", style: { margin: 0, fontSize: 14 }, children: ["Strength training that plays like a game.", _jsx("br", {}), "Sign in with your batesai.org membership."] })] }), error && _jsx("div", { className: "error-box", children: error }), _jsxs("div", { className: "stack", children: [mode === 'register' && (_jsxs("div", { className: "field", children: [_jsx("label", { children: "Display name" }), _jsx("input", { value: name, onChange: (e) => setName(e.target.value), placeholder: "Daniel", maxLength: 40, autoComplete: "name" })] })), _jsxs("div", { className: "field", children: [_jsx("label", { children: "Email" }), _jsx("input", { value: email, onChange: (e) => { setEmail(e.target.value); clearError(); }, placeholder: "you@example.com", autoCapitalize: "none", autoComplete: "email", inputMode: "email" })] }), _jsxs("div", { className: "field", children: [_jsx("label", { children: "Password" }), _jsx("input", { value: password, onChange: (e) => { setPassword(e.target.value); clearError(); }, type: "password", placeholder: mode === 'register' ? '8+ characters' : 'Your password', autoComplete: mode === 'register' ? 'new-password' : 'current-password', onKeyDown: (e) => e.key === 'Enter' && submit() })] }), _jsx("button", { className: "btn btn-primary", disabled: busy, onClick: submit, children: busy ? 'Connecting…' : mode === 'login' ? 'Sign in' : 'Create account' }), _jsx("button", { className: "btn btn-ghost", style: { width: '100%', color: 'var(--muted)' }, onClick: () => { setMode(mode === 'login' ? 'register' : 'login'); clearError(); }, children: mode === 'login' ? 'New here? Create an account' : 'Have an account? Sign in' })] }), _jsx("p", { className: "muted", style: { fontSize: 12, textAlign: 'center' }, children: "Same login as the native app \u2014 your level, streak and guild carry over." })] }));
}
function Shell() {
    const { user, ready } = useAuth();
    const [tab, setTab] = useState('home');
    const [toast, setToast] = useState(null);
    const [homeKey, setHomeKey] = useState(0);
    const showToast = useCallback((msg) => {
        setToast(msg);
        window.setTimeout(() => setToast(null), 3200);
    }, []);
    if (!ready) {
        return (_jsxs("div", { className: "auth-wrap", children: [_jsx("div", { className: "auth-logo", children: "\uD83C\uDFCB\uFE0F" }), _jsx("p", { className: "muted", style: { textAlign: 'center' }, children: "Waking up the gym\u2026" })] }));
    }
    if (!user)
        return _jsx(LoginScreen, {});
    return (_jsxs(_Fragment, { children: [_jsxs("main", { className: "app-main", children: [tab === 'home' && _jsx(Home, { onToast: showToast }, homeKey), tab === 'workout' && _jsx(Workout, { onToast: showToast, onSynced: () => setHomeKey((k) => k + 1) }), tab === 'progress' && _jsx(Progress, {}), tab === 'social' && _jsx(Social, { onToast: showToast }), tab === 'profile' && _jsx(Profile, { onToast: showToast })] }), _jsx("nav", { className: "tabbar", "aria-label": "Main", children: TABS.map((t) => (_jsxs("button", { className: tab === t.id ? 'active' : '', onClick: () => setTab(t.id), "aria-current": tab === t.id, children: [_jsx("span", { className: "ico", children: t.icon }), t.label] }, t.id))) }), toast && _jsx("div", { className: "success-pop", children: toast })] }));
}
export default function App() {
    return (_jsx(AuthProvider, { children: _jsx(Shell, {}) }));
}
