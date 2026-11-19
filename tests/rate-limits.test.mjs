import {test} from 'node:test';import assert from 'node:assert/strict';import {readFile,readdir} from 'node:fs/promises';import {PGlite} from '@electric-sql/pglite';import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';

test('server RPC quotas persist failures, enforce identity budgets, and recover after expiry',async t=>{
 const db=new PGlite({extensions:{pgcrypto}});const admin='00000000-0000-0000-0000-000000000001';
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon;`);
 await db.exec(await readFile(new URL('../supabase/001_schema.sql',import.meta.url),'utf8'));
 for(const file of (await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')).sort())await db.exec(await readFile(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'));
 await db.query('insert into auth.users values($1,$2,now())',[admin,'admin@example.test']);await db.query('insert into private.admins values($1)',[admin]);
 await db.exec("insert into private.members(name,pin_hash) values ('Alice Example',extensions.crypt('123456',extensions.gen_salt('bf',4))),('Bob Example',extensions.crypt('123456',extensions.gen_salt('bf',4)))");
 const auth=async on=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[on?admin:'']);await db.exec(on?'set role authenticated':'set role anon')};
 const reset=async()=>{await db.exec('reset role;delete from private.rpc_rate_limits where scope is not null;');await auth(false)};
 const rpc=async(sql,args=[])=>(await db.query(`with response as materialized (select ${sql} result) select result,current_setting('response.status',true) as status,current_setting('response.headers',true) as headers from response`,args)).rows[0];
 const login=async(first='Alice',last='Example')=>rpc('public.member_login($1,$2,$3,false)',[first,last,'123456']);
 const action=async(token,params)=>rpc('public.member_action($1,$2::jsonb)',[token,JSON.stringify(params)]);
 const isLimited=r=>{assert.equal(r.result.code,'RATE_LIMITED');assert.equal(r.status,'429');assert.ok(r.result.retry_after_seconds>=1&&r.result.retry_after_seconds<=60);assert.equal(Number(JSON.parse(r.headers)[0]['Retry-After']),r.result.retry_after_seconds)};
 let a,b;
 await t.test('failed names count across committed requests and normalized aliases share the limit',async()=>{
  await reset();for(let i=0;i<6;i++){const r=await login(' Not ',' LISTED ');assert.equal(r.result.code,'42501');assert.match(r.result.message,/not on/)}isLimited(await login('not','listed'));
 });
 await t.test('valid sign-ins are limited too; requests resume when the window expires',async()=>{
  await reset();for(let i=0;i<6;i++){const r=await login('ALICE',' Example ');assert.ok(r.result.token)}isLimited(await login());
  await db.exec("reset role;update private.rpc_rate_limits set expires_at=clock_timestamp()-interval '1 second' where scope='login-name';");await auth(false);assert.ok((await login()).result.token);
 });
 await t.test('only five game submissions per player per minute, even across different sessions',async()=>{
  await reset();a=(await login()).result;b=(await login('Bob','Example')).result;
  for(let i=1;i<=5;i++)assert.equal((await action(a.token,{action:'submit',id:`10000000-0000-0000-0000-${String(i).padStart(12,'0')}`,winner:a.id,loser:b.id})).result.ok,true);
  const a2=(await login()).result;isLimited(await action(a2.token,{action:'submit',id:'10000000-0000-0000-0000-000000000006',winner:a.id,loser:b.id}));
  await db.exec('reset role');assert.equal((await db.query('select count(*)::int n from private.matches')).rows[0].n,5);await auth(false);
  assert.equal((await action(b.token,{action:'submit',id:'10000000-0000-0000-0000-000000000007',winner:b.id,loser:a.id})).result.ok,true);
 });
 await t.test('failed game actions consume the write budget without mutating game data',async()=>{
  await reset();for(let i=0;i<30;i++)assert.match((await action(a.token,{action:'unknown'})).result.message,/Unknown/);isLimited(await action(a.token,{action:'unknown'}));
  await db.exec('reset role');assert.equal((await db.query('select count(*)::int n from private.matches')).rows[0].n,6);await auth(false);
 });
 await t.test('read quota is independent of writes and enforced per player',async()=>{
  await reset();for(let i=0;i<120;i++)assert.equal((await rpc('public.member_house($1)',[a.token])).result.me,a.id);
  isLimited(await rpc('public.member_house($1)',[a.token]));assert.equal((await rpc('public.member_house($1)',[b.token])).result.me,b.id);
  assert.match((await action(a.token,{action:'unknown'})).result.message,/Unknown/);
 });
 await t.test('administrator writes have a separate 60-request budget',async()=>{
  await reset();await auth(true);for(let i=0;i<60;i++)assert.match((await rpc('public.house_action($1::jsonb)',[JSON.stringify({action:'unknown'})])).result.message,/Unknown/);isLimited(await rpc('public.house_action($1::jsonb)',[JSON.stringify({action:'unknown'})]));
 });
 await t.test('the five-game submission limit also applies to administrators',async()=>{
  await reset();await auth(true);for(let i=1;i<=5;i++){const r=await rpc('public.house_action($1::jsonb)',[JSON.stringify({action:'submit',id:`20000000-0000-0000-0000-${String(i).padStart(12,'0')}`,winner:a.id,loser:b.id})]);assert.equal(r.result.ok,true)}
  isLimited(await rpc('public.house_action($1::jsonb)',[JSON.stringify({action:'submit',id:'20000000-0000-0000-0000-000000000006',winner:a.id,loser:b.id})]));
  await db.exec('reset role');assert.equal((await db.query("select count(*)::int n from private.matches where id::text like '20000000-%'")).rows[0].n,5);
 });
 await t.test('global login ceiling prevents bypass by rotating entered names',async()=>{
  await reset();const rows=(await db.query("select public.name_sign_in('Unknown',i::text) result from generate_series(1,301) i")).rows;assert.ok(rows.slice(0,300).every(r=>r.result.code==='42501'));assert.equal(rows[300].result.code,'RATE_LIMITED');
 });
 await t.test('invalid tokens also count toward the shared API flood ceiling',async()=>{
  await reset();const rows=(await db.query("select public.member_house(repeat('0',64)) result from generate_series(1,1201)")).rows;assert.ok(rows.slice(0,1200).every(r=>r.result.code==='42501'));assert.equal(rows[1200].result.code,'RATE_LIMITED');
 });
 await t.test('browser roles cannot read quotas or call unlimited implementations',async()=>{
  await reset();await assert.rejects(()=>db.query('select * from private.rpc_rate_limits'),/permission/);await assert.rejects(()=>db.query("select private.take_rpc_budget('x','x',999,60)"),/permission/);await assert.rejects(()=>db.query("select private.unlimited_name_sign_in('Alice','Example')"),/permission/);await assert.rejects(()=>db.query('select private.guarded_rpc($1)', ['house_action']),/permission/);
 });
 await db.close();
});
