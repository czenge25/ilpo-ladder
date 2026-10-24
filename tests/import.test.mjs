import {test} from 'node:test';import assert from 'node:assert/strict';import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';import {execFileSync} from 'node:child_process';import {PGlite} from '@electric-sql/pglite';
test('old Sites export imports safely and reproduces Elo',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'ilpo-import-'));const db=new PGlite();
 try{
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;`);
 await db.exec(await readFile(new URL('../supabase/001_schema.sql',import.meta.url),'utf8'));
 const a='20000000-0000-0000-0000-000000000001',b='20000000-0000-0000-0000-000000000002';const fixture={admin:true,players:[{id:a,name:"O'Brien",email:'a@example.test',active:1},{id:b,name:'Bob',email:null,active:1}],matches:[{id:'30000000-0000-0000-0000-000000000001',winner:a,loser:b,submitter:'admin',status:'confirmed',created:'2026-01-01T00:00:00.000Z',confirmed:'2026-01-01T00:01:00.000Z',note:"'); drop table private.members; --"}]};
 await writeFile(join(dir,'export.json'),JSON.stringify(fixture));execFileSync(process.execPath,['scripts/import-sites.mjs',join(dir,'export.json'),join(dir,'import.sql')],{cwd:new URL('..',import.meta.url)});
 const sql=await readFile(join(dir,'import.sql'),'utf8');await db.exec(sql);
 const {rows}=await db.query('select name,rating from private.members order by rating desc');assert.equal(rows[0].name,"O'Brien");assert.equal(rows[0].rating,1016);assert.equal(rows[1].rating,984);assert.equal((await db.query('select note from private.matches')).rows[0].note,fixture.matches[0].note);
 await assert.rejects(()=>db.exec(sql),/empty roster/);await db.exec('rollback');
 }finally{await db.close();await rm(dir,{recursive:true,force:true})}
});
