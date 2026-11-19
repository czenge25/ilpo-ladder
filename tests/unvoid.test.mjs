import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

test('voided matches restore status, original Elo order, and admin boundaries',async t=>{
 const db=new PGlite();
 try{
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon;`);
 await db.exec(await readFile(new URL('../supabase/001_schema.sql',import.meta.url),'utf8'));
 const migrations=(await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')&&f<='20261119174545_restore_voided_matches.sql').sort();
 const newest=migrations.pop();
 for(const f of migrations)await db.exec(await readFile(new URL('../supabase/migrations/'+f,import.meta.url),'utf8'));
 const members=(await db.query("insert into private.members(name) values('Alice Example'),('Bob Example') returning id")).rows;
 const [a,b]=members.map(p=>p.id);
 const call=async(action,id,admin=true)=> (await db.query('select private.perform_action($1,null,$2,$3::jsonb)',[a,admin,JSON.stringify({action,id,winner:a,loser:b})])).rows;
 const match=async id=>(await db.query('select * from private.matches where id=$1',[id])).rows[0];
 const ratings=async()=>(await db.query('select id,rating,wins,losses,delta from private.members order by id')).rows;
 const legacy=['10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000003'];
 await call('submit',legacy[0]);await call('confirm',legacy[0]);await call('void',legacy[0]);
 await call('submit',legacy[1]);await call('dispute',legacy[1]);await call('void',legacy[1]);
 await call('submit',legacy[2]);await call('void',legacy[2]);
 await db.exec(await readFile(new URL('../supabase/migrations/'+newest,import.meta.url),'utf8'));
 await t.test('existing voids backfill confirmed, disputed, and pending origins',async()=>{for(let i=0;i<3;i++)assert.equal((await match(legacy[i])).status_before_void,['confirmed','disputed','pending'][i])});
 await t.test('members cannot unvoid even with a forged admin parameter',async()=>{
  const session=(await db.query("select public.name_sign_in('Alice','Example') result")).rows[0].result;
  await db.exec('set role anon');
  const r=(await db.query('select public.member_action($1,$2::jsonb) result',[session.token,JSON.stringify({action:'unvoid',id:legacy[0],admin:true})])).rows[0].result;
  assert.match(r.message,/Admin access/);await db.exec('reset role');assert.equal((await match(legacy[0])).status,'void');
 });
 await t.test('pending and disputed restore without awarding Elo',async()=>{
  await call('unvoid',legacy[1]);await call('unvoid',legacy[2]);
  assert.equal((await match(legacy[1])).status,'disputed');assert.equal((await match(legacy[2])).status,'pending');assert.ok((await ratings()).every(p=>p.rating===1000&&p.wins===0&&p.losses===0));
  await assert.rejects(()=>call('unvoid',legacy[2]),/not voided/);
 });
 await t.test('password-authenticated admins can restore through the guarded public RPC',async()=>{
  const admin='00000000-0000-0000-0000-000000000001';
  await db.query('insert into auth.users values($1,$2,now())',[admin,'admin@example.test']);await db.query('insert into private.admins values($1)',[admin]);
  await call('void',legacy[2]);await db.query("select set_config('request.jwt.claim.sub',$1,false)",[admin]);await db.exec('set role authenticated');
  const result=(await db.query('select public.house_action($1::jsonb) result',[JSON.stringify({action:'unvoid',id:legacy[2]})])).rows[0].result;
  assert.equal(result.ok,true);await db.exec('reset role');assert.equal((await match(legacy[2])).status,'pending');
 });
 await t.test('historical confirmed restoration exactly replays later results',async()=>{
  await call('unvoid',legacy[0]);await call('confirm',legacy[1]);await call('confirm',legacy[2]);
  const before=await ratings(),original=await match(legacy[0]);
  await call('void',legacy[0]);assert.notDeepEqual(await ratings(),before);
  await call('unvoid',legacy[0]);assert.deepEqual(await ratings(),before);
  const restored=await match(legacy[0]);assert.equal(restored.confirmation_order,original.confirmation_order);assert.deepEqual(restored.confirmed,original.confirmed);assert.equal(restored.status_before_void,null);
  await assert.rejects(()=>call('unvoid',legacy[0]),/not voided/);assert.deepEqual(await ratings(),before);
  await call('void',legacy[0]);await call('unvoid',legacy[0]);assert.deepEqual(await ratings(),before);
  assert.equal((await db.query("select count(*)::int n from private.audit where action='unvoid' and target=$1",[legacy[0]])).rows[0].n,3);
 });
 }finally{await db.close()}
});
