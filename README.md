# Find the Spy

A cross-device social deduction game built with **Next.js**, **Supabase Auth, Postgres and Realtime**, and designed for deployment on **Vercel**. Players use guest sessions—no player account or password—and share a six-character room code.

## Game modes

- **Classic:** 3–8 players. One secret Spy; every Agent receives the same exact location, while the Spy receives only the location category.
- **Spy Duel:** exactly 2 players. The Spy role rotates between players across three rounds.
- Each game has three rounds, a 90-second investigation, a 20-second private vote, and a 20-second final guess if the Spy is caught. Scores, deadline transitions, tie rules, vote aggregation and the final leaderboard are calculated by Postgres functions.

## Architecture and privacy

- The browser creates a Supabase anonymous-auth session. The Supabase publishable/anon key is public by design; no service-role or secret key is needed or included.
- Game actions go to `POST /api/game-action`. The Next.js Node route checks the bearer token with Supabase Auth and accepts only a fixed list of actions and argument shapes. It forwards the same guest JWT to Postgres, where each security-definer RPC checks `auth.uid()`, membership, role, phase, deadlines, capacity and rate limits.
- Secret roles, exact locations, individual ballots and action counters stay in private Postgres tables. RLS and table grants block direct client reads and writes. The Spy's own game-state response contains no exact location before the round ends. Vote identities are never returned; only post-vote aggregate counts are shown.
- Lobby, room and chat changes use Supabase Realtime Postgres Changes, with member-scoped RLS. The client falls back to polling if a Realtime subscription is unavailable.
- Anonymous-session identity is stored by Supabase in the browser so a refresh can restore that player's own room. The app does not use local storage as the shared game database.

Anonymous Supabase users receive the `authenticated` database role, so the policies in the schema apply to them. See [Supabase Anonymous Sign-Ins](https://supabase.com/docs/guides/auth/auth-anonymous), [Next.js environment variables](https://nextjs.org/docs/app/guides/environment-variables), and [Vercel Git deployments](https://vercel.com/docs/git).

## Requirements

- Node.js 20.9 or newer (Node 24 was used to build this project).
- A Supabase project with anonymous sign-ins and Realtime enabled.
- A GitHub, GitLab, or Bitbucket repository and Vercel account for hosted deployment.

## Run locally

1. Copy `.env.example` to `.env.local`.
2. Replace the two placeholder values with your Supabase Project URL and **publishable key** (or the legacy `anon public` key). Do not use a secret or `service_role` key.
3. Install and run:

   ```sh
   npm install
   npm run dev
   ```

4. Open `http://localhost:3000`. Open a second browser profile or a second device to test joining. `npm run build` checks the production build; `npm test` runs API-contract unit tests.

The environment template contains placeholders only. Keep `.env.local` untracked; it is ignored by `.gitignore`.

## Supabase project setup — actions you perform

1. Sign in at [Supabase](https://supabase.com/dashboard) and select **New project**. Choose or create an organization, enter a project name and database password, select a region, and create it. Wait until provisioning completes.
2. In the project dashboard, open **Authentication → Sign In / Providers** (the label may appear as **Providers**). Enable **Anonymous sign-ins** and save.
3. In **SQL Editor**, select **New query**. Open `supabase/schema.sql` from this project, copy the entire file, paste it into the editor, and select **Run**. Use this combined schema once on a fresh database. Alternatively, apply the six files under `supabase/migrations/` in numeric order from `001` to `006`; do not apply both paths. If your existing project already has all six migrations applied, do not rerun them.
4. Confirm the migration completed successfully. The migration adds the room, player, chat, location, round, vote, and rate-limit tables; RLS policies; trusted RPCs; expiry and recovery logic; and Realtime publication entries for the shared room tables.
5. In **Project Settings → API**, copy the **Project URL** and **publishable key** (older projects may label the key `anon public`). Never copy the `service_role` key.
6. For the local copy, put those values in `.env.local` using the names in `.env.example`, then restart `npm run dev`.
7. In the Supabase Realtime settings, confirm the project Realtime service is enabled. The SQL adds the room, player and chat tables to `supabase_realtime`. The app has a polling fallback, but Realtime must be enabled for push updates.

### Existing Supabase project

If you are continuing with the Supabase project already used for development, it may already contain migrations `001`–`006`. Confirm you applied the final security/recovery migration before using it. You can check the SQL Editor for the `public.touch_game_room` and `public.get_game_state` functions. Do not paste the schema into a production database without first confirming its migration state.

## Push this project to GitHub — actions you perform

This workspace is not currently connected to a Git repository. Create an empty repository first:

1. In GitHub, choose **New repository**. Choose a repository name, select **Private** if you want the source private, and do not initialize it with a README or `.gitignore`.
2. Open a terminal in this project folder and run these commands, replacing the two angle-bracket values with your GitHub owner and repository name:

   ```sh
   git init
   git add .
   git commit -m "Prepare Find the Spy for Vercel"
   git branch -M main
   git remote add origin https://github.com/<YOUR_GITHUB_NAME>/<YOUR_REPOSITORY>.git
   git push -u origin main
   ```

3. If Git asks to authenticate, use GitHub's browser sign-in prompt or Git Credential Manager. Do not paste a token into the source or a chat.

## Deploy on Vercel — actions you perform

1. Sign in at [Vercel](https://vercel.com/dashboard) and choose **Add New → Project**.
2. Connect GitHub if prompted, find the repository you just pushed, and choose **Import**.
3. Leave the Framework Preset as **Next.js** and the Root Directory as `./`.
4. Under **Environment Variables**, add the following for **Preview** and **Production** (and Development if you use Vercel's local environment pull):
   - `NEXT_PUBLIC_SUPABASE_URL` — your Supabase Project URL.
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY` — your Supabase publishable key or legacy `anon public` key.
5. Select **Deploy**. Vercel builds using `npm run build` and serves the Next.js Node route as a serverless function. No special output directory is needed.
6. When deployment finishes, open the Vercel-provided `https://…vercel.app` URL. Keep the repository and dashboard access private as desired; the deployed game page itself must be reachable by players to play.

The `NEXT_PUBLIC_` prefix means a value is bundled into browser JavaScript. The anon/publishable key is designed to be public and is protected by RLS and the database RPC checks. **Never set `SUPABASE_SERVICE_ROLE_KEY`, a secret key, or a database password as a `NEXT_PUBLIC_` variable.** This app does not need any of those privileged credentials.

## Test the deployed public URL — actions you perform

1. Open the Vercel URL in two separate browser profiles or on two devices.
2. In the first, create a room. In the second, join with the displayed code and a different nickname. Confirm both rosters update.
3. Start Classic with 3–8 sessions, or Spy Duel with 2. Confirm only Agents see the location and the Spy sees only its category.
4. Send chat messages and confirm both devices receive them. Test refresh during investigation, voting and the Spy guess; the same guest should return to the same room and role.
5. Vote from each Agent, confirm ballots remain hidden until voting ends, and complete all three rounds. Check the final score order.
6. Close the host browser and wait at least 45 seconds, then confirm an active player receives host controls. Check a room-full join and a duplicate nickname as well.
7. In Supabase, inspect **Logs → Postgres** and **Logs → Auth** for database/auth errors. In Vercel, inspect the deployment **Build Logs** and **Functions** logs if the API returns an error.

Do not announce the site as release-ready until the deployed URL passes those checks from genuinely separate devices. The local project and shared backend can be tested here; dashboard setup, repository creation, deployment, and physical-device public-URL testing require your external accounts and actions.

## Commands

```sh
npm install
npm run dev
npm test
npm run build
npm start
```

`npm start` serves the production build locally on port 3000.
