import {test} from 'node:test';import assert from 'node:assert/strict';import {readFile,readdir} from 'node:fs/promises';import {PGlite} from '@electric-sql/pglite';import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
test('a fresh preview can replay migrations without manually running 001_schema.sql',async()=>{
 const db=new PGlite({extensions:{pgcrypto}});try{
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon;`);
 const files=(await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')).sort();assert.ok(files[0].endsWith('_initial_schema_baseline.sql'));
 for(const file of files)await db.exec(await readFile(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'));
 const id=(await db.query("insert into private.members(name) values('Fresh Player') returning id")).rows[0].id;const session=(await db.query("select public.member_login('Fresh','Player','012345',true) result")).rows[0].result;assert.equal(session.id,id);
 await db.exec('set role anon');const data=(await db.query('select public.ladder_summary($1) result',[session.token])).rows[0].result;assert.equal(data.players.length,1);assert.equal(data.players[0].rating,1000);assert.equal(data.players[0].history,undefined);assert.equal((await db.query('select public.player_profile($1,$2) result',[id,session.token])).rows[0].result.chart.starting_rating,1000);
 await db.exec('reset role');const before=(await db.query("select pg_get_functiondef('private.perform_action(uuid,uuid,boolean,jsonb)'::regprocedure) definition")).rows[0].definition;
 await db.exec(await readFile(new URL('../supabase/migrations/'+files[0],import.meta.url),'utf8'));const after=(await db.query("select pg_get_functiondef('private.perform_action(uuid,uuid,boolean,jsonb)'::regprocedure) definition")).rows[0].definition;assert.equal(before,after);assert.equal((await db.query('select count(*)::int n from private.members')).rows[0].n,1);
 }finally{await db.close()}
});
