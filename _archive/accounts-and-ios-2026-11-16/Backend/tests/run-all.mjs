/**
 * Run every backend test file in its own process and summarise.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Run: node App/Backend/tests/run-all.mjs
 */

import { spawnSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const files = readdirSync(here).filter((f) => f.endsWith('.test.mjs')).sort();
let failed = 0;
for (const f of files) {
  const res = spawnSync(process.execPath, [join(here, f)], { encoding: 'utf8' });
  const ok = res.status === 0 && !/\bFAIL\b/.test(res.stdout);
  const summary = (res.stdout.trim().split('\n').pop() || '').trim();
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${f.padEnd(34)} ${summary}`);
  if (!ok) {
    failed += 1;
    console.log(res.stdout.split('\n').filter((l) => /FAIL|Error|assert/i.test(l)).slice(0, 20).join('\n'));
    if (res.stderr.trim()) console.log(res.stderr.trim().split('\n').slice(0, 20).join('\n'));
  }
}
console.log(`\n${files.length - failed}/${files.length} test files passed`);
process.exitCode = failed ? 1 : 0;
