/* Keeps the writing page in its original tab/origin; only map metadata crosses. */
const ProductMap = (() => {
  const protocol = 'moments-map-v1';
  const copy = {
    zh:{title:'地点与路线',loading:'正在连接地图…',ready:'地图与当前照片同步',error:'地图暂未连接。照片和回忆仍可继续使用。',retry:'重试地图'},
    en:{title:'Places & routes',loading:'Connecting to the map…',ready:'Map synced with the current photos',error:'Map unavailable. You can still browse photos and write memories.',retry:'Retry map'},
    de:{title:'Orte & Routen',loading:'Karte wird verbunden…',ready:'Karte mit den aktuellen Fotos synchronisiert',error:'Karte nicht verfügbar. Fotos und Erinnerungen können weiter genutzt werden.',retry:'Karte erneut laden'}
  };
  function snapshot(value) {
    const seen=new Set();
    const photos=(value.photos||[]).filter(p=>p&&typeof p.id==='string'&&!seen.has(p.id)&&(seen.add(p.id),true)).map(p=>({
      id:p.id,title:String(p.title||'').slice(0,400),date:typeof p.date==='string'?p.date.slice(0,40):'',
      latitude:typeof p.latitude==='number'&&Number.isFinite(p.latitude)&&Math.abs(p.latitude)<=90?p.latitude:null,
      longitude:typeof p.longitude==='number'&&Number.isFinite(p.longitude)&&Math.abs(p.longitude)<=180?p.longitude:null
    }));
    const camera={mode:value.camera?.mode==='photo'?'photo':'overview',revision:Number.isSafeInteger(value.camera?.revision)&&value.camera.revision>=0?value.camera.revision:0};
    return {language:copy[value.language]?value.language:'zh',context:String(value.context||'').slice(0,500),focusedId:photos.some(p=>p.id===value.focusedId)?value.focusedId:null,photos,camera};
  }
  function create({host,url,onSelect,onStatus}) {
    const address=new URL(url,location.href);
    if(!['http:','https:','file:'].includes(address.protocol)||!(address.origin===location.origin||(['127.0.0.1','localhost','[::1]'].includes(address.hostname)&&address.protocol==='http:')))throw Error('Map endpoint must be local');
    let frame=null,channel='',ready=false,disposed=false,visible=false,payload=null,sent='',timer=null,state='loading';
    const language=()=>payload?.language||'zh';
    const status=document.createElement('p');status.className='product-map-status';status.setAttribute('role','status');
    const retry=document.createElement('button');retry.type='button';retry.className='product-map-retry';retry.addEventListener('click',start);
    host.append(status,retry);
    function showStatus(next=state){state=next;const c=copy[language()];status.textContent=c[next];retry.textContent=c.retry;retry.hidden=next!=='error';if(frame)frame.title=c.title;onStatus?.(next);}
    function send(type,data){if(frame&&ready)frame.contentWindow.postMessage({protocol,channel,type,payload:data},address.origin==='null'?'*':address.origin);}
    function update(){if(!ready||!payload)return;const key=JSON.stringify(payload);if(key===sent)return;sent=key;send('state',payload);}
    function start(){
      if(disposed)return;
      clearTimeout(timer);frame?.remove();ready=false;sent='';
      const bytes=new Uint8Array(16);crypto.getRandomValues(bytes);channel=Array.from(bytes,n=>n.toString(16).padStart(2,'0')).join('');
      frame=document.createElement('iframe');frame.className='product-map-frame';frame.referrerPolicy='no-referrer';
      const target=new URL(address);target.hash=new URLSearchParams({channel}).toString();frame.src=target.href;
      frame.addEventListener('error',()=>showStatus('error'));host.prepend(frame);showStatus('loading');
      timer=setTimeout(()=>{if(!ready)showStatus('error');},15000);
    }
    function message(e){
      const m=e.data;
      if(disposed||!frame||e.source!==frame.contentWindow||e.origin!==address.origin||!m||m.protocol!==protocol||m.channel!==channel)return;
      if(m.type==='ready'){
        ready=true;sent='';clearTimeout(timer);showStatus('ready');send('visibility',{visible});update();
      }else if(ready&&m.type==='select'&&typeof m.payload?.id==='string'&&payload?.photos.some(p=>p.id===m.payload.id))onSelect?.(m.payload.id);
      else if(ready&&m.type==='size'&&Number.isFinite(m.payload?.height))frame.style.height=Math.max(480,Math.min(1600,Math.ceil(m.payload.height)))+'px';
    }
    window.addEventListener('message',message);
    return {
      sync(value,isVisible=true){if(disposed)return;payload=snapshot(value);const changed=visible!==isVisible;visible=isVisible;if(visible&&!frame)start();showStatus();if(changed)send('visibility',{visible});update();},
      dispose(){if(disposed)return;disposed=true;clearTimeout(timer);window.removeEventListener('message',message);frame?.remove();status.remove();retry.remove();},
      get ready(){return ready;}
    };
  }
  return {create,snapshot};
})();
