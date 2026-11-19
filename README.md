# ILPO Ladder

Pool Elo rankings with a React/Vite frontend on GitHub Pages and a Supabase backend.

## Access

- Members enter their first and last name, then their six-digit PIN. On first sign-in they explicitly create and confirm a new PIN. Case and extra whitespace in names are ignored.
- Initial PIN setup is a first claim of a roster name, not independent identity verification. Once claimed, the name requires its PIN. Admins can reset a forgotten PIN; the member then creates a new one.
- Member sessions last 30 days and are stored in the browser. Supabase stores only hashed session tokens. Signing out revokes that token; deactivating a member revokes all their sessions. Changing a PIN requires the current PIN, rotates the changing browser’s token, and signs out other devices. PIN hashes use salted bcrypt (cost 10); PINs are never stored in browser storage or returned in API responses.
- Administrators sign in separately with a Supabase Auth email and password. Admin rights are assigned explicitly in `private.admins`; a member name never grants admin rights.
- Members record their own games, which affect ratings immediately. Either player can dispute a recorded result. Only admins can add/deactivate members, resolve disputes, or void games. Voided games stay in the audit history and ratings are recalculated.

## Deploy

Follow [SETUP.md](SETUP.md). Google OAuth and a separate email service are not needed for member access.

```sh
npm ci
# Create .env.local using your Supabase URL and publishable key.
npm run dev
npm test
npm run build
```

The frontend calls PostgreSQL RPCs. Private tables have RLS enabled with no direct browser grants. The member-login RPC validates the roster and PIN; member RPCs validate a random expiring session token and derive the member ID server-side. They never trust an admin flag or member ID supplied by the browser. Admin RPCs check the Supabase Auth account against `private.admins`. Private helper functions are not callable by browser roles. Public SECURITY DEFINER RPCs are intentional and enforce their own authorization.

Initial database schema: `supabase/001_schema.sql`. Database updates: `supabase/migrations/*.sql`, applied once each in filename order. The Elo replay update includes explicit predicates required by the API safe-update guard. Apply only unapplied updates to an existing database; do not rerun the initial schema over live tables. GitHub deployments build the frontend only and do not apply database migrations.

Tests run the real SQL in PGlite, including PIN setup/login/change/reset and brute-force limits, historical rank reconstruction, name normalization, absent/inactive names, invalid/expired/revoked sessions, admin boundaries, immediate rating updates, disputes, duplicate submissions, and Elo recalculation. Admin passwords are handled by Supabase Auth and are never stored in application tables or source code.

## Branch update: request limits and admin layout

See [RATE_LIMITS.md](RATE_LIMITS.md) for server quotas, the new migration, activation order, and verification limits. Result administration appears above member management. Disputed results have their own collapsed list. Admins can remove recorded games using Remove; the record is voided and Elo is recalculated.

## Player profiles and movement

Profiles show the signed-in member’s wins and losses against the selected player, plus that player’s Elo chart. Recorded games count immediately; disputed and voided results are excluded. Charts follow rating order and include the initial 1,000 rating.

Leaderboard movement compares current rank with rank 24 hours, 7 days, or 30 days ago. Historical Elo is reconstructed using rating order and audited result/dispute/void/unvoid events. Comparisons use the current active roster; players who joined after the cutoff display New. Imported matches without an audit trail use their original rating timestamp as the historical baseline.

## Ranking display and match pages

The leaderboard initially shows the top five active players. Remaining rankings are collapsed by default, preserving their original rank numbers and movement values when expanded. Match history appears before disputed and voided results on Matches and in admin result management.

The `match_history` RPC returns ten recorded matches per page, newest first. It validates member sessions or administrator authentication and shares the existing read quotas. Ladder reads include three recent recorded results, disputed/voided results, total counts, and aggregate head-to-head stats. Profiles retain complete rating charts and head-to-head records; player chart histories are still included in ladder data.
