import {test} from 'node:test';import assert from 'node:assert/strict';import {readFile,writeFile,mkdtemp,rm} from 'node:fs/promises';import {fileURLToPath,pathToFileURL} from 'node:url';import {join} from 'node:path';import {JSDOM} from 'jsdom';import ts from 'typescript';
test('account rank, personal dashboard, searchable opponents, and admin editing work through the app',async()=>{
 const dir=await mkdtemp(join(fileURLToPath(new URL('../',import.meta.url)),'.ui-test-')),dom=new JSDOM('<div id="root"></div>',{url:'https://example.test/',pretendToBeVisual:true}),saved=new Map();for(const key of ['window','document','HTMLElement','FormData','Event','MouseEvent','KeyboardEvent','localStorage','Node','navigator','IS_REACT_ACT_ENVIRONMENT'])saved.set(key,Object.getOwnPropertyDescriptor(globalThis,key));for(const key of ['window','document','HTMLElement','FormData','Event','MouseEvent','KeyboardEvent','localStorage','Node'])globalThis[key]=dom.window[key];Object.defineProperty(globalThis,'navigator',{value:dom.window.navigator,configurable:true});globalThis.IS_REACT_ACT_ENVIRONMENT=true;
 let root;try{
 const files=['App','PinEditor','RatingChart','MatchActionMenu','MatchHistory','PlayerProfile','profileCache','usePageVisibility','Dashboard','PlayerPicker','EditResultDialog'];
 for(const file of files){const extension=['profileCache','usePageVisibility'].includes(file)?'ts':'tsx';let s=await readFile(new URL(`../src/${file}.${extension}`,import.meta.url),'utf8');for(const d of ['backend',...files])s=s.replaceAll(`'./${d}'`,`'./${d}.mjs'`);s=s.replaceAll('import.meta.env.BASE_URL',"'/'");await writeFile(join(dir,file+'.mjs'),ts.transpileModule(s,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX}}).outputText)}
 await writeFile(join(dir,'backend.mjs'),await readFile(new URL('./fixtures/lazy-backend.mjs',import.meta.url),'utf8'));const React=await import('react'),{createRoot}=await import('react-dom/client'),{default:App}=await import(pathToFileURL(join(dir,'App.mjs'))),backend=await import(pathToFileURL(join(dir,'backend.mjs'))),act=React.act;
 root=createRoot(document.getElementById('root'));const click=async el=>{assert.ok(el);await act(async()=>el.dispatchEvent(new MouseEvent('click',{bubbles:true})))},button=label=>Array.from(document.querySelectorAll('button')).find(b=>b.textContent.trim()===label),submit=async()=>act(async()=>document.querySelector('form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true})));
 const type=async(input,value)=>act(async()=>{Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype,'value').set.call(input,value);input.dispatchEvent(new Event('input',{bubbles:true}))});
 await act(async()=>root.render(React.createElement(App)));assert.match(document.querySelector('.identity-button').textContent,/#1 · 1,016 Elo/);await click(button('Dashboard'));assert.equal(backend.calls.dashboard,1);assert.match(document.querySelector('.dashboard').textContent,/3W/);assert.match(document.querySelector('.most-played').textContent,/63 games · 40 wins – 23 losses/);assert.match(document.querySelector('.personal-stats').textContent,/\+16/);
 const period=document.querySelector('[aria-label="Dashboard rating change period"]');await act(async()=>{period.value='day';period.dispatchEvent(new Event('change',{bubbles:true}))});assert.match(document.querySelector('.personal-stats').textContent,/\+8/);
 await click(button('Record a game'));const input=document.querySelector('[role="combobox"]');await act(async()=>input.focus());assert.ok(!document.querySelector('[role="listbox"]').textContent.includes('Alice Example'));await type(input,'nobody');assert.match(document.querySelector('[role="listbox"]').textContent,/No matching members/);assert.equal(input.checkValidity(),false);await type(input,'bo');assert.equal(document.querySelectorAll('[role="option"]').length,1);await act(async()=>input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true})));assert.equal(document.querySelector('[name="opponent"]').value,'b');assert.equal(input.checkValidity(),true);assert.equal(document.querySelector('[name="winner"]').options.length,3);document.querySelector('[name="winner"]').value='a';await submit();assert.equal(backend.calls.writes[0].body.winner,'a');assert.equal(backend.calls.writes[0].body.loser,'b');assert.equal(backend.calls.writes[0].token,'f'.repeat(64));assert.equal(backend.calls.dashboard,2);assert.match(document.querySelector('.personal-stats').textContent,/4W/);
 await click(document.querySelector('.most-played .textbtn'));assert.equal(document.querySelector('[aria-label="Player profile"] h2').textContent,'Bob Example');await click(document.querySelector('[aria-label="Close"]'));await click(document.querySelector('.dashboard .match-menu-trigger'));assert.equal(Array.from(document.querySelectorAll('[role="menuitem"]')).some(b=>b.textContent==='Edit result'),false);await act(async()=>document.querySelector('[role="menu"]').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true})));
 await click(button('Leaderboard'));
 await click(button('Doubles'));assert.equal(document.querySelectorAll('tbody tr').length,1);assert.match(document.querySelector('tbody').textContent,/Alice Example.*1,008/);assert.match(document.querySelector('.identity-button').textContent,/1,016 Elo/);
 await click(document.querySelector('tbody tr'));assert.equal(backend.calls.profiles.at(-1).ladder,'doubles');assert.match(document.querySelector('[aria-labelledby="doubles-partners-heading"]').textContent,/Bob Example1 W · 0 L/);
 const resultPairs=Array.from(document.querySelectorAll('.result-elo-pair')).map(el=>el.textContent);
 assert.ok(resultPairs.includes('+8 Overall+16 Doubles'));assert.ok(resultPairs.includes('−8 Overall−16 Doubles'));
 await click(document.querySelector('[aria-label="Profile rating view"] button'));assert.equal(backend.calls.profiles.at(-1).ladder,'overall');assert.equal(document.getElementById('doubles-partners-heading'),null);
 await click(document.querySelector('[aria-label="Close"]'));await click(button('Overall'));
 const setField=async(name,value)=>act(async()=>{const field=document.querySelector(`[name="${name}"]`);field.value=value;field.dispatchEvent(new Event('change',{bubbles:true}))});
 await click(button('Record a game'));
 const memberFormat=(value)=>act(async()=>{const el=document.querySelector('[aria-label="Record game"] select');el.value=value;el.dispatchEvent(new Event('change',{bubbles:true}))});
 await memberFormat('doubles');
 const choosePlayer=async(label,query,name)=>{
  const el=Array.from(document.querySelectorAll('[role="combobox"]')).find(input=>input.labels[0].textContent===label);
  assert.ok(el);await act(async()=>el.focus());
  assert.doesNotMatch(document.querySelector('[role="listbox"]').textContent,/Alice Example/);
  await type(el,query);assert.equal(el.checkValidity(),false);
  const option=document.querySelector('[role="listbox"] [role="option"]');
  assert.equal(option.textContent,name);await click(option);assert.equal(el.checkValidity(),true);
 };
 assert.equal(document.querySelectorAll('[role="combobox"]').length,3);
 await choosePlayer('Partner','bo','Bob Example');
 const firstOpponent=Array.from(document.querySelectorAll('[role="combobox"]')).find(input=>input.labels[0].textContent==='First opponent');
 await act(async()=>firstOpponent.focus());assert.doesNotMatch(document.querySelector('[role="listbox"]').textContent,/Bob Example/);
 await choosePlayer('First opponent','ca','Casey Example');await choosePlayer('Second opponent','dr','Drew Example');
 const selections=new FormData(document.querySelector('[aria-label="Record game"] form'));
 assert.deepEqual(['partner','opponent_one','opponent_two'].map(name=>selections.get(name)),['b','c','d']);
 await memberFormat('singles');await memberFormat('doubles');assert.equal(document.querySelector('[name="partner"]').value,'');
 await click(document.querySelector('[aria-label="Record game"] [aria-label="Close"]'));
 await click(button('Sign out'));await click(button('Admin sign-in'));document.querySelector('[name="email"]').value='admin@example.test';document.querySelector('[name="password"]').value='fixture';await submit();await click(document.querySelector('.recent .match-menu-trigger'));await click(button('Edit result'));assert.ok(document.querySelector('[aria-label="Edit result"]'));assert.equal(document.querySelectorAll('[role="dialog"]').length,1);
 await setField('winner','b');await setField('loser','b');await submit();assert.match(document.querySelector('[aria-label="Edit result"]').textContent,/two different players/);assert.equal(backend.calls.writes.length,1);await setField('loser','a');document.querySelector('[name="played_at"]').value='2026-01-01T18:30';document.querySelector('[name="note"]').value='Corrected result';await submit();assert.equal(backend.calls.writes.length,2);const edit=backend.calls.writes[1];assert.equal(edit.body.action,'edit_result');assert.equal(edit.body.winner,'b');assert.equal(edit.body.loser,'a');assert.equal(edit.body.note,'Corrected result');assert.equal(edit.body.played_at,new Date('2026-01-01T18:30').toISOString());assert.equal(edit.token,undefined);assert.equal(document.querySelector('[aria-label="Edit result"]'),null);assert.match(document.querySelector('.recent').textContent,/Corrected result/);
 await click(button('Record a game'));
 const format=Array.from(document.querySelectorAll('select')).find(s=>s.options[1]?.value==='doubles');
 await act(async()=>{format.value='doubles';format.dispatchEvent(new Event('change',{bubbles:true}))});
 await setField('team_a','a');await setField('partner','b');await setField('opponent_one','c');await setField('opponent_two','b');await setField('winning_team','b');
 await submit();assert.equal(backend.calls.writes.length,2);assert.match(document.querySelector('[aria-label="Record game"] .error').textContent,/four different players/);
 await setField('opponent_two','d');await submit();
 const doubles=backend.calls.writes[2].body;
 assert.deepEqual([doubles.winner,doubles.winner_partner,doubles.loser,doubles.loser_partner],['c','d','a','b']);
 assert.match(document.querySelector('.recent').textContent,/Casey Example & Drew Example vs. Alice Example & Bob Example/);
 assert.match(document.querySelector('.recent').textContent,/\+8 Overall · \+16 Doubles per winner/);
 await click(document.querySelector('.recent .match-menu-trigger'));await click(button('Edit result'));
 await click(button('Swap winning and losing teams'));await submit();
 const corrected=backend.calls.writes[3].body;
 assert.deepEqual([corrected.winner,corrected.winner_partner,corrected.loser,corrected.loser_partner],['a','b','c','d']);
 }finally{if(root){const {act}=await import('react');await act(async()=>root.unmount())}dom.window.close();for(const [key,value] of saved){if(value)Object.defineProperty(globalThis,key,value);else delete globalThis[key]}await rm(dir,{recursive:true,force:true})}
});
