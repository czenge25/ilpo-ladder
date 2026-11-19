import {test} from 'node:test';import assert from 'node:assert/strict';import {readFile,readdir} from 'node:fs/promises';import {PGlite} from '@electric-sql/pglite';import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';

test('server history pages preserve counts and full profile stats with shared read limits',async t=>{
 const db=new PGlite({extensions:{pgcrypto}});try{
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon;`);
 await db.exec(await readFile(new URL('../supabase/001_schema.sql',import.meta.url),'utf8'));for(const f of (await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')).sort())await db.exec(await readFile(new URL('../supabase/migrations/'+f,import.meta.url),'utf8'));
 const [a,b]=(await db.query("insert into private.members(name,pin_hash) values('Alice Example',extensions.crypt('123456',extensions.gen_salt('bf',4))),('Bob Example',extensions.crypt('123456',extensions.gen_salt('bf',4))) returning id")).rows.map(p=>p.id);
 await db.query("insert into private.matches(id,winner,loser,status,created,confirmed,confirmation_order) select gen_random_uuid(),$1,$2,'confirmed','2026-01-01'::timestamptz+i*interval '1 minute','2026-01-01'::timestamptz+i*interval '1 minute',i from generate_series(1,23) i",[a,b]);
 const disputed=crypto.randomUUID(),voided=crypto.randomUUID();await db.query("insert into private.matches(id,winner,loser,status,status_before_void) values($1,$3,$4,'disputed',null),($2,$3,$4,'void','confirmed')",[disputed,voided,a,b]);await db.exec('select private.recalculate()');
 const admin='00000000-0000-0000-0000-000000000001';await db.query('insert into auth.users values($1,$2,now())',[admin,'admin@example.test']);await db.query('insert into private.admins values($1)',[admin]);
 const auth=async on=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[on?admin:'']);await db.exec(on?'set role authenticated':'set role anon')};
 await auth(false);const token=(await db.query("select public.member_login('Alice','Example','123456',false) result")).rows[0].result.token;
 const page=async(n,session=token)=>(await db.query('select public.match_history($1,$2) result',[session,n])).rows[0].result;
 await t.test('pages contain ten, ten, and three unique results in newest-first order',async()=>{
  const pages=await Promise.all([page(1),page(2),page(3)]);assert.deepEqual(pages.map(p=>p.matches.length),[10,10,3]);assert.ok(pages.every(p=>p.total===23&&p.page_size===10));const all=pages.flatMap(p=>p.matches);assert.equal(new Set(all.map(m=>m.id)).size,23);assert.ok(all.every(m=>m.status==='confirmed'));assert.ok(all.every((m,i)=>!i||new Date(all[i-1].created)>=new Date(m.created)));
 });
 await t.test('empty last pages are clamped; malformed page numbers are rejected',async()=>{assert.equal((await page(1000)).page,3);assert.equal((await page(1000)).matches.length,3);assert.match((await page(0)).message,/at least 1/)});
 await t.test('ladder carries only three recent results plus disputes/voids; totals and profiles stay complete',async()=>{
  const d=(await db.query('select public.member_house($1) result',[token])).rows[0].result;assert.equal(d.matches.length,5);assert.equal(d.match_counts.recorded,23);assert.ok(d.matches.some(m=>m.id===disputed));assert.ok(d.matches.some(m=>m.id===voided));assert.equal(d.players.find(p=>p.id===a).history.length,23);assert.equal(d.head_to_head.find(p=>p.winner===a&&p.loser===b).wins,23);
 });
 await t.test('invalid and missing sessions are rejected; authenticated admins can page history',async()=>{
  assert.ok((await page(1,'bad')).error);assert.ok((await page(1,null)).error);await assert.rejects(()=>db.query('select private.history_page($1,$2)',[token,'{}']),/permission/);await auth(true);assert.equal((await page(2,null)).matches.length,10);await auth(false);
 });
 await t.test('history shares the existing per-member read budget rather than bypassing it',async()=>{
  await db.exec('reset role;delete from private.rpc_rate_limits where scope is not null;');await auth(false);for(let i=0;i<120;i++)assert.equal((await page(1)).total,23);assert.equal((await page(2)).code,'RATE_LIMITED');assert.equal((await db.query('select public.member_house($1) result',[token])).rows[0].result.code,'RATE_LIMITED');
 });
 await t.test('removal clamps a now-missing page and zero results still have page one',async()=>{
  await db.exec("reset role;delete from private.rpc_rate_limits where scope is not null;update private.matches set status='void',status_before_void='confirmed' where status='confirmed';");await auth(false);const empty=await page(3);assert.equal(empty.page,1);assert.equal(empty.total,0);assert.deepEqual(empty.matches,[]);
 });
 }finally{await db.close()}
});
