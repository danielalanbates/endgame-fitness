#!/bin/bash
#
# Deploy the Endgame Fitness API (+ the /fitness PWA) to batesai.org.
#
# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# https://batesai.org · help@batesai.org
#
# This repo is the source of truth for these Pages Functions:
#   functions/api/auth/[[path]].js   functions/api/fitness/[[path]].js
#   functions/membership.js          functions/_lib/*.js
# The rest of batesai.org lives in github.com/danielalanbates/website. A Pages
# deploy replaces the WHOLE site, so this script builds the site from the
# commit that is live right now (not from `main`, which has lagged production
# before), overlays our functions + PWA, and refuses to deploy if a section
# the live site serves would disappear.
#
# Sections staged into the site at deploy time (gitignored in the website repo):
#   /subjectmastery/  from the subject-mastery repo  (SUBJECTMASTERY_DIST=…)
#   /play/            Antediluvia browser client       (PLAY_DIST=…)
# If production serves one of them and no dist is given, the deploy stops.
#
# Usage:
#   ./deploy.sh --dry-run           # show what would happen
#   ./deploy.sh                     # sync, migrate, build, deploy
#   ./deploy.sh --schema            # apply schema + migrations only
# Env:
#   BATESAI_SITE_DIR   existing website checkout to use (default: fresh clone)
#   BATESAI_SITE_REF   commit/branch to build (default: live production commit)
#   SUBJECTMASTERY_DIST, PLAY_DIST   staged section builds (see above)
#
set -euo pipefail

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$BACKEND_DIR/../.." && pwd)"
PROJECT_NAME="website"
DB_NAME="batesai-db"

DRY_RUN=false
SCHEMA_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --schema)  SCHEMA_ONLY=true ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

run() {
  if $DRY_RUN; then echo "  [dry-run] $*"; else "$@"; fi
}

# wrangler misbehaves under /Users/daniel (mangled .wrangler/tmp paths) and
# hangs in iCloud trees; run it from a scratch directory.
WRANGLER_CWD="$(mktemp -d)"
wr() { (cd "$WRANGLER_CWD" && npx --yes wrangler@4 "$@"); }

echo "==> Checking wrangler authentication"
if ! wr whoami 2>&1 | grep -qi "account"; then
  echo "ERROR: wrangler is not authenticated. Run: npx wrangler login" >&2
  exit 1
fi

# ---------------------------------------------------------------- database
apply_sql_file() {
  # D1 has no ADD COLUMN IF NOT EXISTS, so migrations are applied one
  # statement at a time and "duplicate column name" is treated as done.
  local file="$1" stmt out
  echo "==> Applying $(basename "$file")"
  python3 - "$file" > "$WRANGLER_CWD/stmts.txt" <<'PY'
import sys, re
sql = open(sys.argv[1]).read()
sql = re.sub(r'--[^\n]*', '', sql)          # strip line comments
parts, buf, depth = [], [], 0
for tok in re.split(r'(;|\bBEGIN\b|\bEND\b)', sql, flags=re.I):
    up = tok.upper()
    if up == 'BEGIN': depth += 1
    if up == 'END' and depth: depth -= 1
    if tok == ';' and depth == 0:
        s = ''.join(buf).strip()
        if s: parts.append(s + ';')
        buf = []
    else:
        buf.append(tok)
tail = ''.join(buf).strip()
if tail: parts.append(tail + ';')
for p in parts:
    print(p.replace('\n', ' ') + '\0', end='')
PY
  while IFS= read -r -d '' stmt; do
    [ -n "${stmt// }" ] || continue
    if $DRY_RUN; then echo "  [dry-run] d1 execute: ${stmt:0:90}…"; continue; fi
    if ! out=$(wr d1 execute "$DB_NAME" --remote --command "$stmt" 2>&1); then
      if grep -qiE "duplicate column name|already exists" <<<"$out"; then
        echo "    (already applied) ${stmt:0:70}…"
      else
        echo "$out" >&2; echo "ERROR applying: $stmt" >&2; exit 1
      fi
    fi
  done < "$WRANGLER_CWD/stmts.txt"
}

apply_sql_file "$BACKEND_DIR/schema.sql"
for migration in "$BACKEND_DIR"/migrations/*.sql; do
  [ -e "$migration" ] || continue
  apply_sql_file "$migration"
done
if $SCHEMA_ONLY; then echo "==> Schema applied (--schema)."; exit 0; fi

# ---------------------------------------------------------------- site tree
SITE_REF="${BATESAI_SITE_REF:-}"
if [[ -z "$SITE_REF" ]]; then
  SITE_REF="$(wr pages deployment list --project-name="$PROJECT_NAME" --environment=production --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["Source"])')"
  echo "==> Live production was built from website@$SITE_REF"
fi
SITE_DIR="${BATESAI_SITE_DIR:-}"
if [[ -z "$SITE_DIR" ]]; then
  SITE_DIR="$(mktemp -d)/site"
  git clone -q https://github.com/danielalanbates/website.git "$SITE_DIR"
fi
(cd "$SITE_DIR" && git fetch -q origin && git checkout -q "$SITE_REF")

echo "==> Overlaying Endgame Fitness functions into $SITE_DIR"
run mkdir -p "$SITE_DIR/functions/api/auth" "$SITE_DIR/functions/api/fitness" "$SITE_DIR/functions/_lib"
run cp "$BACKEND_DIR/functions/api/auth/[[path]].js"    "$SITE_DIR/functions/api/auth/[[path]].js"
run cp "$BACKEND_DIR/functions/api/fitness/[[path]].js" "$SITE_DIR/functions/api/fitness/[[path]].js"
run cp "$BACKEND_DIR/functions/membership.js"           "$SITE_DIR/functions/membership.js"
run cp "$BACKEND_DIR"/functions/_lib/*.js               "$SITE_DIR/functions/_lib/"

echo "==> Staging the PWA into public/fitness/"
PWA_DIST="$REPO_DIR/Web/fitness-pwa/dist"
[[ -f "$PWA_DIST/index.html" ]] || { echo "ERROR: build the PWA first (cd Web/fitness-pwa && npm ci && npm run build)" >&2; exit 1; }
run rm -rf "$SITE_DIR/public/fitness"
run mkdir -p "$SITE_DIR/public/fitness"
run cp -R "$PWA_DIST/." "$SITE_DIR/public/fitness/"

stage_section() {   # stage_section <url path> <public dir> <dist or empty>
  local path="$1" dest="$2" src="$3" live
  live=$(curl -s --max-time 20 "https://batesai.org$path" | grep -c "<title>BatesAI - High-Performance" || true)
  if [[ -n "$src" ]]; then
    [[ -f "$src/index.html" ]] || { echo "ERROR: $src has no index.html" >&2; exit 1; }
    echo "==> Staging $path from $src"
    run rm -rf "$SITE_DIR/public/$dest"; run mkdir -p "$SITE_DIR/public/$dest"
    run cp -R "$src/." "$SITE_DIR/public/$dest/"
  elif [[ "$live" == "0" ]]; then
    echo "ERROR: production serves $path but no build was given; deploying would delete it." >&2
    echo "       Set the matching *_DIST variable (see the header of this script)." >&2
    exit 1
  else
    echo "==> $path is not live; leaving it out"
  fi
}
stage_section /subjectmastery/ subjectmastery "${SUBJECTMASTERY_DIST:-}"
stage_section /play/ play "${PLAY_DIST:-}"

echo "==> Building the site"
run bash -c "cd '$SITE_DIR' && npm ci --no-audit --no-fund >/dev/null && npm run build"

echo "==> Deploying to Cloudflare Pages"
# Pages Functions come from ./functions at the site root; deploy from there.
run bash -c "cd '$SITE_DIR' && npx --yes wrangler@4 pages deploy dist --project-name='$PROJECT_NAME' --branch=main --commit-dirty=true"

cat <<'EOF'

==> Deployed. Verify:
    curl -s -o /dev/null -w '%{http_code}\n' https://batesai.org/api/auth/verify    # 401 = function live
    curl -s https://batesai.org/api/auth/me                                        # {"signedIn":false}
    curl -s -o /dev/null -w '%{http_code}\n' https://batesai.org/api/fitness/season  # 401 = v2 live
    curl -s https://batesai.org/fitness/ | grep -o '<title>[^<]*'                   # Endgame PWA, not the homepage
Then commit the overlaid functions to the website repo (branch + PR) so the
website's own deploys don't roll them back.

Secrets (Pages → Settings → Variables): OAUTH_GOOGLE_CLIENT_SECRET,
OPENROUTER_API_KEY, ALLOWED_ORIGINS, DM_SYNC_KEY (website), STRIPE_* (website).
EOF
