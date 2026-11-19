# ILPO Ladder setup

## GitHub Pages

Use the included `.github/workflows/deploy.yml`. In repository Settings → Pages, set Source to **GitHub Actions**. Do not also publish the source branch using the branch-based Pages builder.

Under Settings → Secrets and variables → Actions → Variables, add:

- `VITE_SUPABASE_URL`: your Supabase project URL.
- `VITE_SUPABASE_PUBLISHABLE_KEY`: your Supabase publishable key (legacy anon keys also work).

Never use a secret/service-role key in browser configuration. Push to `main` or run the deployment workflow. Repository base paths are handled automatically.

## Database

For a new project, run `supabase/001_schema.sql` in Supabase SQL Editor first, followed by every file in `supabase/migrations/` in filename order.

For the existing ILPO project, the initial schema already exists. Apply only unapplied updates. The name-access update is also applied during the assisted setup; inspect migration history before rerunning it.

Keep `private` out of the exposed API schemas. The default `public` schema exposes the app's authorized RPCs.

## First administrator

The initial admin must be set up once. Name login never makes someone an admin.

1. In Supabase → Authentication → Users, use **Add user → Create new user** to create your own email/password account. Choose the password yourself and mark the email as confirmed in that admin workflow. This creates the admin login without requiring an email provider.
2. Copy your new Auth user UUID and replace the placeholder in `supabase/set-admin.sql`. Run that SQL in the project's SQL Editor. Alternatively, ask your setup assistant to assign the account after you've created it.
3. Open the app, select **Admin sign-in**, and enter your email and password.
4. Add yourself and the other members with first and last names. Members do not need Auth accounts or emails.

Use only accounts you intend to authorize in `private.admins`. A Supabase account without an entry in that table cannot manage the roster or void matches. Additional admins can be set up the same way. Admin password changes can be handled in Supabase; self-service password-reset email is not part of this version.

## Member use

Members open the site and enter their roster first and last name. On the first sign-in, a clearly labeled setup screen asks them to create and confirm a six-digit PIN. Later sign-ins require that PIN. Name matching ignores capitalization and repeated whitespace. Names must be unique among active members; use distinct full names if two people share a name. There is no public roster picker before sign-in.

Members can record games in which they played. Ratings update immediately when a game is recorded. Either player can dispute a result; disputed games stop affecting Elo until an admin restores or removes them. Only admins can void games or deactivate members. These actions retain the historical records.

First-time PIN setup claims an unclaimed roster name; it does not independently verify identity. After setup, the correct PIN is required. Members can use Change PIN in their own player profile (opened from the account info in the sidebar) with their current PIN. Admins can use Reset PIN in member management for forgotten PINs. Resetting signs out all member devices; changing a PIN keeps the changing browser signed in and revokes other sessions. Existing name-only sessions must complete PIN setup before recording or disputing games.

## Checks

- Unknown and inactive names must be rejected.
- An unclaimed valid name must show explicit PIN setup. A claimed name must require the correct six-digit PIN.
- Name sessions must never show the Admin tab or allow admin RPC actions.
- Admin email/password login must show the Admin tab.
- Recorded games update ratings immediately and only once; voiding a game recalculates history.
- Deactivating a member blocks their existing session and future sign-ins.

## Optional old-site import

The existing import tool remains available: `node scripts/import-sites.mjs house-export.json import.sql`.

Use a private admin export from the original ChatGPT Sites `/api/house` endpoint. Review and apply the generated SQL only to an empty roster/match database after the schema and name-access update. Old Auth IDs do not carry over as Supabase admins. Existing names must include first and last names and be unique among active members for name login to work. Keep exports and generated import SQL out of GitHub.

## Request limits

Apply all unapplied migrations in filename order, including `20261119014949_rpc_rate_limits.sql`, to activate the custom server-side limits. See RATE_LIMITS.md. Branch-only changes are not automatically applied to your live Supabase project.
