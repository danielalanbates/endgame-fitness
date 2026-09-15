import { jsx as _jsx } from "react/jsx-runtime";
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import './styles.css';
// Register the service worker (app-shell caching + offline). It lives at
// /fitness/sw.js with scope /fitness/ so it never interferes with the rest
// of batesai.org.
if ('serviceWorker' in navigator && window.location.protocol === 'https:') {
    window.addEventListener('load', () => {
        navigator.serviceWorker.register('/fitness/sw.js').catch(() => {
            /* offline support is a bonus, not a requirement */
        });
    });
}
ReactDOM.createRoot(document.getElementById('root')).render(_jsx(React.StrictMode, { children: _jsx(App, {}) }));
