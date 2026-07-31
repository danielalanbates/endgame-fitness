# BatesAI Auth + Endgame Fitness Deployment Guide

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    batesai.org                              │
├─────────────────────────────────────────────────────────────┤
│  Frontend: Astro (membership page)                          │
│  Backend: Cloudflare Workers (auth API)                     │
│  Database: Cloudflare D1 (users, workouts, progress)        │
│  OAuth: Apple Sign-In + Google Sign-In                      │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ JWT Auth
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              Endgame Fitness Mobile                         │
│  (React/Vanilla JS PWA)                                     │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **Cloudflare Account** - Logged in via Wrangler CLI
2. **Apple Developer Account** - For Sign in with Apple
3. **Google Cloud Console** - For Google OAuth

## Step 1: Set Up Cloudflare D1 Database

```bash
cd /Users/daniel/Library/Mobile\ Documents/com~apple~CloudDocs/Code/12-AI_Coding_Tools/github/batesai-website

# Create D1 database
wrangler d1 create batesai-db

# Create tables
wrangler d1 execute batesai-db --file=schema.sql
```

## Step 2: Configure OAuth Providers

### Apple Sign-In

1. Go to [Apple Developer Certificates](https://developer.apple.com/account/resources/certificates/list)
2. Create "Sign in with Apple" certificate
3. Create Service ID with redirect URL: `https://batesai.org/api/auth/oauth/apple`
4. Update `wrangler.toml`:
   - `APPLE_CLIENT_ID` = Service ID
   - `APPLE_TEAM_ID` = Your Team ID
   - `APPLE_KEY_ID` = Key ID from certificate
   - `APPLE_PRIVATE_KEY` = Private key content

### Google Sign-In

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create OAuth 2.0 credentials
3. Authorized redirect URI: `https://batesai.org/api/auth/oauth/google`
4. Update `wrangler.toml`:
   - `GOOGLE_CLIENT_ID` = Client ID
   - `GOOGLE_CLIENT_SECRET` = Client Secret

## Step 3: Deploy to Cloudflare Pages

```bash
# Install dependencies
npm install

# Build and deploy
npm run build
wrangler pages deploy ./dist --project-name=batesai-org
```

## Step 4: Update Endgame Fitness Mobile API URL

Edit `/Users/daniel/Code/endgame-fitness-mobile/auth.js`:

```javascript
const auth = {
    API_URL: 'https://batesai.org/api/auth',  // Update when deployed
    // ...
};
```

## Step 5: Test Authentication Flow

1. Visit `https://batesai.org/membership.html`
2. Create account or login
3. Open Endgame Fitness Mobile
4. Click "Sign In" in Profile tab
5. Verify sync works

## Database Schema

### Tables Created:
- `users` - User accounts (email, password hash, OAuth info)
- `sessions` - Active sessions with JWT tokens
- `workouts` - Workout logs
- `workout_exercises` - Exercises within workouts
- `meso_cycles` - Saved meso cycles
- `user_programs` - Custom programs
- `progress_metrics` - Weight, reps, PRs tracking
- `talent_unlocks` - Talent tree specializations

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/auth/register` | POST | Create new account |
| `/api/auth/login` | POST | Login with email/password |
| `/api/auth/oauth` | POST | OAuth callback (Apple/Google) |
| `/api/auth/verify` | GET | Verify JWT token |
| `/api/workouts` | POST | Save workout (auth required) |
| `/api/user/data` | GET | Load user data (auth required) |

## Environment Variables

Update `wrangler.toml` with production values:

```toml
[vars]
JWT_SECRET = "your-production-secret-min-32-chars"
APPLE_CLIENT_ID = "com.batesai.endgamefitness"
APPLE_TEAM_ID = "XXXXXXXXXX"
APPLE_KEY_ID = "XXXXXXXXXX"
APPLE_PRIVATE_KEY = "-----BEGIN PRIVATE KEY-----..."
GOOGLE_CLIENT_ID = "xxxxx.apps.googleusercontent.com"
GOOGLE_CLIENT_SECRET = "GOCSPX-xxxxx"
FRONTEND_URL = "https://batesai.org"
```

## Security Notes

- JWT tokens expire after 7 days
- Passwords are hashed with SHA-256 + salt
- All API calls require Bearer token (except register/login)
- CORS enabled for batesai.org domain only

## Next Steps

1. Deploy membership page to batesai.org
2. Test OAuth flows with real Apple/Google accounts
3. Add Cloudflare Turnstile for bot protection
4. Implement workout sync on app background/foreground
5. Add password reset via email
