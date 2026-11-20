import {test} from 'node:test';import assert from 'node:assert/strict';import {readFile,readdir} from 'node:fs/promises';import {PGlite} from '@electric-sql/pglite';import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
async function setup(){const db=new PGlite({extensions:{pgcrypto}});await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon;`);for(const f of (await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')).sort())await db.exec(await readFile(new URL('../supabase/migrations/'+f,import.meta.url),'utf8'));return db}
test('admin edits replay Elo, preserve chronology, audit corrections, and retain historical standings',async t=>{
 const db=await setup();try{
 const admin='00000000-0000-0000-0000-000000000001';await db.query('insert into auth.users values($1,$2,now())',[admin,'admin@example.test']);await db.query('insert into private.admins values($1)',[admin]);
 const [a,b,c,inactive]=(await db.query("insert into private.members(name,joined_at,pin_hash) values('Alice Example','2026-01-01',extensions.crypt('123456',extensions.gen_salt('bf',4))),('Bob Example','2026-01-01',null),('Casey Example','2026-01-01',null),('Inactive Player','2026-01-01',null) returning id")).rows.map(p=>p.id);await db.query('update private.members set active=false where id=$1',[inactive]);
 const [g,later]=[crypto.randomUUID(),crypto.randomUUID()];await db.query("insert into private.matches(id,winner,loser,status,created,played_at,confirmed,confirmation_order,note) values($1,$3,$4,'confirmed','2026-01-02','2026-01-02','2026-01-02',1,'original'),($2,$4,$3,'confirmed','2026-01-03','2026-01-03','2026-01-03',2,'later')",[g,later,a,b]);await db.exec('select private.recalculate()');
 const auth=async on=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[on?admin:'']);await db.exec(on?'set role authenticated':'set role anon')};
 const unwrap=r=>{if(r?.error)throw Error(r.message||r.error);return r};const action=async p=>unwrap((await db.query('select public.house_action($1::jsonb) result',[JSON.stringify(p)])).rows[0].result);
 const asOwner=async fn=>{await db.exec('reset role');try{return await fn()}finally{await auth(true)}};
 const row=async id=>asOwner(async()=>(await db.query('select * from private.matches where id=$1',[id])).rows[0]);
 const ratings=async()=>asOwner(async()=>(await db.query('select id,rating,wins,losses from private.members order by id')).rows);
 const historical=async date=>asOwner(async()=>(await db.query('select private.rankings_at($1) result',[date])).rows[0].result);
 await auth(false);const token=(await db.query("select public.member_login('Alice','Example','123456',false) result")).rows[0].result.token;
 let original,beforeHistorical;
 await t.test('member PIN sessions cannot edit results or read correction snapshots',async()=>{const r=(await db.query('select public.member_action($1,$2::jsonb) result',[token,JSON.stringify({action:'edit_result',id:g,winner:b,loser:a,admin:true})])).rows[0].result;assert.match(r.message,/Admin/);await assert.rejects(()=>db.query('select * from private.result_edits'),/permission/);await auth(true)});
 await t.test('winner and player edits replay every later result, update records, and keep rating order',async()=>{
  original=await row(g);beforeHistorical=await historical('2026-01-04');await action({action:'edit_result',id:g,winner:c,loser:b,note:'corrected',played_at:'2026-01-01T12:00:00Z'});const updated=await row(g),all=await ratings();assert.equal(updated.winner,c);assert.equal(updated.loser,b);assert.equal(updated.note,'corrected');assert.deepEqual(updated.confirmed,original.confirmed);assert.equal(updated.confirmation_order,original.confirmation_order);assert.deepEqual(updated.created,original.created);assert.equal(updated.played_at.toISOString(),'2026-01-01T12:00:00.000Z');assert.equal(all.find(p=>p.id===c).rating,1016);assert.equal(all.find(p=>p.id===c).wins,1);assert.equal(all.find(p=>p.id===a).wins,0);assert.equal(all.find(p=>p.id===a).losses,1);
  const expected=1000-32*(1-1/(1+10**((1000-984)/400)));assert.ok(Math.abs(all.find(p=>p.id===a).rating-expected)<1e-9);
 });
 await t.test('before/after snapshots keep old ranks intact across multiple edits',async()=>{
  assert.deepEqual(await historical('2026-01-04'),beforeHistorical);await action({action:'edit_result',id:g,winner:b,loser:c});assert.deepEqual(await historical('2026-01-04'),beforeHistorical);
  await asOwner(async()=>{const edits=(await db.query('select * from private.result_edits where match_id=$1 order by id',[g])).rows;assert.equal(edits.length,2);assert.equal(edits[0].before_result.winner,a);assert.equal(edits[0].after_result.winner,c);assert.equal(edits[1].before_result.winner,c);assert.equal(edits[1].after_result.winner,b);assert.equal(edits[0].actor,admin)});
 });
 await t.test('invalid edits are atomic, and unknown/inactive replacement players are rejected',async()=>{
  const before=await row(g),stats=await ratings();for(const patch of [{winner:a,loser:a},{winner:inactive,loser:b},{winner:crypto.randomUUID(),loser:b},{note:'x'.repeat(241)},{played_at:'not-a-date'},{played_at:'2999-01-01T00:00:00Z'}])await assert.rejects(()=>action({action:'edit_result',id:g,...patch}));assert.deepEqual(await row(g),before);assert.deepEqual(await ratings(),stats);await assert.rejects(()=>action({action:'edit_result',id:crypto.randomUUID(),winner:a,loser:b}),/not found/);
 });
 await t.test('note/date-only edits preserve ratings and original inactive participants may be retained',async()=>{
  const before=await ratings();await action({action:'edit_result',id:g,note:'note only',played_at:'2026-01-05T00:00:00Z'});assert.deepEqual(await ratings(),before);await asOwner(()=>db.query('update private.members set active=false where id=$1',[c]));await action({action:'edit_result',id:g,winner:c,loser:b,note:'retain original inactive participant'});assert.equal((await row(g)).winner,c);
 });
 await t.test('voided/disputed edits stay excluded and apply the corrected players when restored',async()=>{
  await action({action:'void',id:g});const before=await ratings();await action({action:'edit_result',id:g,winner:a,loser:b});assert.equal((await row(g)).status,'void');assert.deepEqual(await ratings(),before);await action({action:'unvoid',id:g});assert.equal((await row(g)).status,'confirmed');await action({action:'dispute',id:g});await action({action:'edit_result',id:g,winner:b,loser:a});assert.equal((await row(g)).status,'disputed');await action({action:'resolve',id:g});assert.equal((await row(g)).winner,b);
 });
 await t.test('an admin linked to a roster player gets that player’s dashboard',async()=>{
  await asOwner(()=>db.query('update private.members set email=$1 where id=$2',['admin@example.test',a]));const d=(await db.query('select public.member_dashboard(null) result')).rows[0].result;assert.equal(d.me,a);assert.ok(d.streak);await asOwner(()=>db.query('update private.members set email=null where id=$1',[a]));
 });
 await t.test('edited dates and outcomes reach paginated history, profiles, and dashboard without leaking snapshots',async()=>{
  await auth(false);const summary=(await db.query('select public.ladder_summary($1) result',[token])).rows[0].result,history=(await db.query('select public.match_history($1,1) result',[token])).rows[0].result,profile=(await db.query('select public.player_profile($1,$2) result',[a,token])).rows[0].result,dash=(await db.query('select public.member_dashboard($1) result',[token])).rows[0].result;
  assert.equal(new Date(history.matches.find(m=>m.id===g).played_at).toISOString(),'2026-01-05T00:00:00.000Z');assert.ok(profile.results.matches.every(m=>m.played_at));assert.ok(dash.recent_matches.every(m=>m.played_at));assert.equal(summary.players.find(p=>p.id===a).rating,profile.player.rating);assert.equal(dash.me,a);assert.equal(JSON.stringify(dash).includes('before_result'),false);
 });
 }finally{await db.close()}
});

test('personal dashboard computes full streaks, recent results, favorite opponents, and enforces read limits',async t=>{
 const db=await setup();try{
 const [a,b,c]=(await db.query("insert into private.members(name,pin_hash) values('Alice Example',extensions.crypt('123456',extensions.gen_salt('bf',4))),('Bob Example',null),('Casey Example',extensions.crypt('123456',extensions.gen_salt('bf',4))) returning id")).rows.map(p=>p.id);
 await db.query("insert into private.matches(id,winner,loser,status,confirmed,confirmation_order) select gen_random_uuid(),$1,$2,'confirmed','2026-01-01'::timestamptz+i*interval '1 minute',i from generate_series(1,63) i",[a,b]);await db.exec('select private.recalculate();set role anon');
 const token=(await db.query("select public.member_login('Alice','Example','123456',false) result")).rows[0].result.token,emptyToken=(await db.query("select public.member_login('Casey','Example','123456',false) result")).rows[0].result.token;
 const dashboard=async session=>(await db.query('select public.member_dashboard($1) result',[session])).rows[0].result;
 await t.test('streaks longer than the fifty-point chart and full all-time opponent totals are exact',async()=>{const d=await dashboard(token);assert.deepEqual(d.streak,{type:'win',count:63});assert.equal(d.most_played_opponent.id,b);assert.equal(d.most_played_opponent.games,63);assert.equal(d.most_played_opponent.wins,63);assert.equal(d.recent_matches.length,10);assert.ok(d.recent_matches.every(m=>m.winner===a&&m.status==='confirmed'))});
 await t.test('new players receive an empty dashboard with no invented favorite or streak',async()=>{const d=await dashboard(emptyToken);assert.deepEqual(d.streak,{type:'none',count:0});assert.equal(d.most_played_opponent,null);assert.deepEqual(d.recent_matches,[])});
 await t.test('invalid/missing sessions and private helper access are rejected',async()=>{assert.ok((await dashboard('invalid')).error);assert.ok((await dashboard(null)).error);await assert.rejects(()=>db.query('select private.dashboard_data($1)',[token]),/permission/)});
 await t.test('the dashboard shares the existing read budget and cannot access another member by client flag',async()=>{await db.exec('reset role;delete from private.rpc_rate_limits where scope is not null;set role anon');for(let i=0;i<120;i++)assert.equal((await dashboard(token)).me,a);assert.equal((await dashboard(token)).code,'RATE_LIMITED');assert.equal((await db.query('select public.ladder_summary($1) result',[token])).rows[0].result.code,'RATE_LIMITED');assert.equal((await dashboard(emptyToken)).me,c)});
 }finally{await db.close()}
});
