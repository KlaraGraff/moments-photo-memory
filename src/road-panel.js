/* Inline road planning UI. Consent exists only for this mounted session. */
const RoadPanel = (() => {
  let sequence = 0;
  const copy = {
    zh: {toggle:'沿道路规划',start:'起点',end:'终点',mode:'出行方式',car:'驾车',foot:'步行',bike:'骑行',plan:'规划路线',reference:'规划参考，不代表历史实际轨迹',hint:'改变选择后不会自动发送请求。',ready:'选择两个拍摄点，查看沿道路的走法。',empty:'不足两个带有效定位的拍摄点。',same:'请选择两个位置不同的拍摄点。',ask:'允许向 FOSSGIS 发送所选两点的位置吗？',privacy:'许可仅在当前标签页会话有效，适用于你主动点击规划的两点路线请求，绝不自动发送。接收方为 FOSSGIS（routing.openstreetmap.de）。仅发送所选两个点的经纬度和出行方式；不发送名称、照片或回忆。服务会记录请求。',fixMap:'地图纠错',about:'服务说明',policy:'隐私说明',allow:'允许并规划',deny:'先不发送',loading:'正在规划这两个点之间的路线…',cancel:'取消规划',clear:'清除路线',revoke:'撤销发送许可',fallback:'查看先后虚线',approx:'约',minutes:'分钟',provider:'规划参考',snap:'所选位置距离道路超过 200 米，请核对起终点。',errors:{aborted:'已取消规划',timeout:'规划超时，请重试', 'rate-limit':'请求过于频繁，请稍后重试','no-route':'这两个点之间未找到可用道路',network:'无法连接路线服务，请稍后重试','invalid-response':'路线服务返回的数据无效','invalid-points':'请选择两个有效且不同的位置','invalid-mode':'出行方式无效','consent-required':'请先允许发送坐标'}},
    en: {toggle:'Plan along roads',start:'Start',end:'End',mode:'Travel mode',car:'Driving',foot:'Walking',bike:'Cycling',plan:'Plan route',reference:'Planning reference; does not represent your actual past journey',hint:'Changing selections never sends a request automatically.',ready:'Choose two photo locations to plan a road route.',empty:'Fewer than two photo locations have valid GPS coordinates.',same:'Choose two photo locations with different coordinates.',ask:'Allow sending these two locations to FOSSGIS?',privacy:'Permission applies only in this tab session to two-point routes you explicitly request; requests are never automatic. Recipient: FOSSGIS (routing.openstreetmap.de). Only the two selected coordinates and travel mode are sent; no names, photos or memories. The service logs requests.',fixMap:'Fix the map',about:'About the service',policy:'Privacy policy',allow:'Allow and plan',deny:'Do not send',loading:'Planning a route between these two locations…',cancel:'Cancel planning',clear:'Clear route',revoke:'Revoke permission',fallback:'View chronological dotted line',approx:'About',minutes:'min',provider:'Planning reference',snap:'A selected location is over 200 m from the road. Check the endpoints.',errors:{aborted:'Planning cancelled',timeout:'Request timed out; please retry','rate-limit':'Too many requests; try again later','no-route':'No road route found between these locations',network:'Cannot connect to the routing service','invalid-response':'The service returned invalid route data','invalid-points':'Choose two valid, different locations','invalid-mode':'Invalid travel mode','consent-required':'Allow sending coordinates first'}},
    de: {toggle:'Route entlang Straßen',start:'Start',end:'Ziel',mode:'Fortbewegung',car:'Auto',foot:'Zu Fuß',bike:'Fahrrad',plan:'Route planen',reference:'Planungsreferenz; bildet keine tatsächlich zurückgelegte Strecke ab',hint:'Eine geänderte Auswahl sendet niemals automatisch eine Anfrage.',ready:'Zwei Fotostandorte für eine Straßenroute auswählen.',empty:'Weniger als zwei Fotostandorte haben gültige GPS-Koordinaten.',same:'Zwei Fotostandorte mit unterschiedlichen Koordinaten auswählen.',ask:'Diese zwei Standorte an FOSSGIS senden?',privacy:'Die Erlaubnis gilt nur in dieser Tab-Sitzung für bewusst angeforderte Zwei-Punkt-Routen; Anfragen erfolgen niemals automatisch. Empfänger: FOSSGIS (routing.openstreetmap.de). Gesendet werden nur die zwei gewählten Koordinaten und die Fortbewegungsart; keine Namen, Fotos oder Erinnerungen. Der Dienst protokolliert Anfragen.',fixMap:'Kartenfehler melden',about:'Über den Dienst',policy:'Datenschutz',allow:'Erlauben und planen',deny:'Nicht senden',loading:'Route zwischen diesen beiden Standorten wird geplant…',cancel:'Planung abbrechen',clear:'Route löschen',revoke:'Erlaubnis widerrufen',fallback:'Zeitliche Punktlinie anzeigen',approx:'Etwa',minutes:'Min.',provider:'Planungsreferenz',snap:'Ein Standort liegt über 200 m von der Straße entfernt. Endpunkte prüfen.',errors:{aborted:'Planung abgebrochen',timeout:'Zeitüberschreitung; erneut versuchen','rate-limit':'Zu viele Anfragen; später versuchen','no-route':'Keine Straßenroute zwischen diesen Standorten gefunden',network:'Routendienst nicht erreichbar','invalid-response':'Der Dienst hat ungültige Routendaten geliefert','invalid-points':'Zwei gültige, unterschiedliche Standorte auswählen','invalid-mode':'Ungültige Fortbewegungsart','consent-required':'Zuerst das Senden der Koordinaten erlauben'}}
  };
  function mount({host,map,L,client,getPoints,getContextKey,getLanguage,onFallback}) {
    const prefix = `road-${++sequence}`;
    let renderedSignature='',renderedOpen=false;
    let points=[],context,initialized=false,start='',end='',mode='car',open=false,consent=false,status='ready',errorCode='',result=null,line=null,token=0,disposed=false;
    const valid = p => p && typeof p.latitude==='number' && Number.isFinite(p.latitude) && Math.abs(p.latitude)<=90 && typeof p.longitude==='number' && Number.isFinite(p.longitude) && Math.abs(p.longitude)<=180;
    const t = () => copy[getLanguage?.()] || copy.en;
    const find = id => points.find(p=>String(p.id)===id);
    const usable = () => {const a=find(start),b=find(end);return a&&b&&start!==end&&(a.latitude!==b.latitude||a.longitude!==b.longitude);};
    function clear(){token++;client.cancel();if(line){map.removeLayer(line);line=null;}result=null;status='ready';errorCode='';}
    function el(tag,text,className){const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(className)n.className=className;return n;}
    function button(text,action,key){const n=el('button',text);n.type='button';n.dataset.roadFocus=key;n.addEventListener('click',()=>{if(!disposed)action();});return n;}
    function render(){
      if(disposed)return;
      const signature=JSON.stringify([context,getLanguage?.(),points.map(p=>[p.id,p.title,p.latitude,p.longitude]),status,errorCode,start,end,mode,open,consent,result]);
      if(signature===renderedSignature)return;
      renderedSignature=signature;
      const opening=open&&!renderedOpen;renderedOpen=open;
      const hadFocus=host.contains(document.activeElement);
      const focus=hadFocus?document.activeElement.dataset.roadFocus:null;
      const c=t();host.replaceChildren();host.classList.add('road-planning');
      const toggle=button(c.toggle,()=>{if(open){const prior=host.querySelector('.road-body');open=false;renderedSignature='';renderedOpen=false;clear();if(prior&&!globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches&&typeof prior.animate==='function'){prior.inert=true;prior.setAttribute('aria-hidden','true');const animation=prior.animate([{opacity:1,transform:'translateY(0)'},{opacity:0,transform:'translateY(-5px)'}],{duration:120,easing:'ease-in'});toggle.setAttribute('aria-expanded','false');animation.finished.then(()=>{if(!disposed&&!open)render();}).catch(()=>{});}else render();}else{open=true;render();}},'toggle');toggle.className='road-toggle';toggle.setAttribute('aria-expanded',String(open));toggle.setAttribute('aria-controls',`${prefix}-body`);host.append(toggle);
      const body=el('div',undefined,`road-body${opening?' road-enter':''}`);body.id=`${prefix}-body`;body.hidden=!open;host.append(body);if(!open){restore();return;}
      const form=el('div',undefined,'road-form');body.append(form);
      function select(label,key,value,options){const wrap=el('label',label);const s=el('select');s.id=`${prefix}-${key}`;s.dataset.roadFocus=key;for(const [v,title] of options){const o=el('option',title);o.value=v;s.append(o);}s.value=value;s.disabled=points.length<2;s.addEventListener('change',()=>{if(disposed)return;if(key==='start')start=s.value;else if(key==='end')end=s.value;else mode=s.value;clear();render();});wrap.append(s);form.append(wrap);}
      const opts=points.map((p,i)=>[String(p.id),`${i+1} · ${p.title||`${c.start} ${i+1}`}`]);select(c.start,'start',start,opts);select(c.end,'end',end,opts);select(c.mode,'mode',mode,['car','foot','bike'].map(m=>[m,c[m]]));
      const plan=button(c.plan,()=>{if(!usable())return;if(!consent){status='consent';render();}else request();},'plan');plan.className='road-primary';plan.disabled=status==='loading'||!usable();form.append(plan);
      body.append(el('p',`${c.reference}。 ${c.hint}`,'road-caption'));
      const state=el('div',undefined,'road-state');state.setAttribute('aria-live','polite');state.setAttribute('aria-atomic','true');body.append(state);
      if(points.length<2)state.append(el('strong',c.empty));
      else if(!usable())state.append(el('strong',c.same));
      else if(status==='consent'){
        state.append(el('strong',c.ask),el('p',c.privacy));
        for(const [url,label] of [['https://routing.openstreetmap.de/about.html',c.about],['https://www.fossgis.de/datenschutzerkl%C3%A4rung',c.policy]]){const a=el('a',label);a.href=url;a.target='_blank';a.rel='noopener noreferrer';state.append(a,document.createTextNode(' '));}
        const actions=el('div',undefined,'road-actions');const allow=button(c.allow,()=>{consent=true;request();},'allow');allow.className='road-primary';actions.append(allow,button(c.deny,()=>{status='ready';render();},'deny'));state.append(actions);
      }else if(status==='loading'){state.append(el('strong',c.loading),button(c.cancel,()=>{clear();render();},'cancel'));}
      else if(status==='success'&&result){const row=el('div',undefined,'road-result');row.append(el('strong',`${(result.distance/1000).toLocaleString(getLanguage?.()||'en',{maximumFractionDigits:1})} km`,'road-distance'),el('span',`${c.approx} ${Math.max(1,Math.round(result.duration/60))} ${c.minutes}`),el('span',c.provider,'road-badge'),button(c.clear,()=>{clear();render();},'clear'));const attribution=el('p',`${result.provider} · ${c.reference} · `);const fix=el('a',c.fixMap);fix.href='https://www.openstreetmap.org/fixthemap';fix.target='_blank';fix.rel='noopener noreferrer';attribution.append(fix);state.append(row,attribution);if(result.waypointDistances?.some(d=>d>200))state.append(el('p',c.snap,'road-warning'));}
      else if(status==='error'){state.append(el('strong',`${c.errors[errorCode]||c.errors.network} (${errorCode})`),button(c.fallback,()=>onFallback?.(),'fallback'));}
      else state.append(el('strong',c.ready));
      if(consent)body.append(button(c.revoke,()=>{consent=false;clear();client.clearCache?.();render();},'revoke'));
      restore();
      function restore(){
        if(!hadFocus)return;
        const previous=focus&&host.querySelector(`[data-road-focus="${focus}"]`);
        const preferred=status==='loading'?'cancel':status==='consent'?'allow':'plan';
        const fallback=host.querySelector(`[data-road-focus="${preferred}"]`);
        const target=status==='consent'&&focus==='plan'?fallback:previous&&!previous.disabled?previous:fallback&&!fallback.disabled?fallback:toggle;
        target?.focus({preventScroll:true});
      }
    }
    async function request(){
      if(disposed||!open||!consent||!usable()||status==='loading')return;
      clear();const current=token;const captured={context,start,end,mode};const a=find(start),b=find(end);status='loading';render();
      try{
        const data=await client.plan({start:{latitude:a.latitude,longitude:a.longitude},end:{latitude:b.latitude,longitude:b.longitude},mode,consent:true});
        if(disposed||token!==current||!open||context!==captured.context||start!==captured.start||end!==captured.end||mode!==captured.mode)return;
        line=L.polyline(data.geometry.coordinates.map(p=>[p[1],p[0]]),{color:'#3979ac',weight:4,opacity:1}).addTo(map);result=data;status='success';map.fitBounds(line.getBounds(),{padding:[24,24],maxZoom:16});render();
      }catch(e){if(disposed||token!==current)return;errorCode=e.code||'network';status='error';render();}
    }
    function update(){if(disposed)return;const next=getContextKey();const previousA=find(start),previousB=find(end);points=(getPoints()||[]).filter(valid).map(p=>({...p}));if(!initialized||next!==context){clear();context=next;start=String(points[0]?.id??'');end=String(points.at(-1)?.id??'');initialized=true;}else{const a=find(start),b=find(end);if(!a||!b||!previousA||!previousB||a.latitude!==previousA.latitude||a.longitude!==previousA.longitude||b.latitude!==previousB.latitude||b.longitude!==previousB.longitude){clear();if(!a)start=String(points[0]?.id??'');if(!b)end=String(points.at(-1)?.id??'');}}render();}
    function escape(e){if(!e.isComposing&&e.keyCode!==229&&e.key==='Escape'&&status==='consent'){e.preventDefault();status='ready';render();}}
    host.addEventListener('keydown',escape);update();
    return {update,dispose(){if(disposed)return;clear();disposed=true;host.removeEventListener('keydown',escape);host.replaceChildren();host.classList.remove('road-planning');}};
  }
  return {mount};
})();
