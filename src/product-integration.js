// Integrate the approved map without navigating away from this writing session.
tr('sample','片刻 · 产品预览','Moments · Product preview','Moments · Produktvorschau');
tr('samplehint','照片、回忆与行程，在同一个地方。','Photos, memories and journeys, together.','Fotos, Erinnerungen und Reisen an einem Ort.');
tr('locationpreview','地点与路线','Places & routes','Orte & Routen');
tr('productmap','地点与路线','Places & routes','Orte & Routen');
tr('mapfollow','跟随当前筛选 · 合集显示当前封面','Follows filters · Collections show the current cover','Folgt Filtern · Sammlungen zeigen das aktuelle Titelbild');
tr('samplefooter','当前预览包含 {n} 张已有素材，可试写、筛选与查看路线。','Preview with {n} photos: write memories, filter and explore routes.','Vorschau mit {n} Fotos: Erinnerungen schreiben, filtern und Routen erkunden.');
const productMapURL=__MAP_WORKSPACE_URL__;
let productMapController=null,productMapHost=null,photoObserver=null;
const visibleCards=new Set();
let mapSelectionUntil=0;
let mapNavigationKey='',mapCameraMode='overview',mapCameraRevision=0,mapPhotoIntent='',mapPhotoIntentAt=-Infinity,mapUserScrollUntil=0,mapFollowFrame=0,mapScrollInputAt=-Infinity,mapScrollSession=0,mapHandledScroll=0;
function mapNavigation(){
  const key=JSON.stringify([S.trip,S.mode,S.view,S.sort,S.type,S.location,S.sublocation,S.customLocation,S.onlyFavorites,S.from,S.to,S.search]);
  if(key!==mapNavigationKey){mapNavigationKey=key;mapCameraMode='overview';mapCameraRevision++;mapUserScrollUntil=0;mapScrollInputAt=-Infinity;mapHandledScroll=mapScrollSession;}
  return key;
}
function photoMapIntent(id,source='explicit',force=false){
  if(!byId[id])return;
  mapNavigation();const now=performance.now();
  if(source!=='scroll'){mapUserScrollUntil=0;mapScrollInputAt=-Infinity;mapHandledScroll=mapScrollSession;}
  if(!force&&mapCameraMode==='photo'&&mapPhotoIntent===id&&now-mapPhotoIntentAt<120)return;
  mapCameraMode='photo';mapCameraRevision++;mapPhotoIntent=id;mapPhotoIntentAt=now;
}
function mapPhotoSnapshot(){
  const ids=['empty','loading'].includes(S.view)?[]:[...new Set(filtered().map(cover))];
  const navigation=mapNavigation();
  let hash=2166136261;for(const ch of navigation+'|'+[...ids].sort().join(','))hash=Math.imul(hash^ch.charCodeAt(0),16777619)>>>0;
  return {language:S.lang,context:S.trip+'|'+hash.toString(16),focusedId:S.focus,camera:{mode:mapCameraMode,revision:mapCameraRevision},photos:ids.map(id=>({id,title:photoTitle(id)+' · '+place(id),date:byId[id].date||'',latitude:byId[id].geo?.latitude??null,longitude:byId[id].geo?.longitude??null}))};
}
function highlightMapPhoto(){document.querySelectorAll('.card[data-current]').forEach(card=>card.classList.toggle('is-map-focus',S.showMap&&card.dataset.current===S.focus));}
function chooseMapPhoto(id){
  const group=filtered().find(g=>g.includes(id));if(!group)return;
  mapSelectionUntil=performance.now()+900;
  S.active[group[0]]=id;S.focus=id;if(group.length>1)S.stacks.add(group[0]);
  if(S.mode!=='photos'){S.mode='photos';photoMapIntent(id);renderFrame();}else{photoMapIntent(id);renderGallery();renderMap();applyDensity();}
  const card=document.querySelector(`.card[data-current="${id}"]`);
  if(card){card.tabIndex=-1;card.focus({preventScroll:true});card.scrollIntoView({block:'center',behavior:globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches?'auto':'smooth'});}
}
renderMap=function(){
  const panel=$('map-panel');panel.hidden=!S.showMap;$('content').classList.toggle('with-map',S.showMap);panel.classList.add('product-map-panel');
  if(!productMapHost&&S.showMap){
    panel.replaceChildren();
    const header=document.createElement('header'),heading=document.createElement('h3'),close=document.createElement('button'),subtitle=document.createElement('p');
    heading.className='product-map-heading';close.dataset.action='map';close.innerHTML=icon('close');close.className='product-map-close';header.append(heading,close);subtitle.className='product-map-subtitle';
    productMapHost=document.createElement('div');productMapHost.className='product-map-host';panel.append(header,subtitle,productMapHost);
    productMapController=ProductMap.create({host:productMapHost,url:productMapURL,onSelect:chooseMapPhoto});
  }
  if(productMapHost){panel.querySelector('h3').textContent=t('productmap');panel.querySelector('.product-map-close').setAttribute('aria-label',t('nomap'));panel.querySelector('.product-map-subtitle').textContent=t('mapfollow');productMapController.sync(mapPhotoSnapshot(),S.showMap);}
  highlightMapPhoto();
};
const integratedLocations=renderLocations;
renderLocations=function(){integratedLocations();const link=$('location-shortcuts').querySelector('.location-preview');if(link){link.href='#map-panel';link.removeAttribute('target');link.removeAttribute('rel');link.setAttribute('role','button');link.setAttribute('aria-expanded',String(S.showMap));}};
function observeProductPhotos(){
  photoObserver?.disconnect();visibleCards.clear();if(typeof IntersectionObserver==='undefined')return;
  photoObserver=new IntersectionObserver(entries=>{
    for(const entry of entries)entry.isIntersecting?visibleCards.add(entry.target):visibleCards.delete(entry.target);
  },{rootMargin:'-12% 0px -45% 0px',threshold:[0,.1,.5]});
  document.querySelectorAll('.card[data-current]').forEach(card=>photoObserver.observe(card));
}
function followProductPhoto(){
  const now=performance.now();
  if(!S.showMap||$('viewer').open||now<mapSelectionUntil||mapUserScrollUntil===0||now>mapUserScrollUntil)return;
  const input=document.activeElement;
  if(input?.matches('textarea,input')){const r=input.getBoundingClientRect();if(r.bottom>0&&r.top<innerHeight)return;}
  const card=[...document.querySelectorAll('.card[data-current]')].map(el=>({el,r:el.getBoundingClientRect()})).filter(({el,r})=>el.isConnected&&r.bottom>innerHeight*.12&&r.top<innerHeight*.65).sort((a,b)=>Math.abs(a.r.top-120)-Math.abs(b.r.top-120))[0]?.el;
  const freshScroll=mapHandledScroll!==mapScrollSession;
  if(card&&(freshScroll||card.dataset.current!==S.focus||mapCameraMode!=='photo')){S.focus=card.dataset.current;photoMapIntent(S.focus,'scroll',freshScroll);mapHandledScroll=mapScrollSession;renderMap();}
}
function userPhotoScroll(e){
  if(e.target?.closest?.('#map-panel')||e.ctrlKey||e.metaKey)return;
  if(e.type==='keydown'&&(!['ArrowDown','ArrowUp','PageDown','PageUp','Home','End',' '].includes(e.key)||e.target?.matches?.('input,textarea,select,[contenteditable="true"]')))return;
  const now=performance.now();if(now-mapScrollInputAt>250)mapScrollSession++;mapScrollInputAt=now;mapUserScrollUntil=now+1600;
}
window.addEventListener('wheel',userPhotoScroll,{passive:true});window.addEventListener('touchmove',userPhotoScroll,{passive:true});window.addEventListener('keydown',userPhotoScroll);
window.addEventListener('pointerdown',e=>{if(e.clientX>=innerWidth-18)userPhotoScroll(e);},{passive:true});
window.addEventListener('scroll',()=>{if(!mapFollowFrame&&performance.now()<=mapUserScrollUntil)mapFollowFrame=requestAnimationFrame(()=>{mapFollowFrame=0;followProductPhoto();});},{passive:true});
document.addEventListener('focusin',e=>{const id=e.target?.dataset?.photo;if(id)photoMapIntent(id);},true);
const integratedGallery=renderGallery;
renderGallery=function(){integratedGallery();renderMap();observeProductPhotos();};
const integratedRedraw=redrawCard;
redrawCard=function(id){integratedRedraw(id);renderMap();observeProductPhotos();};
document.addEventListener('click',e=>{
  if(e.target.closest('[data-action="locationpreview"]')){e.preventDefault();e.stopImmediatePropagation();S.showMap=true;renderFrame();return;}
  const card=e.target.closest('.card[data-current]');if(!card||e.target.closest('.select,.favorite'))return;
  const action=e.target.closest('[data-action]')?.dataset.action?.split(':');
  const id=action?.[0]==='member'?action[2]:['viewer','place','expand','notes'].includes(action?.[0])?action[1]:card.dataset.current;
  if(!byId[id])return;S.focus=id;photoMapIntent(id);if(S.showMap)renderMap();
},true);
window.addEventListener('pagehide',e=>{photoObserver?.disconnect();if(e.persisted)productMapController?.sync(mapPhotoSnapshot(),false);else productMapController?.dispose();});
window.addEventListener('pageshow',e=>{if(e.persisted){renderMap();observeProductPhotos();}});
S.showMap=true;
