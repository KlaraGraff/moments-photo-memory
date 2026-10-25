/* Data-free embedded map. The parent owns photos, text and the selected dataset. */
const MapWorkspaceModel = (() => {
  const text=(v,n)=>typeof v==='string'&&v.length<=n&&!/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(v);
  const valid=p=>p.latitude!==null&&p.longitude!==null;
  function state(p){
    if(!p||!['zh','en','de'].includes(p.language)||!text(p.context,500)||!(p.focusedId===null||text(p.focusedId,200))||!Array.isArray(p.photos)||p.photos.length>10000)return null;
    const camera=p.camera===undefined?{mode:'overview',revision:0}:p.camera;
    if(!camera||!['overview','photo'].includes(camera.mode)||!Number.isSafeInteger(camera.revision)||camera.revision<0)return null;
    const ids=new Set(),photos=[];
    for(const row of p.photos){
      if(!row||!text(row.id,200)||!row.id||ids.has(row.id)||!text(row.title,1000)||!text(row.date,100)||!['latitude','longitude'].every(k=>row[k]===null||(typeof row[k]==='number'&&Number.isFinite(row[k])&&Math.abs(row[k])<=(k==='latitude'?90:180))))return null;
      ids.add(row.id);photos.push(Object.freeze({id:row.id,title:row.title,date:row.date,latitude:row.latitude,longitude:row.longitude}));
    }
    if(p.focusedId!==null&&!ids.has(p.focusedId))return null;
    return Object.freeze({language:p.language,context:p.context,focusedId:p.focusedId,camera:Object.freeze({mode:camera.mode,revision:camera.revision}),photos:Object.freeze(photos)});
  }
  function message(e,parent,origin,channel){
    if(!channel||e.source!==parent||!(e.origin==='null'||e.origin===origin))return null;
    const d=e.data;if(!d||d.protocol!=='moments-map-v1'||d.channel!==channel)return null;
    if(d.type==='state'){const p=state(d.payload);return p?{type:'state',payload:p}:null;}
    if(d.type==='visibility'&&d.payload&&typeof d.payload.visible==='boolean')return{type:'visibility',payload:{visible:d.payload.visible}};
    return null;
  }
  const signature=s=>JSON.stringify([s.context,s.photos.map(p=>[p.id,p.latitude,p.longitude]).sort((a,b)=>a[0].localeCompare(b[0]))]);
  function timestamp(value){
    // EXIF has no timezone: compare its recorded wall-clock values consistently in UTC.
    const m=/^(\d{4})[-:](\d{2})[-:](\d{2})(?:[ T](\d{2}):(\d{2}):(\d{2})(?:\.\d{1,3})?(Z|[+-]\d{2}:?\d{2})?)?$/.exec(value);
    if(!m)return null;
    const [y,mo,d,h,mi,se]=[m[1],m[2],m[3],m[4]||0,m[5]||0,m[6]||0].map(Number);
    if(y<100||mo<1||mo>12||d<1||d>31||h>23||mi>59||se>59)return null;
    const date=new Date(Date.UTC(y,mo-1,d,h,mi,se));
    if(date.getUTCFullYear()!==y||date.getUTCMonth()!==mo-1||date.getUTCDate()!==d)return null;
    let time=date.getTime();
    if(m[7]&&m[7]!=='Z'){const zone=/^([+-])(\d{2}):?(\d{2})$/.exec(m[7]);if(+zone[2]>23||+zone[3]>59)return null;time-=(zone[1]==='+'?1:-1)*(+zone[2]*60 + +zone[3])*60000;}
    return time;
  }
  const chronological=photos=>photos.filter(p=>valid(p)&&timestamp(p.date)!==null).slice().sort((a,b)=>timestamp(a.date)-timestamp(b.date)||a.id.localeCompare(b.id));
  function cameraPlan(photo,center,zoom){
    if(!photo||!valid(photo))return null;
    const radians=Math.PI/180,lat=(photo.latitude+center.lat)*radians/2;
    const distance=Math.hypot((photo.latitude-center.lat)*111195,(photo.longitude-center.lng)*111195*Math.cos(lat));
    const targetZoom=distance<=2000?Math.max(17,zoom):17;
    if(distance<0.05&&zoom>=targetZoom)return null;
    return {center:[photo.latitude,photo.longitude],zoom:targetZoom,nearby:distance<=2000};
  }
  return {state,message,valid,signature,chronological,timestamp,cameraPlan};
})();
(() => {
  if(typeof document==='undefined')return;
  const $=id=>document.getElementById(id),raw=new URLSearchParams(location.hash.slice(1)).get('channel'),channel=/^[a-f\d]{32,128}$/i.test(raw||'')?raw:null;
  if(!channel)return;
  const send=(type,payload={})=>window.parent.postMessage({protocol:'moments-map-v1',channel,type,payload},'*');
  const ready=()=>send('ready');ready();window.addEventListener('load',ready);
  let lastHeight=0;const resize=()=>{const height=Math.ceil(document.body.getBoundingClientRect().height);if(height!==lastHeight){lastHeight=height;send('size',{height});}};
  const observer=typeof ResizeObserver==='function'?new ResizeObserver(resize):null;observer?.observe(document.body);resize();
  if(location.protocol==='file:'){$('opening').textContent='Open Moments through its local entry to use the map.';return;}
  const words={
    en:{fit:'Show all',locate:'Locate current',sequence:'Chronological line (not actual roads)',wheel:'Reverse mouse wheel only',unavailable:'Wheel reversal unavailable',memory:'Preference applies to this session',loading:'Loading map tiles…',loaded:'Tiles for this view are loaded',error:'Some map tiles failed or timed out.',retry:'Retry',summary:(n,m)=>`${n} photo locations · ${m} photos without GPS`,noGPS:'The current photo has no GPS location.',empty:'No GPS locations in this selection.',map:'Photo locations',zoomIn:'Zoom in',zoomOut:'Zoom out'},
    zh:{fit:'查看全部',locate:'定位当前',sequence:'先后顺序线（不是实际道路）',wheel:'仅反转鼠标滚轮',unavailable:'当前地图不支持滚轮反转',memory:'偏好仅在本次会话生效',loading:'正在加载底图…',loaded:'当前视口底图已加载',error:'部分底图加载失败或超时。',retry:'重试',summary:(n,m)=>`${n} 个拍摄点 · ${m} 张照片无定位`,noGPS:'当前照片没有 GPS 定位。',empty:'当前选择中没有有效定位。',map:'拍摄地点',zoomIn:'放大',zoomOut:'缩小'},
    de:{fit:'Alle anzeigen',locate:'Aktuellen Ort zeigen',sequence:'Zeitliche Linie (keine tatsächlichen Straßen)',wheel:'Nur Mausrad umkehren',unavailable:'Mausrad-Umkehr nicht verfügbar',memory:'Einstellung gilt in dieser Sitzung',loading:'Karte wird geladen…',loaded:'Kartenausschnitt geladen',error:'Einige Kartenkacheln fehlen oder haben das Zeitlimit überschritten.',retry:'Erneut laden',summary:(n,m)=>`${n} Fotostandorte · ${m} Fotos ohne GPS`,noGPS:'Das aktuelle Foto hat keinen GPS-Standort.',empty:'Keine GPS-Standorte in dieser Auswahl.',map:'Fotostandorte',zoomIn:'Vergrößern',zoomOut:'Verkleinern'}};
  let state=null,map=null,tiles=null,wheel=null,panel=null,client=null,line=null,visible=true,pageSuspended=false,pendingCamera=null,overviewOverride=null,disposed=false,tileState='loading',failures=0,timer=null,lastStatus='',markers=new Map(),groupMeta=new Map(),stationNodes=new Map(),renderedData='',renderedLanguage='',renderedFocus=null;
  const t=()=>words[state?.language||'en'];const points=()=>state.photos.filter(MapWorkspaceModel.valid);
  function tileStatus(){const key=`${state?.language}|${tileState}`;if(key===lastStatus)return;lastStatus=key;$('status').replaceChildren(document.createTextNode(t()[tileState]));if(tileState==='error'){const b=document.createElement('button');b.textContent=t().retry;b.onclick=()=>{failures=0;tileState='loading';arm();tileStatus();tiles.redraw();};$('status').append(' ',b);}}
  function arm(){clearTimeout(timer);if(pageSuspended||!visible||disposed)return;timer=setTimeout(()=>{tileState='error';tileStatus();},15000);}
  function stopCamera(){
    // Leaflet 1.9.4 public stop() resets the view with zoomSnap:0; its pinned
    // internal stop only cancels motion. Complete CSS zoom before the next target.
    if(typeof map._stop==='function'){map._stop();if(map._animatingZoom)map._onZoomTransitionEnd?.();}
    else map.stop?.();
  }
  function fit(){const p=points();if(p.length){stopCamera();map.fitBounds(p.map(p=>[p.latitude,p.longitude]),{padding:[30,30],maxZoom:16,animate:false});}}
  function drawLine(){if(line)map.removeLayer(line);line=null;if($('sequence').checked){const p=MapWorkspaceModel.chronological(state.photos);if(p.length>1)line=L.polyline(p.map(p=>[p.latitude,p.longitude]),{dashArray:'6 8',weight:2,color:'#9b754e',interactive:false}).addTo(map);}}
  function init(){
    $('opening').hidden=true;$('workspace').hidden=false;
    const reduced=globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    map=L.map('map',{zoomControl:false,zoomSnap:0,zoomAnimation:!reduced,fadeAnimation:!reduced});map.setView([0,0],2);
    L.control.zoom({zoomInTitle:t().zoomIn,zoomOutTitle:t().zoomOut}).addTo(map);
    let storage;try{storage=localStorage;}catch{}wheel=MapWheel.create(map,{storage});
    tiles=L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,updateWhenZooming:false,updateWhenIdle:true,keepBuffer:3,attribution:'© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'});
    tiles.on('loading',()=>{failures=0;tileState='loading';arm();tileStatus();});tiles.on('tileerror',()=>{failures++;tileState='error';tileStatus();});tiles.on('load',()=>{clearTimeout(timer);tileState=failures?'error':'loaded';tileStatus();});arm();tiles.addTo(map);
    client=RoadRouting.create();mountPanel();
    $('fit').onclick=()=>{overviewOverride=state.camera.revision;pendingCamera=null;fit();};$('locate').onclick=()=>{overviewOverride=null;pendingCamera=null;focusCurrent();};$('sequence').onchange=drawLine;$('wheel-reverse').onchange=e=>{wheel.setReversed(e.target.checked);labels();};
  }
  function mountPanel(){
    if(panel||!visible||pageSuspended)return;
    const guardedClient={cancel:()=>client.cancel(),clearCache:()=>client.clearCache(),plan:args=>visible&&!pageSuspended&&!disposed?client.plan(args):Promise.reject(Object.assign(new Error('aborted'),{code:'aborted'}))};
    panel=RoadPanel.mount({host:$('road-panel'),map,L,client:guardedClient,getPoints:points,getContextKey:()=>MapWorkspaceModel.signature(state),getLanguage:()=>state.language,onFallback:()=>{$('sequence').checked=true;drawLine();}});
  }
  function reveal(){if(!state||disposed||!visible||pageSuspended)return;if(!map)init();mountPanel();render();map.scrollWheelZoom.enable();map.invalidateSize({pan:false});const intent=pendingCamera;pendingCamera=null;if(intent==='overview')fit();else if(intent==='photo')focusCurrent();}
  function focusCurrent(){
    const p=state.photos.find(p=>p.id===state.focusedId);
    if(!p||!MapWorkspaceModel.valid(p))return;
    // Finish the previous target before inspecting the view: an unfinished CSS
    // zoom may still report this photo's center while its pending target differs.
    stopCamera();
    const zoom=map.getZoom(),plan=MapWorkspaceModel.cameraPlan(p,map.getCenter(),zoom);
    if(!plan)return;
    // Camera zoom changes are immediate: Leaflet's CSS zoom schedules an
    // untracked animation frame. Same-scale nearby pans can safely stay smooth.
    const animate=plan.nearby&&plan.zoom===zoom&&!globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    map.setView(plan.center,plan.zoom,{animate,duration:0.25});
  }
  function labels(){
    document.documentElement.lang=state.language;
    for(const [id,key] of [['fit','fit'],['locate','locate'],['sequence-label','sequence'],['wheel-label','wheel']])$(id).textContent=t()[key];
    $('map').setAttribute('aria-label',t().map);$('stations').setAttribute('aria-label',t().map);
    for(const [selector,key]of[['.leaflet-control-zoom-in','zoomIn'],['.leaflet-control-zoom-out','zoomOut']]){const n=$('map').querySelector(selector);if(n){n.title=t()[key];n.setAttribute('aria-label',t()[key]);}}
    $('wheel-reverse').checked=wheel.reversed;$('wheel-reverse').disabled=!wheel.available;$('wheel-status').textContent=!wheel.available?t().unavailable:!wheel.persistent?t().memory:'';
  }
  function focusMessage(){const focus=state.photos.find(p=>p.id===state.focusedId);$('focus-status').textContent=focus&&!MapWorkspaceModel.valid(focus)?t().noGPS:!points().length?t().empty:'';$('locate').disabled=!focus||!MapWorkspaceModel.valid(focus);}
  function markerIcon(meta){return L.divIcon({className:'',html:`<span class="marker${meta.rows.some(p=>p.id===state.focusedId)?' active':''}">${meta.rows.length>1?meta.rows.length:meta.index}</span>`,iconSize:[30,30],iconAnchor:[15,15]});}
  function focusOnly(previous){
    const changed=new Set();for(const id of [previous,state.focusedId]){const button=stationNodes.get(id);if(button)button.setAttribute('aria-pressed',String(id===state.focusedId));const p=state.photos.find(p=>p.id===id);if(p&&MapWorkspaceModel.valid(p))changed.add(JSON.stringify([p.latitude,p.longitude]));}
    for(const key of changed){const meta=groupMeta.get(key),marker=markers.get(key);if(meta&&marker)marker.setIcon(markerIcon(meta));}
    focusMessage();
  }
  function render(){
    const data=JSON.stringify([state.context,state.photos.map(p=>[p.id,p.title,p.date,p.latitude,p.longitude])]);
    if(data===renderedData){
      if(state.language!==renderedLanguage){labels();focusMessage();const p=points();$('summary').textContent=t().summary(p.length,state.photos.length-p.length);panel?.update();tileStatus();renderedLanguage=state.language;}
      if(state.focusedId!==renderedFocus){focusOnly(renderedFocus);renderedFocus=state.focusedId;}
      resize();return;
    }
    renderedData=data;renderedLanguage=state.language;renderedFocus=state.focusedId;labels();
    const p=points(),focus=state.photos.find(p=>p.id===state.focusedId);$('summary').textContent=t().summary(p.length,state.photos.length-p.length);$('focus-status').textContent=focus&&!MapWorkspaceModel.valid(focus)?t().noGPS:!p.length?t().empty:'';$('fit').disabled=!p.length;$('locate').disabled=!focus||!MapWorkspaceModel.valid(focus);
    const groups=new Map();p.forEach(row=>{const key=JSON.stringify([row.latitude,row.longitude]);if(!groups.has(key))groups.set(key,[]);groups.get(key).push(row);});
    for(const [key,m]of markers)if(!groups.has(key)){map.removeLayer(m);markers.delete(key);}
    groupMeta.clear();let index=0;for(const [key,rows]of groups){index++;const meta={rows,index};groupMeta.set(key,meta);const icon=markerIcon(meta);let marker=markers.get(key);if(!marker){marker=L.marker([rows[0].latitude,rows[0].longitude],{icon,keyboard:true,title:rows.map(p=>p.title||p.id).join(' · '),alt:rows.map(p=>p.title||p.id).join(' · ')}).addTo(map);markers.set(key,marker);}else marker.setIcon(icon);
      const list=document.createElement('div');rows.forEach(p=>{const b=document.createElement('button');b.type='button';b.textContent=p.title||p.id;b.onclick=()=>send('select',{id:p.id});list.append(b);});marker.unbindPopup?.();marker.off('click');if(rows.length===1)marker.on('click',()=>send('select',{id:rows[0].id}));else marker.bindPopup(list);const label=rows.map(p=>p.title||p.id).join(' · '),element=marker.getElement?.();if(element){element.title=label;element.setAttribute('aria-label',label);element.setAttribute('role','button');}}
    $('stations').replaceChildren();stationNodes.clear();p.forEach(p=>{const b=document.createElement('button');b.type='button';b.className='station';b.textContent=p.title||p.id;b.setAttribute('aria-pressed',String(p.id===state.focusedId));b.onclick=()=>send('select',{id:p.id});$('stations').append(b);stationNodes.set(p.id,b);});drawLine();panel?.update();tileStatus();resize();
  }
  function cleanup(){if(disposed)return;disposed=true;clearTimeout(timer);observer?.disconnect();panel?.dispose();panel=null;client?.cancel();client?.clearCache();wheel?.dispose();map?.remove();window.removeEventListener('load',ready);window.removeEventListener('message',receive);}
  function suspend(){panel?.dispose();panel=null;client?.cancel();client?.clearCache();map?.scrollWheelZoom.disable();clearTimeout(timer);}
  function pagehide(e){if(e?.persisted){pageSuspended=true;suspend();}else cleanup();}
  function pageshow(e){if(e?.persisted&&!disposed){pageSuspended=false;if(visible){reveal();if(tiles?.isLoading?.())arm();}}}
  function receive(e){
    if(disposed)return;const m=MapWorkspaceModel.message(e,window.parent,location.origin,channel);if(!m)return;
    if(m.type==='visibility'){
      visible=m.payload.visible;
      if(!visible)suspend();
      else{reveal();if(tiles?.isLoading?.())arm();}
      return;
    }
    const previous=state;state=m.payload;const contextChanged=!previous||previous.context!==state.context;
    const revisionChanged=previous?.camera.revision!==state.camera.revision;
    if(contextChanged){overviewOverride=null;pendingCamera=state.camera.mode;}
    else {
      if(revisionChanged)overviewOverride=null;
      const cameraChanged=revisionChanged||previous.camera.mode!==state.camera.mode;
      const before=previous.photos.find(p=>p.id===previous.focusedId),after=state.photos.find(p=>p.id===state.focusedId);
      const pointChanged=before?.latitude!==after?.latitude||before?.longitude!==after?.longitude;
      if(state.camera.mode==='overview'&&cameraChanged)pendingCamera='overview';
      else if(state.camera.mode==='photo'&&overviewOverride===null&&(cameraChanged||previous.focusedId!==state.focusedId||pointChanged))pendingCamera='photo';
    }
    if(!visible||pageSuspended)return;
    reveal();
  }
  window.addEventListener('message',receive);window.addEventListener('pagehide',pagehide);window.addEventListener('pageshow',pageshow);window.addEventListener('unload',cleanup);
})();
