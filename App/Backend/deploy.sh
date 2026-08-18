#!/bin/bash
#
# Deploy the Endgame Fitness API to batesai.org.
#
# This repo is the source of truth for the auth + fitness Pages Functions. The
# live site lives in a separate checkout (the home directory is its git worktree
# — see the batesai-website notes), so this copies the workers over and runs the
# schema migration and the deploy.
#
# The site does NOT auto-deploy on push; `wrangler pages deploy` is the only
# thing that ships it.
#
# Usage:
#   ./deploy.sh            # sync files, apply schema, deploy
#   ./deploy.sh --dry-run  # show what would happen
#   ./deploy.sh --schema   # apply the schema only
#
set -euo pipefail

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Where the built site (dist/ + functions/) lives. Default: a fresh shallow clone
# of the website repo (it tracks its own dist/), so this never depends on the
# state of the home-directory worktree, which has had dist/ go missing before.
SITE_DIR="${BATESAI_SITE_DIR:-}"
if [[ -z "$SITE_DIR" ]]; then
  SITE_DIR="$(mktemp -d)/site"
  git clone -q --depth 1 https://github.com/danielalanbates/website.git "$SITE_DIR"
fi
PROJECT_NAME="website"

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
  if $DRY_RUN; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

echo "==> Checking wrangler authentication"
if ! npx wrangler whoami 2>&1 | grep -qi "account"; then
  cat >&2 <<'EOF'
ERROR: wrangler is not authenticated.

  Run this yourself (it opens a browser and cannot be done non-interactively):

      npx wrangler login

  Then re-run this script.
EOF
  exit 1
fi

if ! $SCHEMA_ONLY; then
  echo "==> Syncing Pages Functions into $SITE_DIR"
  run mkdir -p "$SITE_DIR/functions/api/auth" \
               "$SITE_DIR/functions/api/fitness" \
               "$SITE_DIR/functions/_lib"
  run cp "$BACKEND_DIR/functions/api/auth/[[path]].js"    "$SITE_DIR/functions/api/auth/[[path]].js"
  run cp "$BACKEND_DIR/functions/api/fitness/[[path]].js" "$SITE_DIR/functions/api/fitness/[[path]].js"
  run cp "$BACKEND_DIR"/functions/_lib/*.js "$SITE_DIR/functions/_lib/"
fi

echo "==> Applying database schema (idempotent)"
run npx wrangler d1 execute batesai-db --remote --file="$BACKEND_DIR/schema.sql"

if $SCHEMA_ONLY; then
  echo "==> Schema applied. Skipping deploy (--schema)."
  exit 0
fi

echo "==> Deploying to Cloudflare Pages"
# Pages Functions are picked up from ./functions at the project root, so the
# deploy must run from the site directory, not from dist alone.
run bash -c "cd '$SITE_DIR' && npx wrangler pages deploy dist --project-name='$PROJECT_NAME' --branch=main --commit-dirty=true"

cat <<'EOF'

==> Deployed. Verify the API is actually live:

    curl -s -o /dev/null -w '%{http_code}\n' https://batesai.org/api/auth/verify
      401 = correct (no token supplied, endpoint exists)
      200 = WRONG - you are getting the SPA's HTML, the function did not deploy

    curl -s https://batesai.org/api/auth/verify | head -c 200

Remaining manual configuration in the Cloudflare dashboard (Pages -> Settings ->
Environment variables), since these are secrets and must not live in git:

    JWT_SECRET                    long random string (rotating it signs everyone out)
    OAUTH_GOOGLE_CLIENT_SECRET    from Google Cloud Console
    OAUTH_APPLE_CLIENT_SECRET     the Apple client secret JWT (expires every 6 months)
    ALLOWED_ORIGINS               https://batesai.org,http://localhost:4321

EOF
