import test from 'node:test';
import assert from 'node:assert/strict';
import {doublesDb,roster} from './fixtures/doubles-db.mjs';

test('each ladder exposes its own history, movement, head-to-head and match points',async()=>{
 const db=await doublesDb();try{
  const [a,b,c,d,e]=await roster(db);
  await db.exec("update private.members set joined_at=now()-interval '40 days' where id is not null");
  await db.query("update private.members set pin_hash=extensions.crypt('123456',extensions.gen_salt('bf',4)) where id=$1",[a]);
  await db.query(`insert into private.matches(id,winner,winner_partner,loser,loser_partner,status,created,confirmed,confirmation_order)
  values(gen_random_uuid(),$1,null,$3,null,'confirmed',now()-interval '10 days',now()-interval '10 days',1),
  (gen_random_uuid(),$1,$2,$3,$4,'confirmed',now()-interval '2 days',now()-interval '2 days',2),
  (gen_random_uuid(),$2,$3,$1,$4,'confirmed',now()-interval '1 hour',now()-interval '1 hour',3)`,[a,b,c,d]);
  await db.exec("select private.recalculate();set role anon");
  const login=(await db.query("select public.member_login('Alice','Example','123456',false) as r")).rows[0].r;
  const get=async (q,args)=>(await db.query(q,args)).rows[0].r;
  const summary=await get('select public.ladder_summary($1) as r',[login.token]);
  assert.equal(summary.doubles_enabled,true);
  assert.deepEqual(summary.format_match_counts,{doubles:2,singles:1});
  assert.equal(summary.players.find(p=>p.id===b).format_stats.singles,undefined);
  assert.equal(summary.format_baselines.singles.day.find(p=>p.id===a).rating,1016);
  assert.equal(summary.format_baselines.doubles.day.find(p=>p.id===a).rating,1016);
  assert.equal(summary.format_baselines.doubles.week.find(p=>p.id===a).rating,1000);
  const doubles=summary.format_recent_matches.doubles[1];
  assert.equal(doubles.delta,16);
  const recordedDeltas=m=>[m.overall_delta,m.doubles_delta];
  assert.equal(doubles.doubles_delta,16);assert.notEqual(doubles.overall_delta,doubles.doubles_delta);
  assert.deepEqual(recordedDeltas(summary.matches.find(m=>m.id===doubles.id)),recordedDeltas(doubles));
  const history=await get('select public.match_history($1,1) as r',[login.token]);
  assert.deepEqual(recordedDeltas(history.matches.find(m=>m.id===doubles.id)),recordedDeltas(doubles));
  for(const [mode,total,head] of [['overall',3,{wins:2,losses:1}],['singles',1,{wins:1,losses:0}],['doubles',2,{wins:1,losses:1}]]){
   const profile=await get('select public.player_profile($1,$2,$3,$4) as r',[c,login.token,'recent',mode]);
   assert.equal(profile.chart.total_games,total);
   assert.equal(profile.results.total,total);
   assert.deepEqual(profile.your_head_to_head,head);
   if(mode==='doubles'){
    assert.deepEqual(profile.partners,[{id:b,name:'Bob Example',wins:1,losses:0},{id:d,name:'Drew Example',wins:0,losses:1}]);
    assert.equal(profile.head_to_head.find(p=>p.id===d).wins,1);
    assert.deepEqual(recordedDeltas(profile.results.matches.find(m=>m.id===doubles.id)),recordedDeltas(doubles).map(n=>-n));
   }else assert.equal(profile.partners,undefined);
   assert.ok(profile.results.matches.every(m=>Number.isFinite(m.rating)&&Number.isFinite(m.delta)));
   assert.equal(profile.player.rating,profile.chart.history.at(-1).rating);
  }
  const replay=await get('select public.player_results($1,$2,1,$3) as r',[b,login.token,'singles']);
  assert.equal(replay.total,0);
  const empty=await get('select public.player_profile($1,$2,$3,$4) as r',[e,login.token,'recent','doubles']);
  assert.deepEqual(empty.partners,[]);
  const dash=await get('select public.member_dashboard($1) as r',[login.token]);
  assert.equal(dash.recent_matches.length,3);
  assert.deepEqual(recordedDeltas(dash.recent_matches.find(m=>m.id===doubles.id)),recordedDeltas(doubles));
  assert.equal(dash.streak.type,'loss');
  assert.equal(dash.most_played_opponent.id,c);
 }finally{await db.close()}
});
