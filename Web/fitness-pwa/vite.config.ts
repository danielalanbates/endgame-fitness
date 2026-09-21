import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

// Served from https://batesai.org/fitness/ — same origin as /api/*, so no CORS
// configuration is needed. The base must match the deploy path exactly or
// asset URLs and the PWA manifest scope will break.
export default defineConfig({
  plugins: [
    react(),
    // Stamp the service worker's cache name on every build. The browser only
    // installs a new SW when sw.js bytes change; without this, deploys that
    // only change hashed assets would leave users on a stale cached shell.
    {
      name: 'sw-cache-version',
      writeBundle() {
        const swPath = join(import.meta.dirname, 'dist', 'sw.js');
        const stamped = readFileSync(swPath, 'utf8').replace(
          'endgame-fitness-v1',
          `endgame-fitness-${Date.now()}`,
        );
        writeFileSync(swPath, stamped);
      },
    },
  ],
  base: '/fitness/',
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
});
