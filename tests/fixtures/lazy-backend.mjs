export const configured=true,supabase=null;
export const calls={summary:0,profiles:[],results:[],history:0};
let revision=1,deferred=null;
const players=[{id:'a',name:'Alice Example',active:true,rating:1016,wins:40,losses:23,delta:16},{id:'b',name:'Bob Example',active:true,rating:984,wins:23,losses:40,delta:-16}];
export const readMemberSession=()=>({id:'a',name:'Alice Example',token:'f'.repeat(64)}),clearMemberSession=()=>{},signOutMember=async()=>{};
export const checkMemberName=async()=>({name:'Alice Example',needs_pin_setup:false}),signInByName=async()=>({id:'a',name:'Alice Example',token:'e'.repeat(64)}),signInAdmin=async()=>{},changeMemberPin=async()=>{};
export function advanceRevision(){revision++}
export function deferNextProfile(){let resolve;const promise=new Promise(r=>{resolve=r});deferred={promise,resolve};return resolve}
export async function loadLadderSummary(){calls.summary++;return {me:'a',admin:false,pin_required:false,revision:String(revision),players:players.map(p=>({...p})),matches:[],match_counts:{recorded:63},rank_baselines:{week:[{id:'a',rank:1},{id:'b',rank:2}]}}}
export async function changeHouse(){advanceRevision();return {ok:true}}
function results(id,page){const total=revision===1?63:62,actual=Math.min(page,Math.ceil(total/10));return {page:actual,page_size:10,total,matches:Array.from({length:Math.min(10,total-(actual-1)*10)},(_,i)=>({id:`${revision}:${id}:${actual}:${i}`,opponent:id==='b'?'Alice Example':'Bob Example',won:i%2===0,confirmed:'2026-11-18',rating:1000+i,delta:i%2===0?16:-16,note:''}))}}
export async function loadPlayerProfile(id,range){calls.profiles.push({id,range,revision});const pending=deferred;deferred=null;if(pending)await pending.promise;const total=revision===1?63:62,start=range==='recent'?total-50:0;return {player:players.find(p=>p.id===id),chart:{range,start_game:start,starting_rating:start?1013:1000,total_games:total,history:Array.from({length:total-start},(_,i)=>({id:`g${start+i}`,rating:1014+i,delta:1,confirmed:'2026-11-18'}))},your_head_to_head:id==='b'?{wins:40,losses:23}:null,head_to_head:[{id:id==='b'?'a':'b',name:id==='b'?'Alice Example':'Bob Example',wins:23,losses:40}],results:results(id,1)}}
export async function loadPlayerResults(id,page){calls.results.push({id,page,revision});return results(id,page)}
export async function loadMatchHistory(){calls.history++;return {page:1,page_size:10,total:0,matches:[]}}
