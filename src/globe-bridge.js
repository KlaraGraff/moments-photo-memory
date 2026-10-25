/* Small authenticated postMessage bridge for the 3D globe iframe. */
const ProductGlobe=(()=>{
  const protocol='moments-globe-v1';
  function snapshot(value){return JSON.parse(JSON.stringify(value||{language:'en',places:[],arcs:[],focusedId:null}));}
  function create({host,url,onSelect}){
    let frame=null,channel='',payload=null,ready=false,visible=false,sent='',disposed=false,timer=0;
    const status=document.createElement('p');status.className='footprints-globe-status';status.textContent='';host.append(status);
    function show(text){status.textContent=text||'';status.hidden=!text;}
    function send(type,data={}){if(!frame||!ready)return;frame.contentWindow.postMessage({protocol,channel,type,payload:data},new URL(url).origin);}
    function update(){if(!ready||!payload)return;const key=JSON.stringify(payload);if(key===sent)return;sent=key;send('state',payload);}
    function start(){if(disposed||!visible)return;clearTimeout(timer);frame?.remove();ready=false;sent='';const bytes=new Uint8Array(16);crypto.getRandomValues(bytes);channel=Array.from(bytes,n=>n.toString(16).padStart(2,'0')).join('');frame=document.createElement('iframe');frame.className='footprints-globe-frame';frame.referrerPolicy='no-referrer';frame.setAttribute('title','Moments 3D globe');const target=new URL(url);target.hash=new URLSearchParams({channel}).toString();frame.src=target.href;frame.addEventListener('error',()=>show('地球组件加载失败，本地地球仍可使用。'));host.prepend(frame);show('正在准备本地地球…');timer=setTimeout(()=>{if(!ready)show('本地地球仍可使用，外部引擎在后台连接中…')},5000);}
    function receive(event){const message=event.data;if(disposed||!frame||event.source!==frame.contentWindow||event.origin!==new URL(url).origin||!message||message.protocol!==protocol||message.channel!==channel)return;if(message.type==='ready'){ready=true;clearTimeout(timer);show('');send('visibility',{visible});update();}else if(message.type==='status'&&typeof message.payload?.text==='string'){show(message.payload.text)}else if(message.type==='size'&&Number.isFinite(message.payload?.height)){frame.style.height=Math.max(540,Math.ceil(message.payload.height))+'px';}else if(message.type==='select'&&typeof message.payload?.placeId==='string')onSelect?.(message.payload.placeId,message.payload.photoId||'');}
    window.addEventListener('message',receive);
    return {sync(value,isVisible=true){if(disposed)return;payload=snapshot(value);const changed=visible!==isVisible;visible=isVisible;if(visible&&!frame)start();if(!visible&&frame)send('visibility',{visible:false});if(changed&&visible&&ready)send('visibility',{visible:true});update();},dispose(){if(disposed)return;disposed=true;clearTimeout(timer);window.removeEventListener('message',receive);frame?.remove();status.remove();}};
  }
  return {create,snapshot};
})();

