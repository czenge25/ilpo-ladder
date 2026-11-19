import {test} from 'node:test';import assert from 'node:assert/strict';import {readFile,readdir} from 'node:fs/promises';import {PGlite} from '@electric-sql/pglite';import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';

test('automatic scoring, legacy migration, disputes, and original-order restoration',async t=>{
 const db=new PGlite({extensions:{pgcrypto}});try{
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon;`);
 await db.exec(await readFile(new URL('../supabase/001_schema.sql',import.meta.url),'utf8'));
 const migrations=(await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')).sort(),latest=migrations.pop();
 for(const f of migrations)await db.exec(await readFile(new URL('../supabase/migrations/'+f,import.meta.url),'utf8'));
 const [a,b,c]=(await db.query("insert into private.members(name,pin_hash) values('Alice Example',extensions.crypt('123456',extensions.gen_salt('bf',4))),('Bob Example',extensions.crypt('123456',extensions.gen_salt('bf',4))),('Casey Example',extensions.crypt('123456',extensions.gen_salt('bf',4))) returning id")).rows.map(p=>p.id);
 const admin='00000000-0000-0000-0000-000000000001';await db.query('insert into auth.users values($1,$2,now())',[admin,'admin@example.test']);await db.query('insert into private.admins values($1)',[admin]);
 const legacy=crypto.randomUUID(),legacyVoid=crypto.randomUUID(),legacyDispute=crypto.randomUUID();
 await db.query("insert into private.matches(id,winner,loser,status,created,status_before_void) values($1,$4,$5,'pending',now()-interval '2 days',null),($2,$4,$5,'void',now()-interval '2 days','pending'),($3,$4,$5,'disputed',now()-interval '2 days',null)",[legacy,legacyVoid,legacyDispute,a,b]);
 await db.exec(await readFile(new URL('../supabase/migrations/'+latest,import.meta.url),'utf8'));
 const auth=async adminOn=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[adminOn?admin:'']);await db.exec(adminOn?'set role authenticated':'set role anon')};
 const unwrap=r=>{if(r?.error)throw Error(r.message||r.error);return r};
 const login=async first=>unwrap((await db.query("select public.member_login($1,'Example','123456',false) result",[first])).rows[0].result);
 const action=async p=>unwrap((await db.query('select public.house_action($1::jsonb) result',[JSON.stringify(p)])).rows[0].result);
 const member=async(token,p)=>unwrap((await db.query('select public.member_action($1,$2::jsonb) result',[token,JSON.stringify(p)])).rows[0].result);
 const house=async token=>unwrap((await db.query('select public.member_house($1) result',[token])).rows[0].result);
 let alice,bob,casey,g=crypto.randomUUID(),later=crypto.randomUUID(),baseline;
 await t.test('legacy pending games become rated once; disputed and voided games stay excluded',async()=>{
  await auth(false);alice=await login('Alice');bob=await login('Bob');casey=await login('Casey');const d=await house(alice.token);assert.equal(d.players.find(p=>p.id===a).rating,1016);assert.equal(d.matches.find(m=>m.id===legacy).status,'confirmed');assert.equal(d.matches.find(m=>m.id===legacyDispute).status,'disputed');
  await db.exec('reset role');const past=(await db.query("select private.rankings_at(now()-interval '1 day') result")).rows[0].result;assert.ok(past.every(p=>p.rating===1000));await auth(true);await action({action:'void',id:legacy});await auth(false);
 });
 await t.test('a member submission updates both Elo ratings, records and histories immediately',async()=>{
  const p={action:'submit',id:g,winner:a,loser:b};await member(alice.token,p);let d=await house(alice.token);assert.equal(d.players.find(p=>p.id===a).rating,1016);assert.equal(d.players.find(p=>p.id===b).rating,984);assert.equal(d.players.find(p=>p.id===a).wins,1);assert.equal(d.players.find(p=>p.id===a).history.length,1);
  await member(alice.token,p);d=await house(alice.token);assert.equal(d.players.find(p=>p.id===a).wins,1);assert.equal(d.matches.filter(m=>m.id===g).length,1);
  await assert.rejects(()=>member(casey.token,{action:'submit',id:crypto.randomUUID(),winner:a,loser:b}),/own games/);
 });
 await t.test('admin submissions are immediate too; historical replay uses automatic submission events',async()=>{
  await auth(true);await action({action:'submit',id:later,winner:b,loser:a});await auth(false);baseline=(await house(alice.token)).players;
  await db.exec('reset role');const ranks=(await db.query('select private.rankings_at(clock_timestamp()) result')).rows[0].result;for(const p of baseline)assert.equal(ranks.find(r=>r.id===p.id).rating,p.rating);await auth(false);
 });
 await t.test('either participant can dispute a result; outsiders cannot; only admins restore it',async()=>{
  await assert.rejects(()=>member(casey.token,{action:'dispute',id:g}),/player in this game/);await member(alice.token,{action:'dispute',id:g});let d=await house(alice.token);assert.equal(d.matches.find(m=>m.id===g).status,'disputed');assert.equal(d.players.find(p=>p.id===b).rating,1016);
  await assert.rejects(()=>member(bob.token,{action:'resolve',id:g}),/Admin/);await auth(true);await action({action:'resolve',id:g});await auth(false);assert.deepEqual((await house(alice.token)).players,baseline);
 });
 await t.test('void/unvoid preserves rating order and reapplies exactly once',async()=>{
  await auth(true);await action({action:'void',id:g});await action({action:'unvoid',id:g});await auth(false);assert.deepEqual((await house(alice.token)).players,baseline);await auth(true);await assert.rejects(()=>action({action:'unvoid',id:g}),/not voided/);await auth(false);
 });
 await t.test('unvoiding an old unrated result rates it automatically; legacy disputes can be restored',async()=>{
  await auth(true);await action({action:'unvoid',id:legacyVoid});await action({action:'resolve',id:legacyDispute});await auth(false);const d=await house(alice.token);assert.equal(d.matches.find(m=>m.id===legacyVoid).status,'confirmed');assert.equal(d.matches.find(m=>m.id===legacyDispute).status,'confirmed');assert.equal(d.players.reduce((n,p)=>n+p.wins,0),4);
 });
 }finally{await db.close()}
});
