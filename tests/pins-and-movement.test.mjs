import {test} from 'node:test';import assert from 'node:assert/strict';import {readFile,readdir} from 'node:fs/promises';import {PGlite} from '@electric-sql/pglite';import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
async function database(){const db=new PGlite({extensions:{pgcrypto}});await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon;`);await db.exec(await readFile(new URL('../supabase/001_schema.sql',import.meta.url),'utf8'));for(const file of (await readdir(new URL('../supabase/migrations/',import.meta.url))).filter(f=>f.endsWith('.sql')).sort())await db.exec(await readFile(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'));return db}

test('six-digit PIN setup, authentication, changes, resets, and rate limits',async t=>{
 const db=await database();try{
 const [a,b]=(await db.query("insert into private.members(name) values('Alice Example'),('Bob Example') returning id")).rows.map(p=>p.id);
 const admin='00000000-0000-0000-0000-000000000001';await db.query('insert into auth.users values($1,$2,now())',[admin,'admin@example.test']);await db.query('insert into private.admins values($1)',[admin]);
 const auth=async who=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[who||'']);await db.exec(who?'set role authenticated':'set role anon')};
 const login=async(pin=null,setup=false,first='Alice')=>(await db.query('select public.member_login($1,$2,$3,$4) result',[first,'Example',pin,setup])).rows[0].result;
 const action=async(token,p)=>(await db.query('select public.member_action($1,$2::jsonb) result',[token,JSON.stringify(p)])).rows[0].result;
 const house=async token=>(await db.query('select public.member_house($1) result',[token])).rows[0].result;
 const resetBudget=async()=>{await db.exec('reset role;delete from private.rpc_rate_limits where scope is not null;');await auth()};
 let session,second,changed;
 const legacy='f'.repeat(64);await db.query("insert into private.member_sessions(token_hash,member_id) values(encode(sha256(convert_to($1,'UTF8')),'hex'),$2)",[legacy,a]);
 await t.test('name lookup never authenticates, legacy sessions require setup before writes',async()=>{
  await auth();const info=await login();assert.equal(info.needs_pin_setup,true);assert.equal(info.token,undefined);const old=(await db.query("select public.name_sign_in('Alice','Example') result")).rows[0].result;assert.equal(old.token,undefined);assert.equal((await house(legacy)).pin_required,true);
  assert.match((await action(legacy,{action:'submit',id:crypto.randomUUID(),winner:a,loser:b})).message,/Create your six-digit PIN/);
 });
 await t.test('first setup accepts exactly six digits including leading zeroes and revokes legacy sessions',async()=>{
  await resetBudget();for(const pin of ['12345','1234567','12a456',''])assert.match((await login(pin,true)).message,/six digits/);
  session=await login('012345',true);assert.equal(session.id,a);assert.equal(session.token.length,64);assert.equal((await house(session.token)).pin_required,false);assert.match((await house(legacy)).message,/sign in again/);
 });
 await t.test('bcrypt hashes are salted and never returned, and setup cannot replace an existing PIN',async()=>{
  await resetBudget();const bob=await login('012345',true,'Bob');assert.ok(bob.token);
  await db.exec('reset role');const hashes=(await db.query('select pin_hash from private.members order by name')).rows.map(p=>p.pin_hash);assert.ok(hashes.every(h=>h.startsWith('$2a$10$')&&h!=='012345'));assert.notEqual(hashes[0],hashes[1]);await auth();
  assert.match((await login('999999',true)).message,/already set/);assert.match((await login('999999')).message,/Incorrect PIN/);second=await login('012345');assert.ok(second.token);assert.equal(JSON.stringify(await house(second.token)).includes('pin_hash'),false);
  await assert.rejects(()=>db.query('select private.pin_login($1,$2,$3)',['Alice','Example','{}']),/permission/);
 });
 await t.test('PIN changes require the current PIN, rotate sessions, and retain the changing browser',async()=>{
  await resetBudget();assert.match((await action(session.token,{action:'change_pin',current_pin:'999999',new_pin:'654321'})).message,/Current PIN/);
  changed=await action(session.token,{action:'change_pin',current_pin:'012345',new_pin:'654321'});assert.equal(changed.id,a);assert.notEqual(changed.token,session.token);assert.match((await house(session.token)).message,/sign in again/);assert.match((await house(second.token)).message,/sign in again/);assert.equal((await house(changed.token)).me,a);assert.match((await login('012345')).message,/Incorrect PIN/);assert.ok((await login('654321')).token);
 });
 await t.test('failed login and PIN change attempts consume persistent budgets',async()=>{
  await resetBudget();for(let i=0;i<6;i++)assert.match((await login('999999')).message,/Incorrect PIN/);assert.equal((await login('654321')).code,'RATE_LIMITED');
  await resetBudget();for(let i=0;i<6;i++)assert.match((await action(changed.token,{action:'change_pin',current_pin:'999999',new_pin:'654321'})).message,/Current PIN/);assert.equal((await action(changed.token,{action:'change_pin',current_pin:'654321',new_pin:'111111'})).code,'RATE_LIMITED');
 });
 await t.test('the hourly PIN budget survives expiration of the minute window',async()=>{
  await resetBudget();
  for(let i=0;i<30;i++){
   if(i&&i%6===0){await db.exec("reset role;update private.rpc_rate_limits set expires_at=clock_timestamp()-interval '1 second' where scope='login-name';");await auth()}
   assert.match((await login('999999')).message,/Incorrect PIN/);
  }
  await db.exec("reset role;update private.rpc_rate_limits set expires_at=clock_timestamp()-interval '1 second' where scope='login-name';");await auth();
  const limited=await login('654321');assert.equal(limited.code,'RATE_LIMITED');assert.ok(limited.retry_after_seconds>60);
 });
 await t.test('only admins can reset a PIN; reset invalidates sessions and reopens explicit setup',async()=>{
  await resetBudget();assert.match((await action(changed.token,{action:'reset_pin',id:b,admin:true})).message,/Admin/);
  await auth(admin);assert.equal((await db.query('select public.house_action($1::jsonb) result',[JSON.stringify({action:'reset_pin',id:a})])).rows[0].result.ok,true);await auth();assert.match((await house(changed.token)).message,/sign in again/);assert.equal((await login()).needs_pin_setup,true);assert.match((await login('654321')).message,/Create your six-digit PIN/);assert.ok((await login('111111',true)).token);
 });
 }finally{await db.close()}
});

test('historical rank baselines replay confirmations, historical voids, and new members',async t=>{
 const db=await database();try{
 const [a,b,c]=(await db.query("insert into private.members(name,joined_at) values('Alice Example','2026-01-01'),('Bob Example','2026-01-01'),('Casey Example','2026-03-01') returning id")).rows.map(p=>p.id);
 const game=crypto.randomUUID();await db.query("insert into private.matches(id,winner,loser,status,created,confirmed,confirmation_order) values($1,$2,$3,'confirmed','2026-01-02','2026-01-02',1)",[game,b,a]);await db.query("insert into private.audit(action,target,created) values('submit',$1,'2026-01-02'),('confirm',$1,'2026-01-02')",[game]);
 const ranks=async cutoff=>(await db.query('select private.rankings_at($1) result',[cutoff])).rows[0].result;
 await t.test('historical Elo uses confirmations and excludes later joiners',async()=>{
  const before=await ranks('2026-01-01T12:00:00Z');assert.deepEqual(before.map(p=>p.id),[a,b]);assert.ok(before.every(p=>p.rating===1000));
  const after=await ranks('2026-01-03');assert.deepEqual(after.map(p=>p.id),[b,a]);assert.equal(after[0].rating,1016);assert.equal(after[1].rating,984);
 });
 await t.test('later voiding leaves earlier historical standings intact',async()=>{
  await db.query("update private.matches set status='void',status_before_void='confirmed' where id=$1",[game]);await db.query("insert into private.audit(action,target,created) values('void',$1,'2026-02-01')",[game]);
  assert.equal((await ranks('2026-01-03'))[0].id,b);assert.deepEqual((await ranks('2026-02-02')).map(p=>p.id),[a,b]);
 });
 await t.test('unvoid restores original-order Elo from that time onward',async()=>{
  await db.query("update private.matches set status='confirmed',status_before_void=null where id=$1",[game]);await db.query("insert into private.audit(action,target,created) values('unvoid',$1,'2026-02-03')",[game]);
  assert.deepEqual((await ranks('2026-02-02')).map(p=>p.id),[a,b]);const restored=await ranks('2026-03-02');assert.deepEqual(restored.map(p=>p.id),[b,c,a]);assert.equal(restored[0].rating,1016);assert.equal(restored[2].rating,984);
 });
 await t.test('member response includes personalized identity, chart dates, and all movement windows',async()=>{
  const token=(await db.query("select public.member_login('Alice','Example','123456',true) result")).rows[0].result.token;
  const d=(await db.query('select public.member_house($1) result',[token])).rows[0].result;assert.equal(d.me,a);assert.deepEqual(Object.keys(d.rank_baselines).sort(),['day','month','week']);assert.equal(d.players.find(p=>p.id===a).history.length,1);assert.ok(d.players.find(p=>p.id===a).history[0].confirmed);
 });
 }finally{await db.close()}
});
