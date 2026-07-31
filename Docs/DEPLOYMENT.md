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
│  (PWA with Cloud Sync)                                      │
└─────────────────────────────────────────────────────────────┘
```

## Quick Deploy Steps

### 1. Set Up Cloudflare D1 Database

```bash
cd "/Users/daniel/Library/CloudStorage/GoogleDrive-danielalanbates@gmail.com/My Drive/X10 Backup/AIcode/12-AI_Coding_Tools/github/batesai-website"

# Create D1 database
wrangler d1 create batesai-db

# Note the database_id from output and update wrangler.toml

# Create tables
wrangler d1 execute batesai-db --file=schema.sql
```

### 2. Configure OAuth Providers

#### Apple Sign-In
1. Go to [Apple Developer Certificates](https://developer.apple.com/account/resources/certificates/list)
2. Create "Sign in with Apple" certificate
3. Create Service ID with redirect URL: `https://batesai.org/api/auth/oauth/apple`
4. Update `wrangler.toml`:
   ```toml
   APPLE_CLIENT_ID = "com.batesai.endgamefitness"
   APPLE_TEAM_ID = "XXXXXXXXXX"
   APPLE_KEY_ID = "XXXXXXXXXX"
   APPLE_PRIVATE_KEY = "-----BEGIN PRIVATE KEY-----..."
   ```

#### Google Sign-In
1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create OAuth 2.0 credentials
3. Authorized redirect URI: `https://batesai.org/api/auth/oauth/google`
4. Update `wrangler.toml`:
   ```toml
   GOOGLE_CLIENT_ID = "xxxxx.apps.googleusercontent.com"
   GOOGLE_CLIENT_SECRET = "GOCSPX-xxxxx"
   ```

### 3. Deploy to Cloudflare Pages

```bash
# Install dependencies
npm install

# Build and deploy
npm run build
wrangler pages deploy ./dist --project-name=batesai-org
```

### 4. Update Endgame Fitness API URL

The app is configured to use `https://batesai.org/api/auth`. Update in `auth.js` if needed:

```javascript
const auth = {
    API_URL: 'https://batesai.org/api/auth',
    // ...
};
```

### 5. Test Authentication Flow

1. Visit `https://batesai.org/membership`
2. Create account or login
3. Open Endgame Fitness Mobile (serve locally or deploy)
4. Click "Sign In" in Profile tab
5. Verify cloud sync works

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
| `/api/auth/oauth/apple` | POST | Apple OAuth callback |
| `/api/auth/oauth/google` | POST | Google OAuth callback |
| `/api/auth/verify` | GET | Verify JWT token |
| `/api/workouts` | POST | Save workout (auth required) |
| `/api/user/data` | GET | Load user data (auth required) |
| `/api/talents` | POST | Unlock talent (auth required) |

## Security Notes

- JWT tokens expire after 7 days
- Passwords are hashed with SHA-256 + salt
- All API calls require Bearer token (except register/login)
- CORS enabled for batesai.org domain only

## Local Testing

### Test Auth API Locally
```bash
# Start Cloudflare dev server
wrangler dev

# API will be available at http://localhost:8788/api/auth/...
```

### Test Endgame Fitness Locally
```bash
cd /Users/daniel/Code/endgame-fitness-mobile
python3 -m http.server 8000
# Open http://localhost:8000
```

## Troubleshooting

### "Database not found"
- Ensure D1 database is created and `database_id` in `wrangler.toml` matches

### "OAuth failed"
- Verify redirect URIs match exactly in Apple/Google console
- Check environment variables are set correctly

### "Token verification failed"
- Ensure `JWT_SECRET` is at least 32 characters
- Check system clock is synchronized

## Next Steps

1. ✅ Deploy membership page to batesai.org
2. ✅ Test OAuth flows with real Apple/Google accounts
3. ⏳ Add Cloudflare Turnstile for bot protection
4. ⏳ Implement password reset via email
5. ⏳ Add subscription tiers with Stripe integration
