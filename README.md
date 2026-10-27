# ILPO Ladder

Pool Elo rankings with a React/Vite frontend on GitHub Pages and a Supabase backend.

## Access

- Members enter their first and last name. Only an exact active roster match is accepted; case and extra whitespace are ignored.
- This is a roster check, not proof of identity: anyone who knows a listed name can use that member account.
- Name sessions last 30 days and are stored in the browser. Supabase stores only hashed session tokens. Signing out revokes that token; deactivating a member revokes all of their name sessions.
- Administrators sign in separately with a Supabase Auth email and password. Admin rights are assigned explicitly in `private.admins`; a member name never grants admin rights.
- Members record their own games and confirm or dispute their opponents' submissions. Only admins can add/deactivate members, resolve disputes, or void games. Voided games stay in the audit history and ratings are recalculated.

## Deploy

Follow [SETUP.md](SETUP.md). Google OAuth and a separate email service are not needed for member access.

```sh
npm ci
# Create .env.local using your Supabase URL and publishable key.
npm run dev
npm test
npm run build
```

The frontend calls PostgreSQL RPCs. Private tables have RLS enabled with no direct browser grants. The name-login RPC validates the roster; member RPCs validate a random expiring session token and derive the member ID server-side. They never trust an admin flag or member ID supplied by the browser. Admin RPCs check the Supabase Auth account against `private.admins`. Private helper functions are not callable by browser roles. Public SECURITY DEFINER RPCs are intentional and enforce their own authorization.

Initial database schema: `supabase/001_schema.sql`. Name-access update: `supabase/migrations/*_roster_name_access.sql`. Apply the update to an existing database once; do not rerun the initial schema over live tables. GitHub deployments build the frontend only and do not apply database migrations.

Tests run the real SQL in PGlite, including name normalization, absent/inactive names, invalid/expired/revoked sessions, admin boundaries, opponent confirmation, duplicate submissions, and Elo recalculation. Admin passwords are handled by Supabase Auth and are never stored in application tables or source code.
