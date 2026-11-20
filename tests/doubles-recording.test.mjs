import test from 'node:test';
import assert from 'node:assert/strict';
import {doublesDb,roster} from './fixtures/doubles-db.mjs';

test('doubles recording checks participants, shares the singles submission limit, and renders both teams in API history',async()=>{
 const db=await doublesDb();try{
  const [a,b,c,d,e]=await roster(db);
  await db.query("update private.members set pin_hash=extensions.crypt('123456',extensions.gen_salt('bf',4)) where id in ($1,$2)",[b,e]);
  await db.exec('set role anon');
  const getToken=async name=>(await db.query("select public.member_login($1,'Example','123456',false) as r",[name])).rows[0].r.token;
  const token=await getToken('Bob'), outsider=await getToken('Evan');
  const action=async (t,body)=>(await db.query('select public.member_action($1,$2) as r',[t,JSON.stringify(body)])).rows[0].r;
  const game={action:'submit',id:crypto.randomUUID(),winner:a,winner_partner:b,loser:c,loser_partner:d};
  assert.match((await action(outsider,game)).message,/own games/);
  assert.match((await action(token,{...game,loser_partner:null})).message,/both teammates/);
  assert.match((await action(token,{...game,loser_partner:b})).message,/different active/);
  assert.equal((await action(token,game)).ok,true);
  assert.equal((await action(token,game)).ok,true);
  assert.equal((await action(token,{action:'submit',id:crypto.randomUUID(),winner:b,loser:d})).ok,true);
  assert.equal((await action(token,{...game,id:crypto.randomUUID()})).code,'RATE_LIMITED');
  const page=(await db.query('select public.match_history($1,1) as r',[token])).rows[0].r;
  const summary=(await db.query('select public.ladder_summary($1) as r',[token])).rows[0].r;
  assert.equal(page.total,2);
  for(const list of [page.matches,summary.matches]){
   const match=list.find(m=>m.id===game.id);
   assert.equal(match.winner_partner,b);assert.equal(match.loser_partner,d);assert.equal(match.delta,8);
  }
 }finally{await db.close()}
});
