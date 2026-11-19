import {useEffect,useState,type ReactNode} from 'react';
import {loadMatchHistory} from './backend';
import {usePageVisibility} from './usePageVisibility';
type Page={matches:any[];total:number;page:number;page_size:number};
export function MatchHistory({token,revision,renderMatches}:{token?:string;revision:unknown;renderMatches:(matches:any[])=>ReactNode}){
 const visible=usePageVisibility();
 const [page,setPage]=useState(1),[result,setResult]=useState<Page|null>(null),[loading,setLoading]=useState(true),[error,setError]=useState(''),[retry,setRetry]=useState(0);
 useEffect(()=>{if(!visible)return;let alive=true;setLoading(true);setError('');loadMatchHistory(page,token).then(next=>{if(!alive)return;setResult(next);if(next.page!==page)setPage(next.page)}).catch(e=>{if(alive)setError(e.message)}).finally(()=>{if(alive)setLoading(false)});return()=>{alive=false}},[page,token,revision,retry,visible]);
 const pages=Math.max(1,Math.ceil((result?.total??0)/10));
 return <section className="panel match-history" aria-label="Match history"><div className="panelhead"><h2>Match history {result&&<span className="count">{result.total}</span>}</h2><span className="tag">10 PER PAGE</span></div>
 {error&&<div className="history-error" role="alert">{error} <button className="textbtn" onClick={()=>setRetry(n=>n+1)}>Retry</button></div>}
 <div aria-busy={loading}>{result?renderMatches(result.matches):<div className="empty compact">{error?'Unable to load match history.':'Loading match history…'}</div>}</div>
 {result&&<nav className="history-pagination" aria-label="Match history pages"><button className="secondary" disabled={loading||result.page<=1} onClick={()=>setPage(result.page-1)}>Previous</button><span role="status">{loading?'Loading…':`Page ${result.page} of ${pages}`}{!loading&&result.total>0&&<small>{(result.page-1)*10+1}–{Math.min(result.page*10,result.total)} of {result.total} matches</small>}</span><button className="secondary" disabled={loading||result.page>=pages} onClick={()=>setPage(result.page+1)}>Next</button></nav>}
 </section>;
}
