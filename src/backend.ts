import {createClient} from '@supabase/supabase-js';
const url=import.meta.env.VITE_SUPABASE_URL||'';
const key=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY||'';
export const configured=!!(url&&key&&!url.includes('YOUR_PROJECT')&&!key.includes('YOUR_'));
export const supabase=configured?createClient(url,key,{auth:{flowType:'pkce',persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}):null;
export async function loadHouse(){if(!supabase)throw Error('Supabase is not configured.');const {data,error}=await supabase.rpc('get_house');if(error)throw Error(error.message);return data;}
export async function changeHouse(params:Record<string,unknown>){if(!supabase)throw Error('Supabase is not configured.');const {error}=await supabase.rpc('house_action',{params});if(error)throw Error(error.message);}
export async function signIn(){if(!supabase)throw Error('Supabase is not configured.');const redirectTo=new URL(import.meta.env.BASE_URL,window.location.origin+window.location.pathname).href;const {error}=await supabase.auth.signInWithOAuth({provider:'google',options:{redirectTo}});if(error)throw Error(error.message);}
