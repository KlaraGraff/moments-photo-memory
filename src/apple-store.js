/* Local-only Apple Photos persistence. No credentials or helper addresses are stored. */
const AppleImportStore = (() => {
  const NAME = 'moments-apple-photos-v1', validID = id => /^APL[a-f0-9]{64}$/.test(id || '');
  const sourceFields = ['source','localIdentifier','date','timeSource','dateBasis','creationDate','originalDate','originalTimeZone','captureLocalDate','type','width','height','geo','favorite','duration','durationSeconds','previewState'];
  function merge(old, next) {
    if (!validID(next.id)) throw new Error('Invalid Apple Photos identifier');
    if (!old) return {...next};
    const result = {...old};
    for (const key of sourceFields) if (Object.hasOwn(next,key)) result[key]=next[key];
    if(old.previewState==='available'&&next.previewState!=='available')result.previewState='available';
    if (/^data:image\/(jpeg|png|webp);base64,/.test(next.previewURL || next.dataURI || '')) { result.previewURL=next.previewURL;result.dataURI=next.dataURI; }
    return result;
  }
  function open() { return new Promise((resolve,reject)=>{
    if (typeof indexedDB==='undefined') return reject(new Error('Local database unavailable'));
    const request=indexedDB.open(NAME,1);
    request.onupgradeneeded=()=>{const db=request.result;db.createObjectStore('assets',{keyPath:'id'});db.createObjectStore('groups',{keyPath:'id'});};
    request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);request.onblocked=()=>reject(new Error('Close other Moments tabs and retry'));
  }); }
  async function load() {
    const db=await open();try {return await new Promise((resolve,reject)=>{const tx=db.transaction(['assets','groups'],'readonly'),a=tx.objectStore('assets').getAll(),g=tx.objectStore('groups').getAll();tx.oncomplete=()=>{const assets=a.result.filter(x=>validID(x.id));const known=new Set(assets.map(x=>x.id));resolve({assets,groups:g.result.map(x=>({...x,items:x.items.filter(i=>i.every(id=>known.has(id)))})),favoriteIds:assets.filter(x=>x.favorite).map(x=>x.id)});};tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error||new Error('Read aborted'));});}finally{db.close();}
  }
  async function upsert(assets,group) {
    assets.forEach(a=>{if(!validID(a.id))throw new Error('Invalid Apple Photos identifier');});
    const db=await open();try{return await new Promise((resolve,reject)=>{const tx=db.transaction(['assets','groups'],'readwrite'),store=tx.objectStore('assets'),committed=[];
      for(const asset of assets){const request=store.get(asset.id);request.onsuccess=()=>{const value=merge(request.result,asset);store.put(value);committed.push(value);};}
      if(group){const gs=tx.objectStore('groups'),r=gs.get(group.id);r.onsuccess=()=>{const ids=new Set((r.result?.items||[]).flat());for(const a of assets)ids.add(a.id);gs.put({...group,items:[...ids].map(id=>[id])});};}
      tx.oncomplete=()=>resolve(committed);tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error||new Error('Save aborted'));});}finally{db.close();}
  }
  return {load,upsert,merge,validID,NAME};
})();
if(typeof module!=='undefined')module.exports=AppleImportStore;
