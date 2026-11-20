import test from 'node:test';
import assert from 'node:assert/strict';
import {doublesDb,roster} from './fixtures/doubles-db.mjs';
test('migration preserves singles exactly; doubles split the Overall swing across both players',async()=>{
 let ids,before;
 const ratings=async db=>(await db.query('select id,rating,wins,losses,delta from private.members order by id')).rows;
 const db=await doublesDb(async db=>{
  ids=await roster(db);const [a,b]=ids;
  await db.query("insert into private.matches(id,winner,loser,status,confirmed,confirmation_order) values(gen_random_uuid(),$1,$2,'confirmed',now(),nextval('private.confirmation_order')),(gen_random_uuid(),$2,$1,'confirmed',now(),nextval('private.confirmation_order'))",[a,b]);
  await db.exec('select private.recalculate()');before=await ratings(db);
 });
 try{
  assert.deepEqual(await ratings(db),before);
  const [a,b,c,d,e]=ids;
  const read=async ()=>(await db.query('select id,rating,format_stats from private.members')).rows;
  const get=(r,id)=>r.find(p=>p.id===id);
  assert.equal(get(await read(),a).format_stats.singles.rating,before.find(p=>p.id===a).rating);
  await db.exec('delete from private.matches where confirmation_order is not null');
  const g=(await db.query("insert into private.matches(id,winner,winner_partner,loser,loser_partner,status,confirmed,confirmation_order) values(gen_random_uuid(),$1,$2,$3,$4,'confirmed',now(),nextval('private.confirmation_order')) returning id",[a,b,c,d])).rows[0].id;
  await db.exec('select private.recalculate()');
  const row=await read();
  for(const id of [a,b,c,d]){
   const sign=id===a||id===b?1:-1,p=get(row,id);
   assert.equal(p.rating,1000+sign*8);assert.equal(p.format_stats.doubles.rating,1000+sign*16);assert.equal(p.format_stats.singles,undefined);
  }
  assert.equal(get(row,e).rating,1000);
  const g2=(await db.query("insert into private.matches(id,winner,winner_partner,loser,loser_partner,status,confirmed,confirmation_order) values(gen_random_uuid(),$1,$2,$3,$4,'confirmed',now(),nextval('private.confirmation_order')) returning id",[c,d,a,e])).rows[0].id;
  await db.exec('select private.recalculate()');
  const expected=(gap,k)=>k*(1-1/(1+10**(gap/400)));
  const res=(await db.query('select ladder_results from private.matches where id=$1',[g2])).rows[0].ladder_results;
  assert.ok(Math.abs(res.overall[c].delta-expected(12,16))<1e-10);
  assert.ok(Math.abs(res.doubles[c].delta-expected(24,32))<1e-10);
  await assert.rejects(db.query("update private.matches set loser_partner=$1 where id=$2",[a,g]),/match_distinct_teams/);
  await db.query("update private.matches set status='void',status_before_void='confirmed' where id=$1",[g]);await db.exec('select private.recalculate()');
  assert.equal(get(await read(),c).rating,1008);
 }finally{await db.close()}
});
