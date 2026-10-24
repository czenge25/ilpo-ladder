// Convert the old site's ADMIN /api/house JSON export into SQL. No credentials needed.
import {readFile,writeFile} from 'node:fs/promises';
const [input,output]=process.argv.slice(2);
if(!input||!output){console.error('Usage: node scripts/import-sites.mjs house-export.json import.sql');process.exit(1)}
const source=JSON.parse(await readFile(input,'utf8'));
if(source.admin!==true||!Array.isArray(source.players)||!Array.isArray(source.matches))throw Error('Expected an admin /api/house export from the old site.');
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const members=source.players.map(p=>{if(!uuid.test(p.id)||typeof p.name!=='string'||!p.name.trim()||p.name.length>60)throw Error('Invalid member.');return {id:p.id,name:p.name,email:p.email?.trim().toLowerCase()||null,active:!!p.active}});
const ids=new Set(members.map(p=>p.id));
const confirmed=source.matches.filter(m=>m.status==='confirmed').sort((a,b)=>a.confirmed.localeCompare(b.confirmed)||a.id.localeCompare(b.id));
const order=new Map(confirmed.map((g,i)=>[g.id,i+1]));
const games=source.matches.map(g=>{if(!uuid.test(g.id)||!ids.has(g.winner)||!ids.has(g.loser)||g.winner===g.loser||!['pending','confirmed','disputed','void'].includes(g.status))throw Error('Invalid game.');if(!Number.isFinite(Date.parse(g.created))||(g.status==='confirmed'&&!Number.isFinite(Date.parse(g.confirmed))))throw Error('Invalid timestamp.');return {id:g.id,winner:g.winner,loser:g.loser,submitter:ids.has(g.submitter)?g.submitter:null,status:g.status,created:g.created,confirmed:g.confirmed||null,confirmation_order:order.get(g.id)||null,note:g.note||''}});
const literal=value=>"'"+JSON.stringify(value).replaceAll("'","''")+"'::jsonb";
const sql=`-- Import into a NEW empty ILPO Supabase database after 001_schema.sql.\n-- Contains private member data. Do not commit this file or the JSON export.\nbegin;\nset local standard_conforming_strings=on;\nselect pg_advisory_xact_lock(84201935);\ndo $$begin if exists(select 1 from private.members) or exists(select 1 from private.matches) then raise exception 'Import requires an empty roster and match history.'; end if; end$$;\ninsert into private.members(id,name,email,active) select * from jsonb_to_recordset(${literal(members)}) as x(id uuid,name text,email text,active boolean);\ninsert into private.matches(id,winner,loser,submitter,status,created,confirmed,confirmation_order,note) select * from jsonb_to_recordset(${literal(games)}) as x(id uuid,winner uuid,loser uuid,submitter uuid,status text,created timestamptz,confirmed timestamptz,confirmation_order bigint,note text);\nselect setval('private.confirmation_order',greatest(${confirmed.length},1),${confirmed.length>0});\nselect private.recalculate();\ncommit;\n`;
await writeFile(output,sql);console.log(`Prepared ${members.length} members and ${games.length} games in ${output}.`);
