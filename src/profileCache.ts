// Memory only. Keys include the signed-in identity and the ladder's audit revision.
export function createProfileCache(limit=64){
 const entries=new Map<string,Promise<any>>();
 return {
  get<T>(key:string,load:()=>Promise<T>):Promise<T>{
   const existing=entries.get(key);if(existing){entries.delete(key);entries.set(key,existing);return existing}
   const pending=Promise.resolve().then(load);entries.set(key,pending);
   while(entries.size>limit)entries.delete(entries.keys().next().value!);
   pending.catch(()=>{if(entries.get(key)===pending)entries.delete(key)});
   return pending;
  },
  clear(){entries.clear()}
 };
}
export type ProfileCache=ReturnType<typeof createProfileCache>;
