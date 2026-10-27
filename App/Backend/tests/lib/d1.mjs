/**
 * A tiny Cloudflare D1 stand-in over node:sqlite for integration tests.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Implements the D1 surface the workers use: prepare(sql).bind(...).first()
 * / .all() / .run(), and batch([...]) as one transaction. Bind values follow
 * D1's rules: booleans become 0/1, `undefined` and objects are rejected (D1
 * throws D1_TYPE_ERROR for them, so a test catches the same bug), and more
 * than 100 bound parameters in one statement throws, like D1.
 *
 * Also: applySqlFile() for whole files and applyStatements() for the
 * "one statement at a time, ignore duplicate column name" migration mode.
 */

import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';

const D1_MAX_BOUND_PARAMS = 100;

function convert(value) {
  if (value === undefined) throw new Error('D1_TYPE_ERROR: Type \'undefined\' not supported for value \'undefined\'');
  if (typeof value === 'boolean') return value ? 1 : 0;
  if (value === null || typeof value === 'number' || typeof value === 'string' || typeof value === 'bigint') return value;
  if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return value;
  throw new Error(`D1_TYPE_ERROR: Type '${typeof value}' not supported for value '${String(value)}'`);
}

class Statement {
  constructor(db, sql, params = []) {
    this.db = db;
    this.sql = sql;
    this.params = params;
  }

  bind(...values) {
    if (values.length > D1_MAX_BOUND_PARAMS) {
      throw new Error(`D1: too many SQL variables (${values.length} > ${D1_MAX_BOUND_PARAMS})`);
    }
    return new Statement(this.db, this.sql, values.map(convert));
  }

  #stmt() {
    this.db.queries += 1;
    return this.db.raw.prepare(this.sql);
  }

  async first(column) {
    const row = this.#stmt().get(...this.params);
    if (!row) return null;
    const plain = { ...row };
    return column ? plain[column] ?? null : plain;
  }

  async all() {
    const rows = this.#stmt().all(...this.params).map((r) => ({ ...r }));
    return { success: true, results: rows, meta: { rows_read: rows.length } };
  }

  async run() {
    const info = this.#stmt().run(...this.params);
    return {
      success: true,
      results: [],
      meta: { changes: Number(info.changes), last_row_id: Number(info.lastInsertRowid) },
    };
  }

  /** Used by batch(): reads return rows, writes return meta.changes. */
  execSync() {
    this.db.queries += 1;
    const stmt = this.db.raw.prepare(this.sql);
    if (/^\s*(SELECT|WITH)\b/i.test(this.sql) || /\bRETURNING\b/i.test(this.sql)) {
      const rows = stmt.all(...this.params).map((r) => ({ ...r }));
      return { success: true, results: rows, meta: { changes: 0 } };
    }
    const info = stmt.run(...this.params);
    return { success: true, results: [], meta: { changes: Number(info.changes), last_row_id: Number(info.lastInsertRowid) } };
  }
}

export class D1Database {
  constructor(path = ':memory:') {
    this.raw = new DatabaseSync(path); // foreign keys are enforced by default, as in D1
    this.queries = 0;
  }

  prepare(sql) {
    return new Statement(this, sql);
  }

  async batch(statements) {
    this.raw.exec('BEGIN');
    try {
      const results = statements.map((s) => s.execSync());
      this.raw.exec('COMMIT');
      return results;
    } catch (e) {
      this.raw.exec('ROLLBACK');
      throw e;
    }
  }

  async exec(sql) {
    this.raw.exec(sql);
    return { count: 1 };
  }
}

/** Split a SQL file into statements on `;` outside quotes and comments. */
export function splitStatements(sql) {
  const out = [];
  let cur = '';
  let quote = null;
  for (let i = 0; i < sql.length; i += 1) {
    const c = sql[i];
    if (quote) {
      cur += c;
      if (c === quote) quote = null;
      continue;
    }
    if (c === '-' && sql[i + 1] === '-') {
      const nl = sql.indexOf('\n', i);
      i = nl === -1 ? sql.length : nl;
      cur += '\n';
      continue;
    }
    if (c === "'" || c === '"') { quote = c; cur += c; continue; }
    if (c === ';') {
      if (cur.trim()) out.push(cur.trim());
      cur = '';
      continue;
    }
    cur += c;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

/** Apply a whole file at once (what `wrangler d1 execute --file` does). */
export function applySqlFile(db, path) {
  db.raw.exec(readFileSync(path, 'utf8'));
}

/**
 * Apply a file one statement at a time, ignoring only "duplicate column name"
 * (the documented deploy mode for migrations with ALTER TABLE ADD COLUMN).
 * Returns { applied, skipped } counts; any other error throws.
 */
export function applyStatements(db, path) {
  let applied = 0;
  let skipped = 0;
  for (const stmt of splitStatements(readFileSync(path, 'utf8'))) {
    try {
      db.raw.exec(stmt);
      applied += 1;
    } catch (e) {
      if (/duplicate column name/i.test(String(e && e.message))) { skipped += 1; continue; }
      throw new Error(`${e.message}\n  in statement: ${stmt.slice(0, 160)}`);
    }
  }
  return { applied, skipped };
}
