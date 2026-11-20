import {useEffect,useState} from 'react';
import {X} from 'lucide-react';
import {loadPlayerProfile,loadPlayerResults} from './backend';
import {RatingChart} from './RatingChart';
import {type ProfileCache} from './profileCache';
import {usePageVisibility} from './usePageVisibility';
type Props={player:any;token?:string;scope:string;cache:ProfileCache;canChangePin:boolean;busy:boolean;onChangePin:()=>void;onClose:()=>void};
export function PlayerProfile({player,token,scope,cache,canChangePin,busy,onChangePin,onClose}:Props){
 const visible=usePageVisibility(),[range,setRange]=useState<'recent'|'all'>('recent'),[page,setPage]=useState(1),[info,setInfo]=useState<{key:string;value:any}|null>(null),[results,setResults]=useState<{key:string;value:any}|null>(null),[error,setError]=useState(''),[resultError,setResultError]=useState(''),[loadingResults,setLoadingResults]=useState(false),[retry,setRetry]=useState(0);
 const profileKey=`${scope}:profile:${player.id}:${range}`,resultKey=`${scope}:results:${player.id}:${page}`;
 const detail=info?.key===profileKey?info.value:null,history=results?.key===resultKey?results.value:null;
 useEffect(()=>{if(!visible)return;let alive=true;setError('');cache.get(profileKey,()=>loadPlayerProfile(player.id,range,token)).then(value=>{if(alive)setInfo({key:profileKey,value})}).catch(e=>{if(alive)setError(e.message)});return()=>{alive=false}},[profileKey,player.id,range,token,visible,retry,cache]);
 useEffect(()=>{if(!visible||!detail)return;let alive=true;setLoadingResults(true);setResultError('');cache.get(resultKey,()=>page===1?Promise.resolve(detail.results):loadPlayerResults(player.id,page,token)).then(value=>{if(!alive)return;setResults({key:resultKey,value});if(value.page!==page)setPage(value.page)}).catch(e=>{if(alive)setResultError(e.message)}).finally(()=>{if(alive)setLoadingResults(false)});return()=>{alive=false}},[resultKey,detail,page,player.id,token,visible,retry,cache]);
 const p=detail?.player??player,initials=p.name.split(' ').map((x:string)=>x[0]).slice(0,2).join('').toUpperCase();
 return <div className="overlay" onClick={onClose}><section className="dialog" role="dialog" aria-modal="true" aria-label="Player profile" onClick={e=>e.stopPropagation()}><button className="close" aria-label="Close" onClick={onClose}><X/></button><span className="avatar large">{initials}</span><h2>{p.name}</h2>
 {canChangePin&&<button className="secondary profile-pin" disabled={busy} onClick={onChangePin}>Change PIN</button>}
 <div className="profileStats"><div><strong>{Math.round(p.rating)}</strong><small>ELO RATING</small></div><div><strong>{p.wins}–{p.losses}</strong><small>RECORD</small></div><div><strong>{p.wins+p.losses?Math.round(100*p.wins/(p.wins+p.losses)):0}%</strong><small>WIN RATE</small></div></div>
 {error&&<div className="error" role="alert">{error} <button className="textbtn" onClick={()=>setRetry(n=>n+1)}>Retry profile</button></div>}
 {!detail&&!error&&<p role="status">Loading player history…</p>}
 {detail?.your_head_to_head&&<section className="your-matchup"><h3>Your head-to-head vs. {p.name}</h3><strong>{detail.your_head_to_head.wins} – {detail.your_head_to_head.losses}</strong><p>Your wins – your losses · Recorded games only</p></section>}
 <div className="profile-sectionhead"><h3>Rating history</h3><div className="profile-range" role="group" aria-label="Rating chart range"><button className="secondary" aria-pressed={range==='recent'} onClick={()=>setRange('recent')}>Last 50 games</button><button className="secondary" aria-pressed={range==='all'} onClick={()=>setRange('all')}>All time</button></div></div>
 {detail&&<RatingChart name={p.name} history={detail.chart.history} startingRating={detail.chart.starting_rating} startGame={detail.chart.start_game}/>}
 <h3>Match history</h3>{resultError&&<div className="error" role="alert">{resultError} <button className="textbtn" onClick={()=>setRetry(n=>n+1)}>Retry results</button></div>}
 <div className="profile-results" aria-busy={loadingResults}>{history?history.matches.length?history.matches.map((g:any)=><div className="profile-result" key={g.id}><div><strong>{g.won?'Win':'Loss'} vs. {g.opponent}</strong><p>{new Date(g.played_at??g.confirmed).toLocaleDateString()}{g.note?' · '+g.note:''}</p></div><span className={g.delta>=0?'up':'down'}>{g.delta>0?'+':''}{Math.round(g.delta)}</span><strong>{Math.round(g.rating)}</strong></div>):<p>No recorded games yet.</p>:<p>Loading match history…</p>}</div>
 {history&&history.total>0&&<nav className="history-pagination profile-pagination" aria-label="Player result pages"><button className="secondary" disabled={loadingResults||history.page<=1} onClick={()=>setPage(history.page-1)}>Previous</button><span role="status">Page {history.page} of {Math.max(1,Math.ceil(history.total/10))}<small>{(history.page-1)*10+1}–{Math.min(history.page*10,history.total)} of {history.total} matches</small></span><button className="secondary" disabled={loadingResults||history.page>=Math.ceil(history.total/10)} onClick={()=>setPage(history.page+1)}>Next</button></nav>}
 {detail&&<><h3>Head to head</h3>{detail.head_to_head.length?detail.head_to_head.map((other:any)=><div className="h2h" key={other.id}>{other.name}<strong>{other.wins} – {other.losses}</strong></div>):<p>No head-to-head results yet.</p>}</>}
 </section></div>;
}
