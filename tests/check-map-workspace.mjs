import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source=fs.readFileSync(new URL('../src/map-workspace.js',import.meta.url),'utf8');
const context=vm.createContext({});vm.runInContext(source+'\nglobalThis.model=MapWorkspaceModel;',context);const m=context.model;
const row={id:'a',title:'<script>safe text</script>',date:'2024-02-01',latitude:0,longitude:0};
const state={language:'en',context:'filter',focusedId:'a',photos:[row,{...row,id:'b',date:'2023-01-01',latitude:null,longitude:null}]};
const clean=m.state(state);assert(clean);assert(Object.isFrozen(clean.photos[0]));assert.equal(clean.photos[0].latitude,0);assert.equal(clean.photos[1].latitude,null);row.latitude=10;assert.equal(clean.photos[0].latitude,0);
assert.equal(m.state({...state,photos:[{...row,latitude:91}]}),null);assert.equal(m.state({...state,photos:[row,row]}),null);assert.equal(m.state({...state,focusedId:'missing'}),null);assert.equal(m.state({...state,language:'xx'}),null);assert.equal(m.state({...state,photos:Array(10001).fill(row)}),null);
const parent={},channel='a'.repeat(32),envelope={protocol:'moments-map-v1',channel,type:'state',payload:state};
const event={source:parent,origin:'null',data:envelope};assert(m.message(event,parent,'https://local',channel));assert.equal(m.message({...event,source:{}},parent,'https://local',channel),null);assert.equal(m.message({...event,origin:'https://evil'},parent,'https://local',channel),null);assert.equal(m.message(event,parent,'https://local','b'.repeat(32)),null);assert.equal(m.message(event,parent,'https://local',null),null);
assert(m.message({...event,data:{...envelope,type:'visibility',payload:{visible:false}}},parent,'https://local',channel));assert.equal(m.message({...event,data:{...envelope,type:'visibility',payload:{visible:'false'}}},parent,'https://local',channel),null);
const ordered=m.chronological([{...row,id:'late',date:'2025-01-01'},{...row,id:'early',date:'2022-01-01'},{...row,id:'none',latitude:null}]);assert.deepEqual(Array.from(ordered,p=>p.id),['early','late']);
assert.equal(m.signature(clean),m.signature({...clean,language:'de',focusedId:null,photos:[...clean.photos].reverse()}));assert.notEqual(m.signature(clean),m.signature({...clean,context:'other'}));
const html=fs.readFileSync(new URL('../src/map-workspace.html',import.meta.url),'utf8');for(const marker of ['__LEAFLET_JS__','__LEAFLET_CSS__','__MAP_WHEEL_JS__','__ROAD_ROUTING_JS__','__ROAD_PANEL_JS__','__ROAD_PANEL_CSS__','__WORKSPACE_JS__','__WORKSPACE_CSS__'])assert(html.includes(marker));
assert(source.indexOf('map.setView([0,0],2)')<source.indexOf('MapWheel.create(map'));
// Startup without a bridge channel must not touch Leaflet, send data or create network requests.
let outbound=0;
vm.runInNewContext(source,{document:{getElementById(){throw new Error('unexpected DOM access');}},location:{hash:'',protocol:'https:',origin:'https://local'},URLSearchParams,window:{parent:{postMessage(){outbound++;}}}});
assert.equal(outbound,0);
// A file-loaded frame sends only ready/size, then explains the supported local entry.
const opening={textContent:''},posts=[];
vm.runInNewContext(source,{document:{getElementById(id){assert.equal(id,'opening');return opening;},body:{getBoundingClientRect:()=>({height:42})}},location:{hash:'#channel='+channel,protocol:'file:',origin:'null'},URLSearchParams,window:{parent:{postMessage:e=>posts.push(e)},addEventListener(){}}});
assert(opening.textContent.includes('local entry'));
assert.deepEqual(posts.map(p=>p.type),['ready','size']);
assert(posts.every(p=>!('photos' in p.payload)&&!('latitude' in p.payload)));
console.log('Embedded map offline validation passed');
assert.equal(m.timestamp('2025:02:29 12:00:00'),null);assert.equal(m.timestamp('2024:02:29 12:00:00'),Date.UTC(2024,1,29,12));assert.equal(m.timestamp('not a date'),null);
assert.deepEqual(Array.from(m.chronological([{...row,id:'later',date:'2024:07:10 10:20:30'},{...row,id:'earlier',date:'2024:01:09 05:03:02'},{...row,id:'undated',date:''},{...row,id:'bad',date:'2024:19:01 00:00:00'}]),p=>p.id),['earlier','later']);
// Exercise component lifecycle without Leaflet, HTTP or a browser. Fakes record public API calls.
let nodeConstructions=0,iconConstructions=0,popupBindings=0,panelUpdates=0,lineConstructions=0;
class Node{constructor(){nodeConstructions++;this.children=[];this.attrs={};this.classList={add(){},remove(){}};this.checked=false;}append(...children){this.children.push(...children);}replaceChildren(...children){this.children=children;}setAttribute(k,v){this.attrs[k]=v;}querySelector(){return null;}getBoundingClientRect(){return{height:430};}}
const nodes=new Map(),listeners={},calls={maps:0,tiles:0,fit:0,pan:0,mount:0,dispose:0,cancel:0,removed:0,wheelDisposed:0,invalidated:0},mockMarkers=[];
const doc={getElementById:id=>{if(!nodes.has(id))nodes.set(id,new Node());return nodes.get(id);},createElement:()=>new Node(),createTextNode:x=>x,body:new Node(),documentElement:{}};
let reducedMotion=true;let inBounds=true,mapCenter={lat:0,lng:0},mapZoom=2;const cameraCommands=[];const map={getCenter:()=>mapCenter,getZoom:()=>mapZoom,_stop(){calls.stopped=(calls.stopped||0)+1;},_onZoomTransitionEnd(){calls.zoomCompleted=(calls.zoomCompleted||0)+1;this._animatingZoom=false;if(this.pendingCenter){mapCenter=this.pendingCenter;mapZoom=this.pendingZoom;this.pendingCenter=null;}},stop(){calls.publicStops=(calls.publicStops||0)+1;},setView(center,zoom,options){mapCenter={lat:center[0],lng:center[1]};mapZoom=zoom;cameraCommands.push({center,zoom,options});return this;},fitBounds(){calls.fit++;},panTo(){calls.pan++;},getBounds:()=>({contains:()=>inBounds}),removeLayer(){},invalidateSize(){calls.invalidated++;},remove(){calls.removed++;},scrollWheelZoom:{enable(){},disable(){}}};
const fakeL={map(id,options){calls.maps++;assert.equal(options.zoomSnap,0);assert.equal(options.zoomAnimation,false);return map;},control:{zoom:()=>({addTo(){}})},tileLayer(url,opts){calls.tiles++;assert.equal(opts.keepBuffer,3);return{on(){return this;},addTo(){return this;},redraw(){},isLoading:()=>false};},divIcon:x=>{iconConstructions++;return x;},marker(coords,options){const marker={coords,options,events:{},element:new Node(),addTo(){return this;},setIcon(){},off(type){delete this.events[type];},on(type,fn){this.events[type]=fn;},unbindPopup(){this.popup=null;},bindPopup(n){popupBindings++;this.popup=n;},getElement(){return this.element;}};mockMarkers.push(marker);return marker;},polyline:()=>{lineConstructions++;return{addTo(){return this;}};}};
const parentWindow={postMessage:e=>posts.push(e)};
vm.runInNewContext(source,{document:doc,location:{hash:'#channel='+channel,protocol:'https:',origin:'https://local'},URLSearchParams,window:{parent:parentWindow,addEventListener:(type,fn)=>listeners[type]=fn,removeEventListener:(type)=>delete listeners[type]},L:fakeL,MapWheel:{create:()=>({reversed:false,available:true,persistent:true,setReversed(){},dispose(){calls.wheelDisposed++;}})},RoadRouting:{create:()=>({cancel(){calls.cancel++;},clearCache(){}})},RoadPanel:{mount(){calls.mount++;return{update(){panelUpdates++;},dispose(){calls.dispose++;}}}},matchMedia:()=>({matches:reducedMotion}),setTimeout:()=>1,clearTimeout(){}});
const deliver=(type,payload)=>listeners.message({source:parentWindow,origin:'null',data:{protocol:'moments-map-v1',channel,type,payload}});
const sample={language:'en',context:'china',focusedId:'a',photos:[{id:'a',title:'Place A',date:'2024:01:02 10:00:00',latitude:30,longitude:110},{id:'b',title:'Place B',date:'2024:01:03 10:00:00',latitude:31,longitude:111}]};
deliver('visibility',{visible:false});deliver('state',sample);assert.equal(calls.maps,0);assert.equal(calls.tiles,0);
deliver('visibility',{visible:true});assert.equal(calls.maps,1);assert.equal(calls.tiles,1);assert.equal(calls.fit,1);mockMarkers[0].events.click();assert.equal(posts.at(-1).type,'select');assert.equal(posts.at(-1).payload.id,'a');assert.equal(mockMarkers[0].element.attrs['aria-label'],'Place A');
deliver('state',{...sample,language:'de'});assert.equal(calls.fit,1);assert.equal(calls.pan,0);
deliver('state',{...sample,focusedId:'b'});assert.equal(calls.pan,0);inBounds=false;deliver('state',sample);assert.equal(calls.pan,0);assert.equal(calls.fit,1);
deliver('state',{...sample,context:'morocco',photos:sample.photos.map(p=>({...p,latitude:35,longitude:-6}))});assert.equal(calls.fit,2);assert.equal(calls.maps,1);assert.equal(calls.tiles,1);assert(mockMarkers.at(-1).popup);assert.equal(mockMarkers.at(-1).popup.children.length,2);
deliver('visibility',{visible:false});assert.equal(calls.dispose,1);deliver('visibility',{visible:true});assert.equal(calls.mount,2);assert.equal(calls.fit,2);assert.equal(calls.maps,1);
listeners.pagehide({persisted:true});assert.equal(calls.removed,0);assert.equal(calls.dispose,2);
// Parent visibility before the child's pageshow must not recreate or resume the panel early.
deliver('visibility',{visible:true});assert.equal(calls.mount,2);listeners.pageshow({persisted:true});assert.equal(calls.mount,3);assert.equal(calls.maps,1);assert.equal(calls.tiles,1);assert.equal(calls.fit,2);
// A preserved hidden frame remains paused after BFCache restoration until its parent shows it.
deliver('visibility',{visible:false});listeners.pagehide({persisted:true});listeners.pageshow({persisted:true});assert.equal(calls.mount,3);deliver('visibility',{visible:true});assert.equal(calls.mount,4);assert.equal(calls.maps,1);
const thousand={language:'en',context:'synthetic-thousand',focusedId:'bulk-0',photos:Array.from({length:1000},(_,i)=>({id:`bulk-${i}`,title:`Place ${i}`,date:'2024:01:02 10:00:00',latitude:20+i/10000,longitude:30+i/10000}))};
deliver('state',thousand);const stationBefore=[...nodes.get('stations').children],markerCount=mockMarkers.length,nodeCount=nodeConstructions,iconCount=iconConstructions,popups=popupBindings,updates=panelUpdates,lines=lineConstructions,fits=calls.fit;
deliver('state',{...thousand,focusedId:'bulk-999'});
assert.equal(mockMarkers.length,markerCount);assert.equal(nodeConstructions,nodeCount);assert.equal(iconConstructions-iconCount,2);assert.equal(popupBindings,popups);assert.equal(panelUpdates,updates);assert.equal(lineConstructions,lines);assert.equal(calls.fit,fits);assert.deepEqual(nodes.get('stations').children,stationBefore);assert.equal(stationBefore[0].attrs['aria-pressed'],'false');assert.equal(stationBefore[999].attrs['aria-pressed'],'true');
const langIcons=iconConstructions;deliver('state',{...thousand,focusedId:'bulk-999',language:'de'});assert.equal(iconConstructions,langIcons);assert.equal(nodeConstructions,nodeCount);assert.equal(popupBindings,popups);assert.equal(calls.fit,fits);
// Camera intent is separate from marker rendering and routing, and retains exact GPS.
assert.equal(clean.camera.mode,'overview');assert.equal(clean.camera.revision,0);
for(const camera of [{mode:'bad',revision:0},{mode:'photo',revision:-1},{mode:'photo',revision:1.5},null])assert.equal(m.state({...state,camera}),null);
const exact={latitude:30.123456789,longitude:110.987654321};const exactPlan=m.cameraPlan(exact,{lat:30,lng:110},19);assert.equal(exactPlan.center[0],exact.latitude);assert.equal(exactPlan.center[1],exact.longitude);assert.equal(exactPlan.zoom,17);assert.equal(m.cameraPlan({latitude:null,longitude:null},{lat:0,lng:0},2),null);
const cameraState={...sample,context:'camera-tests',camera:{mode:'overview',revision:0},photos:[...sample.photos,{...sample.photos[0],id:'no-gps',latitude:null,longitude:null}]};
deliver('state',cameraState);const overviewFits=calls.fit,overviewCommands=cameraCommands.length;
mapCenter={lat:30,lng:110};mapZoom=5;
deliver('state',{...cameraState,camera:{mode:'photo',revision:1}});
assert.equal(calls.fit,overviewFits);assert.equal(mapZoom,17);assert.deepEqual({...mapCenter},{lat:30,lng:110});assert.equal(cameraCommands.length,overviewCommands+1);
const afterPhoto=cameraCommands.length;
deliver('state',{...cameraState,language:'de',camera:{mode:'photo',revision:1}});assert.equal(cameraCommands.length,afterPhoto);
// Preserve a deliberately closer local scale, but reset a distant-city jump to local scale.
mapCenter={lat:30.0001,lng:110.0001};mapZoom=19;
deliver('state',{...cameraState,camera:{mode:'photo',revision:2}});assert.equal(mapZoom,19);assert.equal(mapCenter.lat,30);
deliver('state',{...cameraState,focusedId:'b',camera:{mode:'photo',revision:3}});assert.equal(mapZoom,17);assert.equal(mapCenter.lat,31);assert.equal(cameraCommands.at(-1).options.animate,false);
// Repeated click on the same id recenters after manual panning.
mapCenter={lat:32,lng:112};deliver('state',{...cameraState,focusedId:'b',camera:{mode:'photo',revision:4}});assert.equal(mapCenter.lat,31);
const noGpsCommands=cameraCommands.length;deliver('state',{...cameraState,focusedId:'no-gps',camera:{mode:'photo',revision:5}});assert.equal(cameraCommands.length,noGpsCommands);assert(nodes.get('focus-status').textContent.includes('GPS'));
// Explicit overview remains until a new user camera revision; metadata and language do not override it.
nodes.get('fit').onclick();const showAllFits=calls.fit,showAllCommands=cameraCommands.length;
deliver('state',{...cameraState,language:'de',focusedId:'a',camera:{mode:'photo',revision:5}});assert.equal(cameraCommands.length,showAllCommands);assert.equal(calls.fit,showAllFits);
mapCenter={lat:0,lng:0};mapZoom=4;nodes.get('locate').onclick();assert.equal(mapZoom,17);assert.equal(mapCenter.lat,30);
deliver('state',{...cameraState,context:'group-reset',camera:{mode:'overview',revision:6}});assert.equal(calls.fit,showAllFits+1);
// Hidden rapid targets coalesce to the latest photo, applied once on reveal.
deliver('visibility',{visible:false});const hiddenCommands=cameraCommands.length;
deliver('state',{...cameraState,context:'group-reset',camera:{mode:'photo',revision:7}});
deliver('state',{...cameraState,context:'group-reset',focusedId:'b',camera:{mode:'photo',revision:8}});
assert.equal(cameraCommands.length,hiddenCommands);deliver('visibility',{visible:true});assert.equal(cameraCommands.length,hiddenCommands+1);assert.equal(mapCenter.lat,31);
assert(calls.stopped>=cameraCommands.length-1);assert.equal(calls.publicStops||0,0);assert.equal(calls.pan,0);
// Already centered nearby photo updates do not rewind camera or route state.
const settled=cameraCommands.length,routeUpdates=panelUpdates;
deliver('state',{...cameraState,context:'group-reset',focusedId:'b',camera:{mode:'photo',revision:9}});assert.equal(cameraCommands.length,settled);assert.equal(panelUpdates,routeUpdates);
// Membership can change the context while retaining an explicit photo intent.
mapCenter={lat:0,lng:0};mapZoom=3;map._animatingZoom=true;
const contextFits=calls.fit;
deliver('state',{...cameraState,context:'membership-selected',photos:[cameraState.photos[1]],focusedId:'b',camera:{mode:'photo',revision:9}});
assert.equal(calls.fit,contextFits);assert.equal(mapCenter.lat,31);assert.equal(mapZoom,17);assert.equal(calls.zoomCompleted,1);assert.equal(calls.publicStops||0,0);
// A transient missing focus does not consume the same-revision photo intent.
deliver('state',{...cameraState,context:'transient-selection',focusedId:null,camera:{mode:'photo',revision:10}});
mapCenter={lat:0,lng:0};mapZoom=3;
deliver('state',{...cameraState,context:'transient-selection',focusedId:'a',camera:{mode:'photo',revision:10}});assert.equal(mapCenter.lat,30);assert.equal(mapZoom,17);
// Reported A is not settled A while an older CSS zoom is still targeting B.
mapCenter={lat:30,lng:110};mapZoom=17;map._animatingZoom=true;map.pendingCenter={lat:31,lng:111};map.pendingZoom=17;
const beforeRace=cameraCommands.length;
deliver('state',{...cameraState,context:'transient-selection',focusedId:'a',camera:{mode:'photo',revision:11}});
assert.equal(cameraCommands.length,beforeRace+1);assert.equal(mapCenter.lat,30);assert.equal(mapCenter.lng,110);assert.equal(calls.zoomCompleted,2);
// Programmatic zoom never queues CSS zoom RAF; a local same-scale pan stays smooth.
reducedMotion=false;mapCenter={lat:30.0001,lng:110.0001};mapZoom=16;
deliver('state',{...cameraState,context:'transient-selection',camera:{mode:'photo',revision:12}});assert.equal(cameraCommands.at(-1).options.animate,false);assert.equal(mapZoom,17);
mapCenter={lat:30.0001,lng:110.0001};
deliver('state',{...cameraState,context:'transient-selection',camera:{mode:'photo',revision:13}});assert.equal(cameraCommands.at(-1).options.animate,true);assert.equal(cameraCommands.at(-1).options.duration,0.25);assert.equal(calls.publicStops||0,0);
listeners.pagehide({persisted:false});assert.equal(calls.removed,1);assert.equal(calls.wheelDisposed,1);assert.equal(calls.dispose,5);assert(!listeners.message);
console.log('Embedded map fake DOM/Leaflet lifecycle passed');
