import test from 'node:test';
import assert from 'node:assert/strict';
import {doublesDb,roster} from './fixtures/doubles-db.mjs';

test('all four doubles participants can dispute; only admins edit, void, and restore',async()=>{
 const db=await doublesDb();try{
  const ids=await roster(db);const [a,b,c,d,e]=ids;
  const admin=crypto.randomUUID();
  await db.query("insert into auth.users values($1,'admin@example.test',now());",[admin]);
  await db.query('insert into private.admins values($1)',[admin]);
  await db.exec("update private.members set joined_at=now()-interval '40 days',pin_hash=extensions.crypt('123456',extensions.gen_salt('bf',4)) where id is not null");
  const q=async (sql,args)=>(await db.query(sql,args)).rows;
  const stats=()=>q('select id,rating,format_stats from private.members order by id');
  const match=id=>q('select * from private.matches where id=$1',[id]).then(r=>r[0]);
  const as=async role=>{await db.exec('reset role');await q("select set_config('request.jwt.claim.sub',$1,false)",[role==='authenticated'?admin:'']);if(role!=='owner')await db.exec('set role '+role)};
  await as('anon');
  const tokens=[];
  for(const name of ['Alice','Bob','Casey','Drew','Evan'])tokens.push((await q("select public.member_login($1,'Example','123456',false) as r",[name]))[0].r.token);
  const act=async (body,token)=> (await q(token?'select public.member_action($2,$1::jsonb) as r':'select public.house_action($1::jsonb) as r',token?[JSON.stringify(body),token]:[JSON.stringify(body)]))[0].r;
  const game={action:'submit',id:crypto.randomUUID(),winner:a,winner_partner:b,loser:c,loser_partner:d};
  assert.equal((await act(game,tokens[0])).ok,true);
  assert.equal((await act({action:'submit',id:crypto.randomUUID(),winner:a,loser:c},tokens[0])).ok,true);
  assert.match((await act({action:'dispute',id:game.id},tokens[4])).message,/Only a player/);
  assert.match((await act({action:'edit_result',id:game.id},tokens[1])).message,/Admin/);
  for(const token of tokens.slice(0,4)){
   await as('anon');assert.equal((await act({action:'dispute',id:game.id},token)).ok,true);
   await as('owner');assert.equal((await match(game.id)).ladder_results,null);
   assert.equal((await stats()).find(r=>r.id===a).rating,1016);
   await as('authenticated');assert.equal((await act({action:'resolve',id:game.id})).ok,true);
  }
  await as('owner');
  const before=await stats(),original=await match(game.id),cutoff=(await q('select clock_timestamp()::text as t'))[0].t;
  const historical=async ()=>(await q('select private.ladder_rankings_at($1) as r',[cutoff]))[0].r;
  const baseline=await historical();assert.equal(baseline.doubles.find(r=>r.id===a).rating,1016);
  await as('authenticated');
  assert.match((await act({action:'edit_result',id:game.id,winner_partner:c})).message,/four different/);
  assert.equal((await act({action:'edit_result',id:game.id,winner:c,winner_partner:d,loser:a,loser_partner:e,note:'Corrected teams'})).ok,true);
  await as('owner');
  const corrected=await stats(),updated=await match(game.id);
  assert.deepEqual(corrected.map(r=>r.format_stats.singles),before.map(r=>r.format_stats.singles));
  assert.equal(corrected.find(r=>r.id===b).format_stats.doubles,undefined);
  assert.equal(corrected.find(r=>r.id===e).format_stats.doubles.losses,1);
  assert.equal(updated.confirmation_order,original.confirmation_order);
  assert.deepEqual(await historical(),baseline);
  const audit=(await q('select before_result,after_result from private.result_edits where match_id=$1',[game.id]))[0];
  assert.equal(audit.before_result.winner_partner,b);assert.equal(audit.after_result.loser_partner,e);
  await as('authenticated');assert.equal((await act({action:'void',id:game.id})).ok,true);
  await as('owner');assert.equal((await stats()).find(r=>r.id===e).format_stats.doubles,undefined);
  await as('authenticated');assert.equal((await act({action:'unvoid',id:game.id})).ok,true);
  await as('owner');assert.deepEqual(await stats(),corrected);
 }finally{await db.close()}
});
