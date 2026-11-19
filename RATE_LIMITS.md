# API rate limits

This branch adds server-side limits to the Supabase RPCs used by ILPO Ladder. They cannot be bypassed by changing frontend JavaScript. Limits use fixed windows as shown:

| Operation | Limit | Key |
| --- | --- | --- |
| Name/PIN lookup and sign-in (successful or failed) | 6 attempts/minute and 30/hour | Normalized entered name |
| Set or change PIN while signed in | 6 attempts/minute and 30/hour, plus member mutation budget | Player ID |
| Name sign-in, across all names | 300 attempts/minute | Whole application |
| Record a game (members and admins) | 5 attempts/minute | Player ID or admin Auth user ID |
| Member mutations, including disputes and PIN changes | 30 attempts/minute | Player ID |
| Admin mutations, including removing recorded games | 60 attempts/minute | Admin Auth user ID |
| Fetch ladder data | 120 requests/minute | Player ID or admin Auth user ID |
| Shared RPC flood ceiling, including invalid sessions | 1200 requests/minute | Whole application |

Recording a game consumes both its submission budget and its general mutation budget. Limits apply to attempts, so invalid submissions count too. Member budgets use the server-resolved player ID rather than a browser session token; signing in again or using another device does not reset them. Admin and name-based member sessions are separate identities.

A rejected request returns HTTP 429, a Retry-After header, and a message telling the member how many seconds to wait. A rejected game submission creates no match record. Rate-limited background reads keep the currently displayed leaderboard instead of clearing it.

Counters are incremented atomically with INSERT ... ON CONFLICT. Business errors are caught inside a nested block after budget charging; they return an error response instead of aborting the entire transaction, so failed attempts still count. Private implementation functions and the quota table remain inaccessible to browser roles. The private implementations can only be called through the guarded public RPCs.

The app does not trust a client-supplied IP header. Name sign-in has a per-name quota plus a shared ceiling, and other operations use authenticated account IDs or validated member sessions. First-time setup claims an unclaimed name. Later sign-ins require a six-digit PIN; guessing and failed PIN changes consume their limits. A new device or session does not reset these budgets.

Admin password authentication remains managed by Supabase Auth; this migration does not change provider settings. Logout is not part of the custom quota system.

## Activation

This is a branch-only change. Merge and deploy the frontend, and apply `supabase/migrations/20261119014949_rpc_rate_limits.sql` once to Supabase after the earlier migrations. The migration can also be applied before the frontend because errors use normal HTTP error responses understood by the existing client. A GitHub Pages deployment by itself does not apply the SQL.

No live database changes are made just by creating this branch.

## Verification

Run `npm test` and `npm run build`. Database tests use PGlite to apply the actual migrations and verify failed-attempt persistence, reset after expiry, per-player/session behavior, submission limits for both members and admins, shared ceilings, Retry-After response settings, and private-function access restrictions. Real multi-connection load and PostgREST HTTP integration should be checked on a staging project before activation; the production database is not modified for branch-only testing.

The PIN migration (`20261119181825_member_pins_and_rank_history.sql`) adds the hourly login budget and PIN-change budgets while preserving the existing game-submission, read, and mutation limits.
