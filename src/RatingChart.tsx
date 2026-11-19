type Point={id:string;rating:number;confirmed?:string};
export function RatingChart({name,history}:{name:string;history:Point[]}){
 const values=[1000,...history.map(h=>h.rating)],width=380,height=180,left=44,right=12,top=16,bottom=30;
 const min=Math.floor((Math.min(...values)-16)/20)*20,max=Math.ceil((Math.max(...values)+16)/20)*20;
 const x=(i:number)=>left+(width-left-right)*(values.length===1?0:i/(values.length-1));
 const y=(v:number)=>top+(height-top-bottom)*(max-v)/(max-min);
 const ticks=[min,(min+max)/2,max];
 return <div className="rating-chart"><svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`${name} Elo rating history: starting at 1000, now ${Math.round(values.at(-1)!)}, across ${history.length} confirmed games.`}>
 <title>{name} — Elo rating history</title>
 {ticks.map(v=><g key={v}><line x1={left} x2={width-right} y1={y(v)} y2={y(v)} stroke="#e5e9e1"/><text x={left-8} y={y(v)+4} textAnchor="end">{Math.round(v)}</text></g>)}
 <line x1={left} x2={width-right} y1={y(1000)} y2={y(1000)} stroke="#a7b6a5" strokeDasharray="4 4"/>
 <polyline points={values.length===1?`${left},${y(1000)} ${width-right},${y(1000)}`:values.map((v,i)=>`${x(i)},${y(v)}`).join(' ')} fill="none" stroke="#20523f" strokeWidth="2.5" strokeLinejoin="round"/>
 {values.map((v,i)=><circle key={i} cx={x(i)} cy={y(v)} r={values.length>50?2:3.5} fill="#20523f"><title>{i===0?'Starting rating':`Game ${i}${history[i-1].confirmed?' · '+new Date(history[i-1].confirmed!).toLocaleDateString():''}`}: {Math.round(v)} Elo</title></circle>)}
 <text x={left} y={height-8}>Start</text><text x={width-right} y={height-8} textAnchor="end">{history.length?`Game ${history.length}`:'No confirmed games'}</text>
 </svg><p>Confirmed games, in rating order. Starting Elo: 1,000.</p></div>;
}
