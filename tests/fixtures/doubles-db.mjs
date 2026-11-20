import {readFile,readdir} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
const dir=new URL('../../supabase/migrations/',import.meta.url);
export async function doublesDb(beforeEngine){
 const db=new PGlite({extensions:{pgcrypto}});
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated,anon;`);
 for(const file of (await readdir(dir)).filter(f=>f.endsWith('.sql')).sort()){
  if(file.endsWith('_doubles_rating_engine.sql'))await beforeEngine?.(db);
  await db.exec(await readFile(new URL(file,dir),'utf8'));
 }
 return db;
}
export async function roster(db){
 return (await db.query("insert into private.members(name) values('Alice Example'),('Bob Example'),('Casey Example'),('Drew Example'),('Evan Example') returning id")).rows.map(r=>r.id);
}
