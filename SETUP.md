# Deploy ILPO Ladder on GitHub Pages + Supabase

You need a GitHub account, a Supabase project, and a Google Cloud project for Google sign-in. There are no paid dependencies required by this app; provider free-tier quotas and account restrictions still apply. A custom domain is optional.

The existing ChatGPT-hosted site stays as it is. This package is a separate deployment.

## 1. Create your GitHub repository

Create a repository such as `ilpo-ladder`. For GitHub Free, use a public repository for GitHub Pages. Upload the **contents** of this folder, including `.github/workflows/deploy.yml`, rather than uploading the ZIP itself. Do not upload `node_modules`, `dist`, `.env.local`, or member-data exports.

Use `main` as the default branch. In **Settings → Pages → Build and deployment**, select **GitHub Actions**. An early workflow failure is expected until you add the Supabase configuration in step 4.

The normal project URL is `https://YOUR_USERNAME.github.io/ilpo-ladder/`. Use the exact URL GitHub shows in Settings → Pages, including the repository path and trailing slash. The deployment workflow automatically configures the frontend asset base path, including for a root user site or a custom domain.

## 2. Create the Supabase database

1. Create a new Supabase project.
2. Open **SQL Editor**, paste `supabase/001_schema.sql`, and run it once.
3. In the project's connection/API settings, copy the **Project URL** and **publishable key**. A legacy `anon` key also works, but use the publishable key when available.
4. Leave the `private` database schema out of exposed API schemas. The default `public` API schema exposes the two RPCs; the underlying tables are private.

Never put a `service_role` key, secret API key, database password, or Google client secret into the frontend or GitHub repository. The publishable key is intended for browser use; the database functions enforce permissions independently of it.

## 3. Enable Google sign-in

Follow the official guide: https://supabase.com/docs/guides/auth/social-sign-in/auth-google

1. Create/configure a Google Cloud project and its OAuth consent screen (Google Auth Platform).
2. Create an OAuth client of type **Web application**.
3. Use the Supabase Google-provider callback URL as an authorized redirect URI. It normally looks like `https://YOUR_PROJECT.supabase.co/auth/v1/callback`; copy the exact value from Supabase.
4. Configure the relevant web origin in Google as directed by the provider guide (your GitHub Pages origin, without the repository path).
5. Enable Google in **Supabase → Authentication → Sign In / Providers**, and enter the Google client ID and secret there. Keep the secret in Supabase, not in this code.
6. In **Supabase → Authentication → URL Configuration**, set the Site URL to the exact GitHub Pages URL with its repository path and trailing slash. Add the same URL to the redirect allowlist.
7. For local development, also allow `http://localhost:5173/` as a Supabase redirect URL.
8. If the Google OAuth app is in Testing mode, add yourself and participating members as test users, or configure the Google app for the appropriate published audience. Use only the basic identity scopes needed for sign-in. Members still need to be on your app's active roster.

Keep Google sign-ups enabled so added members can sign in for the first time. Creating an Auth account does **not** grant ladder access. The app independently checks its member allowlist. This app does not use Supabase email/password or magic-link delivery, so no SMTP service is needed for its sign-in flow.

## 4. Configure and deploy GitHub Pages

In **GitHub repository → Settings → Secrets and variables → Actions → Variables**, create:

| Repository variable | Value |
| --- | --- |
| `VITE_SUPABASE_URL` | Your Supabase project URL |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | Your Supabase publishable key (or legacy anon key) |

Use **repository variables**, not environment variables scoped to a deployment job or GitHub secrets: the included workflow reads `vars.*` during its build job. These two browser-safe values will be embedded in the static bundle.

Open **Actions → Deploy ILPO Ladder → Run workflow**, on `main`. The workflow installs locked dependencies, runs database tests, builds the frontend, and deploys it to Pages.

Future pushes to `main` deploy automatically. Updating repository variables requires a new build/deploy. Changing the database schema requires separately applying a reviewed new SQL migration in Supabase; GitHub Pages does not apply database migrations.

## 5. Make yourself an administrator

1. Open the deployed site and sign in with Google once.
2. You will initially see a message that your account is not on the active member list. This is expected: no one is automatically made an admin.
3. In **Supabase → Authentication → Users**, find your own account and copy its user UUID.
4. Open `supabase/set-admin.sql`, replace the placeholder with that UUID, and run it in the Supabase SQL Editor.
5. Refresh the app. The **Admin** tab will appear.
6. Add yourself as a member if you also want to play; use the same Google account email. Admin rights and player records are separate.

## 6. Add members

Use **Admin → Add member**, entering each person's name and the email on their Google account. Send them the GitHub Pages link. They can sign in immediately; there is no separate site-sharing invitation to send.

- Active members can view the ladder, submit their own games, and confirm or dispute an opponent's submission.
- Admins can manage members, record games, resolve disputed games, and void results.
- A member without an email is admin-managed and cannot sign in as that player.
- Deactivating a member removes their app access and prevents new games for that member while retaining history.
- Other people may load the public sign-in page but cannot read ladder data or change anything.

If you add a member with the wrong email, correct their `email` in `private.members` in the Supabase dashboard/SQL Editor (lowercase). There is no member-email editor in this version of the app.

## 7. Verify before sharing

Use your account and one second account, preferably in separate browser profiles:

1. Add two members and confirm both start at 1000 Elo.
2. Sign in as the second member: no Admin tab should appear.
3. Record a game as one member; it stays pending and ratings do not change.
4. Sign in as the opponent and confirm: equal-rated players become 1016 and 984.
5. Confirm the same result again through a repeated request: it must not award points twice.
6. As admin, void the game: ratings return to 1000 and the voided record remains.
7. Sign in with an unlisted account: ladder access must be denied.
8. Refresh the page at the repository URL and verify the assets and Google callback load correctly.

The GitHub deployment's automated tests cover the database behavior. The Google OAuth configuration and actual hosting require these live checks in your accounts.

## Optional: migrate existing members and games

Skip this if you want to start with an empty ladder. Existing data is **not** included in this package.

1. Before adding any members to the new Supabase app, sign in as admin on the old site in your browser.
2. Open the old site's `/api/house` path on the same origin and save its JSON response as `house-export.json`. This export contains member emails; keep it private.
3. From this project directory, run:

   ```sh
   node scripts/import-sites.mjs house-export.json import.sql
   ```

4. Review `import.sql` and run it in Supabase SQL Editor **after** `001_schema.sql`. It refuses to import into a nonempty roster/match database to prevent accidental merges.
5. Run the admin assignment from step 5, if not already done. Old ChatGPT user IDs do not become Supabase admin IDs.
6. Compare game counts and ratings between the old and new sites. Confirm the imported member emails match the Google accounts members will use.
7. Use only the new site for recording games after switching over; the two deployments do not synchronize.

The import keeps member/game IDs, results, dates, notes, active status, and the original confirmed-game ordering. It recalculates ratings from confirmed games. It cannot recover historical authentication actor IDs that the old export does not include. Do not commit the JSON or generated SQL to GitHub.

## Troubleshooting

- **Setup required:** add both repository variables and rerun the deployment.
- **Google redirect error:** distinguish Google's callback URI (Supabase `/auth/v1/callback`) from Supabase's return URL (your GitHub Pages app URL).
- **Account not on member list:** match the Google email to an active member, or complete the explicit admin assignment.
- **RPC not found:** apply `001_schema.sql` to the same project configured in the frontend.
- **Missing CSS/JS or 404:** use the included Pages workflow; do not deploy a development server or the unbuilt `src` directory.
- **OAuth code expired or verifier missing:** start a new sign-in in the same browser tab/profile. Do not copy the callback URL between browsers.
- **Free project unavailable after inactivity:** inspect the project's status in Supabase and restore/resume it if required by its current free-plan policy.

References: https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages and https://supabase.com/docs/guides/database/functions
