# ILPO Ladder

Pool Elo rankings with a React/Vite frontend for GitHub Pages and a Supabase database/auth backend. Start with **[SETUP.md](SETUP.md)**.

## Included

- Starting Elo of 1000, K-factor 32; every confirmed game counts immediately.
- Google sign-in and an admin-managed member allowlist.
- Server-enforced admin permissions, member activation/deactivation, and opponent confirmation.
- Match disputes, admin resolution, voiding, and automatic historical rating recalculation.
- Player ratings, win/loss records, rating history, and head-to-head records.
- Responsive layout, 30-second refresh, and GitHub Pages project-path support.
- Database migration, automated PostgreSQL tests, and GitHub Actions deployment.
- Optional import script for the existing ChatGPT Sites data.

## Local use

Node.js 22.13 or later:

```sh
npm ci
cp .env.example .env.local
# Fill in your own Supabase project URL and publishable key.
npm run dev
```

Run `npm test` for PostgreSQL permission/rating checks, and `npm run build` for a type-checked static build in `dist/`.

## Architecture

The browser uses the official Supabase JS client with Google OAuth + PKCE. It calls two PostgreSQL RPCs: `get_house()` and `house_action(params)`. Those functions enforce membership and admin access on every request. Private tables have RLS enabled and no direct browser grants. Ratings are calculated in PostgreSQL, never accepted from browser input. Mutations run transactionally under an advisory lock, with confirmation order recorded explicitly and submission retries deduplicated by game ID.

Admin status is assigned explicitly using an Auth user UUID in the database. The first person to visit cannot claim admin status. An account must match an active member email or be an administrator to read any ladder data.

The frontend source can be public. Member emails, match history, tokens, and admin privileges are not bundled into it. Only the Supabase URL and **publishable** key belong in frontend configuration; never add a service-role key or Google client secret there.

## Current status

This is a converted, tested deployment package, not a newly hosted site. It has no connection to a live Supabase project until you configure one. Your existing ChatGPT Sites deployment has not been changed. Existing members and matches have not been copied automatically; see the optional migration instructions.

## Files

- `src/` — application and Supabase client
- `supabase/001_schema.sql` — schema, permissions, rating logic, RPCs
- `supabase/set-admin.sql` — explicit admin assignment template
- `.github/workflows/deploy.yml` — build/test/deploy to Pages
- `scripts/import-sites.mjs` — optional existing-data conversion
- `tests/database.test.mjs` — PostgreSQL tests using PGlite
- `SETUP.md` — account configuration and deployment guide

## Verification limits

Automated tests run the actual SQL functions in PGlite (PostgreSQL compiled to WebAssembly), with mock Supabase Auth tables and roles. They verify membership, permission enforcement, confirmation rules, idempotency, Elo updates, and void/replay behavior. They do not substitute for a live Google OAuth round trip or multi-connection concurrency/load testing. Before sharing the live site, complete the two-account checks in SETUP.md.
