import {createClient} from '@supabase/supabase-js';
const url=import.meta.env.VITE_SUPABASE_URL||'';
const key=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY||'';
export const configured=!!(url&&key&&!url.includes('YOUR_PROJECT')&&!key.includes('YOUR_'));
export const supabase=configured?createClient(url,key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true,flowType:'pkce'}}):null;
export type MemberSession={token:string;id:string;name:string};
const storageKey='ilpo-member-session-v1';
export function readMemberSession():MemberSession|null{try{const s=JSON.parse(localStorage.getItem(storageKey)||'null');return s&&typeof s.token==='string'&&s.token.length===64&&typeof s.id==='string'&&typeof s.name==='string'?s:null}catch{return null}}
export function clearMemberSession(){localStorage.removeItem(storageKey)}
async function rpc(name:string,args?:Record<string,unknown>){if(!supabase)throw Error('Supabase is not configured.');const {data,error}=await supabase.rpc(name,args);if(error)throw Error(error.message);return data;}
export async function signInByName(firstName:string,lastName:string){const data:MemberSession=await rpc('name_sign_in',{first_name:firstName,last_name:lastName});localStorage.setItem(storageKey,JSON.stringify(data));return data;}
export async function signOutMember(token:string){try{await rpc('name_sign_out',{session_token:token})}finally{clearMemberSession()}}
export function loadHouse(token?:string){return token?rpc('member_house',{session_token:token}):rpc('get_house')}
export function changeHouse(params:Record<string,unknown>,token?:string){return token?rpc('member_action',{session_token:token,params}):rpc('house_action',{params})}
export async function signInAdmin(email:string,password:string){if(!supabase)throw Error('Supabase is not configured.');const {data,error}=await supabase.auth.signInWithPassword({email,password});if(error)throw Error(error.message);clearMemberSession();return data.session;}
