import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

test('Supabase SQL: permissions, game lifecycle, and Elo replay',async t=>{
 const db=new PGlite();
 const ids={admin:'00000000-0000-0000-0000-000000000001',a:'00000000-0000-0000-0000-000000000002',b:'00000000-0000-0000-0000-000000000003',c:'00000000-0000-0000-0000-000000000004',stranger:'00000000-0000-0000-0000-000000000005',unverified:'00000000-0000-0000-0000-000000000006'};
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon;`);
 await db.exec(await readFile(new URL('../supabase/001_schema.sql',import.meta.url),'utf8'));
 for(const [name,id] of Object.entries(ids))await db.query('insert into auth.users values($1,$2,$3)',[id,name+'@example.test',name==='unverified'?null:new Date().toISOString()]);
 await db.query('insert into private.admins values($1)',[ids.admin]);
 const as=async name=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[name]||'']);await db.exec(name?'set role authenticated':'set role anon')};
 const house=async()=> (await db.query('select public.get_house() as result')).rows[0].result;
 const action=async p=>(await db.query('select public.house_action($1::jsonb) as result',[JSON.stringify(p)])).rows[0].result;
 let a,b,c;
 await t.test('only configured admin can add members; normalized unique email',async()=>{
  await as('admin');await action({action:'add',name:'Alice',email:' A@EXAMPLE.TEST '});await action({action:'add',name:'Bob',email:'b@example.test'});await action({action:'add',name:'Casey',email:'c@example.test'});
  await assert.rejects(()=>action({action:'add',name:'Duplicate',email:'a@example.test'}),/already assigned/);
  const d=await house();a=d.players.find(p=>p.name==='Alice').id;b=d.players.find(p=>p.name==='Bob').id;c=d.players.find(p=>p.name==='Casey').id;assert.equal(d.admin,true);assert.equal(d.players[0].rating,1000);
  await as('a');await assert.rejects(()=>action({action:'add',name:'Intruder'}),/Admin/);assert.equal((await house()).admin,false);
 });
 await t.test('anonymous, unknown and unverified accounts denied',async()=>{
  for(const person of ['', 'stranger','unverified']){await as(person);await assert.rejects(()=>house());await assert.rejects(()=>action({action:'add',name:'X'}));}
 });
 await t.test('direct table changes and recalculation are inaccessible',async()=>{
  await as('a');await assert.rejects(()=>db.query('select * from private.members'),/permission/);await assert.rejects(()=>db.query('select private.recalculate()'),/permission/);await assert.rejects(()=>db.query('insert into private.admins values($1)',[ids.a]),/permission/);
  const d=await house();assert.equal(d.me,a);assert.ok(d.players.every(p=>p.email===null));
 });
 const game='10000000-0000-0000-0000-000000000001';
 await t.test('only participant can submit; retries do not duplicate games',async()=>{
  await as('a');await assert.rejects(()=>action({action:'submit',id:game,winner:a,loser:a}),/different/);await assert.rejects(()=>action({action:'submit',id:game,winner:b,loser:c}),/own games/);
  const payload={action:'submit',id:game,winner:a,loser:b,note:'Test game'};await action(payload);await action(payload);assert.equal((await house()).matches.length,1);assert.ok((await house()).players.every(p=>p.rating===1000));
  await assert.rejects(()=>action({...payload,winner:b,loser:a}),/already used/);
  await assert.rejects(()=>action({action:'confirm',id:game}),/opponent/);
  await as('c');await assert.rejects(()=>action({action:'confirm',id:game}),/opponent/);
 });
 await t.test('opponent confirmation applies Elo once; cannot submit own rating',async()=>{
  await as('b');await action({action:'confirm',id:game,rating:9000});let d=await house();assert.equal(d.players.find(p=>p.id===a).rating,1016);assert.equal(d.players.find(p=>p.id===b).rating,984);assert.equal(d.players.find(p=>p.id===a).history.length,1);await assert.rejects(()=>action({action:'confirm',id:game}),/already/);
 });
 const game2='10000000-0000-0000-0000-000000000002';
 await t.test('disputed games require admin resolution',async()=>{
  await as('a');await action({action:'submit',id:game2,winner:a,loser:b});await as('b');await action({action:'dispute',id:game2});assert.equal((await house()).players.find(p=>p.id===a).rating,1016);await assert.rejects(()=>action({action:'confirm',id:game2}),/already/);
  await as('admin');await action({action:'confirm',id:game2});const d=await house();const alice=d.players.find(p=>p.id===a);assert.ok(alice.delta<16&&alice.delta>0);assert.equal(d.players.reduce((n,p)=>n+p.rating,0),3000);
 });
 await t.test('admin void replays later games and preserves records',async()=>{
  await as('a');await assert.rejects(()=>action({action:'void',id:game}),/Admin/);await as('admin');await action({action:'void',id:game});const d=await house();assert.equal(d.players.find(p=>p.id===a).rating,1016);assert.equal(d.players.find(p=>p.id===b).rating,984);assert.equal(d.matches.find(m=>m.id===game).status,'void');assert.equal(d.players.find(p=>p.id===a).history.length,1);
 });
 await t.test('deactivation removes account access; reactivation restores it',async()=>{
  await as('admin');await action({action:'edit',id:a,active:false});await as('a');await assert.rejects(()=>house(),/active member/);await assert.rejects(()=>action({action:'confirm',id:game2}),/Active membership/);await as('admin');await action({action:'edit',id:a,active:true});await as('a');assert.equal((await house()).me,a);
 });
 await db.close();
});
