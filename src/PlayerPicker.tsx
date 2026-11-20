import {useEffect,useId,useRef,useState} from 'react';
type Player={id:string;name:string};
export function PlayerPicker({players,value,onChange,label='Opponent',name='opponent',autoFocus=false}:{players:Player[];value:string;onChange:(id:string)=>void;label?:string;name?:string;autoFocus?:boolean}){
 const id=useId(),input=useRef<HTMLInputElement>(null),root=useRef<HTMLDivElement>(null),editing=useRef(false);
 const selectedName=players.find(p=>p.id===value)?.name??'';
 const [query,setQuery]=useState(selectedName),[open,setOpen]=useState(false),[active,setActive]=useState(0);
 const options=players.filter(p=>p.name.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()));
 useEffect(()=>{if(value){setQuery(selectedName);editing.current=false}else if(!editing.current)setQuery('')},[value,selectedName]);
 useEffect(()=>{input.current?.setCustomValidity(value&&selectedName?'':'Select a player from the list.')},[value,selectedName,query]);
 useEffect(()=>{if(open)document.getElementById(`${id}-option-${active}`)?.scrollIntoView?.({block:'nearest'})},[active,open,id]);
 function choose(p:Player){editing.current=false;onChange(p.id);setQuery(p.name);setOpen(false);input.current?.focus()}
 return <div className="player-picker" ref={root} onBlur={e=>{if(!e.currentTarget.contains(e.relatedTarget as Node))setOpen(false)}}><label htmlFor={id}>{label}</label><input type="hidden" name={name} value={value}/><input ref={input} id={id} autoFocus={autoFocus} value={query} placeholder="Search members…" autoComplete="off" required role="combobox" aria-autocomplete="list" aria-expanded={open} aria-controls={`${id}-options`} aria-activedescendant={open&&options[active]?`${id}-option-${active}`:undefined} onFocus={e=>{setOpen(true);e.currentTarget.select()}} onChange={e=>{editing.current=true;setQuery(e.target.value);setActive(0);setOpen(true);if(value)onChange('')}} onKeyDown={e=>{
  if(e.key==='ArrowDown'||e.key==='ArrowUp'){e.preventDefault();setOpen(true);setActive(i=>options.length?(i+(e.key==='ArrowDown'?1:-1)+options.length)%options.length:0)}
  else if(e.key==='Enter'&&open){e.preventDefault();if(options[active])choose(options[active])}
  else if(e.key==='Escape'){e.preventDefault();setOpen(false)}
 }}/>{open&&<div className="player-options" id={`${id}-options`} role="listbox" aria-label={`${label} choices`}>{options.length?options.map((p,i)=><div id={`${id}-option-${i}`} role="option" aria-selected={p.id===value} className={i===active?'highlighted':''} key={p.id} onMouseDown={e=>e.preventDefault()} onMouseEnter={()=>setActive(i)} onClick={()=>choose(p)}>{p.name}</div>):<p>No matching members.</p>}</div>}</div>;
}
