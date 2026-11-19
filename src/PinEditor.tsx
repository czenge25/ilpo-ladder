import {useState} from 'react';
export const pinInputProps={type:'password',inputMode:'numeric',pattern:'[0-9]{6}',minLength:6,maxLength:6,required:true} as const;
export function PinEditor({initial,busy,onSave}:{initial:boolean;busy:boolean;onSave:(current:string,next:string)=>Promise<void>}){
 const [error,setError]=useState('');
 return <form onSubmit={async e=>{e.preventDefault();const f=new FormData(e.currentTarget),next=String(f.get('newPin'));if(next!==f.get('confirmPin')){setError('The PINs do not match.');return}setError('');await onSave(String(f.get('currentPin')||''),next)}}>
 {!initial&&<label>Current PIN<input {...pinInputProps} name="currentPin" autoComplete="current-password" autoFocus/></label>}
 <label>{initial?'Create a six-digit PIN':'New six-digit PIN'}<input {...pinInputProps} name="newPin" autoComplete="new-password" autoFocus={initial}/></label>
 <label>Confirm your {initial?'':'new '}PIN<input {...pinInputProps} name="confirmPin" autoComplete="new-password"/></label>
 {error&&<p role="alert" className="pin-error">{error}</p>}
 <button className="primary wide" disabled={busy}>{busy?'Saving…':initial?'Set PIN and continue':'Change PIN'}</button>
 </form>;
}
