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

Profiles load on demand and show the signed-in member’s wins and losses against the selected player, plus that player’s Elo chart. The default chart shows the last 50 games from their actual preceding Elo; All time loads the complete chart. Recorded games count immediately; disputed and voided results are excluded. Charts follow rating order and include the initial 1,000 rating.

Leaderboard movement compares current rank with rank 24 hours, 7 days, or 30 days ago. Historical Elo is reconstructed using rating order and audited result/dispute/void/unvoid events. Comparisons use the current active roster; players who joined after the cutoff display New. Imported matches without an audit trail use their original rating timestamp as the historical baseline.

## Ranking display and match pages

The leaderboard shows ten active players per page, preserving their overall rank numbers and movement values across pages. Recent matches appear above the Rating System box. Match history appears before disputed and voided results on Matches and in admin result management.

The `match_history` RPC returns ten recorded matches per page, newest first. It validates member sessions or administrator authentication and shares the existing read quotas. Ladder reads include three recent recorded results, disputed/voided results, total counts, and aggregate head-to-head stats. The new lightweight ladder summary omits all player chart histories and global matchup details. Each profile fetches its own complete head-to-head totals, recent chart, and ten initial results; older result pages are fetched separately.

## Lazy player history branch

On `lazy-player-history`, the frontend uses `ladder_summary`, `player_profile`, and `player_results`. Existing `get_house`/`member_house` endpoints remain unchanged for compatibility with main. Profiles, chart ranges, and result pages share a 64-entry memory cache keyed by signed-in identity and the ladder audit revision. Game changes update that revision, invalidating cached data after the next ladder refresh; sign-out and session changes clear the cache. Failed requests can retry, and stale responses cannot replace another open player.

Ladder polling stops when the browser tab is hidden and refreshes immediately on return. Open match/profile views also pause their automatic requests while hidden. Ordinary unchanged ladder refreshes do not refetch the current match-history page.

### Deployment and migration tracking

The initial schema is included as `20261027153948_initial_schema_baseline.sql`, before the feature migrations, so a fresh preview can replay the entire database setup. It skips initialization when the existing application schema is present. The original `001_schema.sql` remains a supported setup entry point.

Production migration IDs have been reconciled with the committed filenames after checking that each recorded SQL hash matches its file. The lazy-profile migration is activated before the frontend deployment. Future migrations should be deployed with the CLI using the committed migration IDs; applying SQL through a tool that generates a new ID requires reconciling its history before GitHub deployment.

Run `npm ci`, `npm test`, and `npm run build`. Tests cover the actual SQL, session/admin boundaries, shared read quotas, true preceding chart ratings, profile result pages, cache reuse/invalidation, failed/stale requests, hidden tabs, and sign-out.

## Dashboard and result corrections

Signed-in players have a Dashboard with rank, Elo, rating change over 24 hours/7 days/30 days, their full current winning or losing streak, their most-played opponent, and their ten latest recorded results. A new player’s rating-change comparison starts at 1,000 and is labeled Since joining. The account card displays overall rank and rounded Elo. Admin accounts also get personal stats when their verified login email is linked to their roster entry. Dashboard reads are scoped to the server-resolved signed-in player and share the normal read budget and revision-based cache.

The member game form has a searchable, keyboard-accessible opponent picker. Typed text must be matched to a roster entry; the winner remains limited to the signed-in player and the chosen opponent.

Admins can select Edit result from a match’s three-dot menu, including disputed or voided matches. They can correct the winner, loser, match date/time, or note. The original submission time and Elo sequence position are preserved; correcting the displayed match date does not reorder the rating sequence. Ratings, records, charts, head-to-head totals and current dashboard statistics are recalculated from the corrected results. Disputed and voided results stay excluded until restored.

Each edit stores its before/after match state in a private RLS-protected table and records an admin audit entry. Historical-rank calculations reconstruct the participants as they were at the requested cutoff, so a later correction does not silently rewrite earlier standings. PIN members cannot edit results, read the edit snapshots, or choose another member’s dashboard identity.

The leaderboard has Overall, Singles, and Doubles views. Overall uses K = 32 for 1v1 and K = 16 per player for 2v2. Singles and Doubles use K = 32 within their own format; doubles compares the average rating of each team. Each ladder starts at 1,000 and lists a player after their first rated match in that view. Existing games are singles. Game history and profiles identify 2v2 results, and profiles can switch between all three rating histories. Teammates do not count as head-to-head opponents.

All four players can dispute a rated doubles result. Admins can correct the teams or winner, void the result, or restore it. The match format and original rating order stay fixed. Apply the doubles migrations in order before deploying the corresponding frontend.
