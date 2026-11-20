import {useState} from 'react';import {X} from 'lucide-react';
function localDateTime(value:string){const d=new Date(value),pad=(n:number)=>String(n).padStart(2,'0');return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`}
export function EditResultDialog({match,players,busy,error,onClose,onSave}:{match:any;players:any[];busy:boolean;error:string;onClose:()=>void;onSave:(body:any)=>Promise<void>}){
 const [validation,setValidation]=useState('');
 const doubles=!!match.winner_partner;
 const [winners,setWinners]=useState<string[]>(()=>doubles?[match.winner,match.winner_partner]:[match.winner]);
 const [losers,setLosers]=useState<string[]>(()=>doubles?[match.loser,match.loser_partner]:[match.loser]);
 const original=[match.winner,match.winner_partner,match.loser,match.loser_partner];
 const eligible=players.filter(p=>p.active||original.includes(p.id));
 function slot(label:string,field:string,team:string[],index:number,setTeam:(v:string[])=>void){
  return <label>{label}<select name={field} required value={team[index]} onChange={e=>setTeam(team.map((v,i)=>i===index?e.target.value:v))}>{eligible.map(p=><option value={p.id} key={p.id}>{p.name}{p.active?'':' (inactive)'}</option>)}</select></label>
 }
 return <div className="overlay" onClick={()=>!busy&&onClose()}><section className="dialog" role="dialog" aria-modal="true" aria-label="Edit result" onClick={e=>e.stopPropagation()}><button className="close" aria-label="Close" disabled={busy} onClick={onClose}><X/></button><h2>Edit result</h2><p>Correct the players, result, match date, or note. Ratings will be recalculated.</p><form onSubmit={async e=>{
  e.preventDefault();const f=new FormData(e.currentTarget);
  const participants=['winner','loser',...(doubles?['winner_partner','loser_partner']:[])].map(field=>f.get(field));
  if(participants.some(p=>!p)||new Set(participants).size!==participants.length){setValidation(doubles?'Select four different players.':'Select two different players.');return}
  const dateText=String(f.get('played_at')),originalDate=match.played_at??match.created,date=new Date(dateText===localDateTime(originalDate)?originalDate:dateText);
  if(!Number.isFinite(date.getTime())){setValidation('Enter a valid match date.');return}
  setValidation('');await onSave({action:'edit_result',id:match.id,winner:participants[0],loser:participants[1],...(doubles?{winner_partner:participants[2],loser_partner:participants[3]}:{}),played_at:date.toISOString(),note:f.get('note')});
 }}>
 {slot(doubles?'Winning team · Player 1':'Winner','winner',winners,0,setWinners)}
 {doubles&&slot('Winning team · Player 2','winner_partner',winners,1,setWinners)}
 {slot(doubles?'Losing team · Player 1':'Loser','loser',losers,0,setLosers)}
 {doubles&&slot('Losing team · Player 2','loser_partner',losers,1,setLosers)}
 {doubles&&<button className="secondary" type="button" disabled={busy} onClick={()=>{setWinners(losers);setLosers(winners);setValidation('')}}>Swap winning and losing teams</button>}
 <label>Match date and time<input name="played_at" type="datetime-local" required defaultValue={localDateTime(match.played_at??match.created)}/></label>
 <label>Game note <span>(optional)</span><input name="note" maxLength={240} defaultValue={match.note}/></label><p className="hint">Times use your local timezone. Editing the match date keeps its original place in the rating sequence.</p>
 {(validation||error)&&<div className="error" role="alert">{validation||error}</div>}<button className="primary wide" disabled={busy}>{busy?'Saving…':'Save changes'}</button></form></section></div>;
}
