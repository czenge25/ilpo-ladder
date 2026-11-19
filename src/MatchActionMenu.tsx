import {useEffect,useId,useRef,useState} from 'react';
import {createPortal} from 'react-dom';
import {MoreVertical} from 'lucide-react';

type Action={label:string;onSelect:()=>void;danger?:boolean};
export function MatchActionMenu({label,actions,disabled}:{label:string;actions:Action[];disabled?:boolean}){
 const [position,setPosition]=useState<{top:number;left:number}|null>(null);
 const trigger=useRef<HTMLButtonElement>(null),menu=useRef<HTMLDivElement>(null),initialFocus=useRef(0);
 const id=useId();
 function close(focus=false){setPosition(null);if(focus)trigger.current?.focus()}
 function open(last=false){
  const r=trigger.current!.getBoundingClientRect(),height=Math.max(actions.length,1)*40+10;
  initialFocus.current=last?Math.max(actions.length-1,0):0;
  setPosition({left:Math.max(8,Math.min(r.right-190,window.innerWidth-198)),top:Math.max(8,r.bottom+height+8>window.innerHeight?r.top-height-4:r.bottom+4)});
 }
 useEffect(()=>{
  if(!position)return;
  const buttons=menu.current?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)');
  if(buttons?.length)buttons[initialFocus.current]?.focus();else menu.current?.focus();
  const outside=(e:PointerEvent)=>{if(!menu.current?.contains(e.target as Node)&&!trigger.current?.contains(e.target as Node))close()};
  const dismiss=()=>close();
  document.addEventListener('pointerdown',outside);window.addEventListener('resize',dismiss);window.addEventListener('scroll',dismiss,true);
  return()=>{document.removeEventListener('pointerdown',outside);window.removeEventListener('resize',dismiss);window.removeEventListener('scroll',dismiss,true)};
 },[position]);
 useEffect(()=>{if(disabled)setPosition(null)},[disabled]);
 return <><button ref={trigger} className="match-menu-trigger" disabled={disabled} aria-label={label} aria-haspopup="menu" aria-expanded={!!position} aria-controls={position?id:undefined} onClick={()=>position?close():open()} onKeyDown={e=>{if(e.key==='ArrowDown'||e.key==='ArrowUp'){e.preventDefault();open(e.key==='ArrowUp')}}}><MoreVertical size={19}/></button>
 {position&&createPortal(<div ref={menu} id={id} role="menu" aria-label={label} tabIndex={-1} className="match-menu" style={position} onBlur={e=>{if(!e.currentTarget.contains(e.relatedTarget as Node))close()}} onKeyDown={e=>{
  if(e.key==='Escape'){e.preventDefault();close(true);return}
  const buttons=Array.from(menu.current?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')||[]),index=buttons.indexOf(document.activeElement as HTMLButtonElement);
  if(['ArrowDown','ArrowUp','Home','End'].includes(e.key)){e.preventDefault();const next=e.key==='Home'?0:e.key==='End'?buttons.length-1:(index+(e.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length;buttons[next]?.focus()}
 }}>{actions.length?actions.map(a=><button role="menuitem" className={a.danger?'danger':''} key={a.label} onClick={()=>{close(true);a.onSelect()}}>{a.label}</button>):<span role="menuitem" aria-disabled="true">No actions available</span>}</div>,document.body)}</>;
}
