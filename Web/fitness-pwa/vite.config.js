import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
// Served from https://batesai.org/fitness/ — same origin as /api/*, so no CORS
// configuration is needed. The base must match the deploy path exactly or
// asset URLs and the PWA manifest scope will break.
export default defineConfig({
    plugins: [react()],
    base: '/fitness/',
    build: {
        outDir: 'dist',
        emptyOutDir: true,
    },
});
