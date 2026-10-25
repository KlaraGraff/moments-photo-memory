import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const plain=x=>JSON.parse(JSON.stringify(x));
class Node {
  constructor(tag){this.tag=tag;this.children=[];this.style={};this.listeners={};this.hidden=false;this.posts=[];this.contentWindow={postMessage:(message,origin)=>this.posts.push({message:plain(message),origin})};}
  append(...nodes){nodes.forEach(n=>{n.parent=this;this.children.push(n);});}
  prepend(n){n.parent=this;this.children.unshift(n);}
  remove(){if(this.parent)this.parent.children=this.parent.children.filter(n=>n!==this);}
  setAttribute(){}
  addEventListener(k,fn){this.listeners[k]=fn;}
}
const handlers=new Map(),timers=new Map();let serial=0,random=0;
const document={createElement:tag=>new Node(tag)};
const window={addEventListener:(k,fn)=>handlers.set(k,fn),removeEventListener:(k,fn)=>{if(handlers.get(k)===fn)handlers.delete(k);}};
const context=vm.createContext({document,window,URL,URLSearchParams,Uint8Array,location:{href:'file:///synthetic/product.html',origin:'null'},crypto:{getRandomValues(a){a.fill(++random);}},setTimeout:fn=>{timers.set(++serial,fn);return serial;},clearTimeout:id=>timers.delete(id)});
vm.runInContext(fs.readFileSync(new URL('../src/product-map.js',import.meta.url),'utf8')+'\nglobalThis.model=ProductMap;',context);
const P=context.model,host=new Node('host'),selected=[];
const input={language:'zh',context:'demo',focusedId:'a',photos:[{id:'a',title:'A',date:'2000:01:02 12:00:00',latitude:0,longitude:0,dataURI:'must-not-cross',memory:'private text'},{id:'b',title:'B',date:'',latitude:null,longitude:null}]};
const snapshot=P.snapshot(input);assert.deepEqual(Object.keys(snapshot.photos[0]),['id','title','date','latitude','longitude']);assert.equal(snapshot.photos[0].latitude,0);assert.equal(snapshot.photos[1].latitude,null);assert(!JSON.stringify(snapshot).includes('private text'));assert.equal(P.snapshot({...input,context:'x'.repeat(1000)}).context.length,500);
assert.deepEqual(plain(snapshot.camera),{mode:'overview',revision:0});
assert.deepEqual(plain(P.snapshot({...input,camera:{mode:'photo',revision:3}}).camera),{mode:'photo',revision:3});
assert.deepEqual(plain(P.snapshot({...input,camera:{mode:'invalid',revision:NaN}}).camera),{mode:'overview',revision:0});
const ui=P.create({host,url:'http://127.0.0.1:8766/workspace-map',onSelect:id=>selected.push(id)});
ui.sync(input,false);assert.equal(host.children.filter(n=>n.tag==='iframe').length,0);
ui.sync(input,true);let frame=host.children.find(n=>n.tag==='iframe');assert(frame);assert(!frame.src.includes('private'));assert.equal(host.children.filter(n=>n.tag==='iframe').length,1);
const channel=()=>new URLSearchParams(new URL(frame.src).hash.slice(1)).get('channel');
const message=(type,payload={},extra={})=>handlers.get('message')({source:frame.contentWindow,origin:'http://127.0.0.1:8766',data:{protocol:'moments-map-v1',channel:channel(),type,payload},...extra});
message('ready',{}, {origin:'https://untrusted.invalid'});assert(!ui.ready);
message('ready',{}, {source:{}});assert(!ui.ready);
message('ready',{}, {data:{protocol:'moments-map-v1',channel:'wrong',type:'ready'}});assert(!ui.ready);
message('ready');assert(ui.ready);assert.equal(timers.size,0);assert.deepEqual(frame.posts.map(p=>p.message.type),['visibility','state']);assert(frame.posts.every(p=>p.origin==='http://127.0.0.1:8766'));
const before=frame.posts.length;ui.sync(input,true);assert.equal(frame.posts.length,before,'identical writes do not post/reload map');assert.equal(host.children.filter(n=>n.tag==='iframe').length,1);
message('select',{id:'missing'});message('select',{id:'a'});assert.deepEqual(selected,['a']);
message('size',{height:2000});assert.equal(frame.style.height,'1600px');message('size',{height:NaN});assert.equal(frame.style.height,'1600px');
ui.sync({...input,language:'de'},true);assert.equal(frame.posts.at(-1).message.type,'state');assert.equal(frame.posts.at(-1).message.payload.language,'de');
ui.sync(input,false);assert.equal(frame.posts.at(-2).message.type,'visibility');assert.equal(frame.posts.at(-2).message.payload.visible,false);ui.sync(input,true);assert.equal(frame.posts.at(-1).message.type,'visibility');
const old=frame;host.children.find(n=>n.tag==='button').listeners.click();frame=host.children.find(n=>n.tag==='iframe');assert.notEqual(frame,old);assert.notEqual(channel(),new URLSearchParams(new URL(old.src).hash.slice(1)).get('channel'));message('ready',{}, {source:old.contentWindow});assert(!ui.ready);message('ready');assert(ui.ready);
ui.dispose();ui.dispose();assert.equal(handlers.size,0);assert.equal(timers.size,0);assert.equal(host.children.length,0);
assert.throws(()=>P.create({host,url:'https://untrusted.invalid/map'}));
// Run only the integration adapter against synthetic stubs, never a private page.
const S={view:'gallery',trip:'demo',lang:'zh',focus:'a',active:{},stacks:new Set(),showMap:false,mode:'photos'};
let groups=[['a','hidden-b']],galleryCalls=0,scrolls=0;
let bridgeClock=1000,ioCallback=null;
const card={dataset:{current:'a'},isConnected:true,getBoundingClientRect:()=>({top:120,bottom:450}),focus(){},scrollIntoView(){scrolls++;}},integrationHandlers={},windowHandlers={};
const bridge=vm.createContext({S,tr(){},innerHeight:800,innerWidth:1200,IntersectionObserver:class{constructor(fn){ioCallback=fn;}disconnect(){}observe(){}},performance:{now:()=>bridgeClock},byId:{a:{date:'2000:01:02 12:00:00',geo:{latitude:0,longitude:0}},'hidden-b':{date:'',geo:null}},filtered:()=>groups,cover:g=>S.active[g[0]]||g[0],photoTitle:id=>id,place:()=>'',renderLocations(){},renderGallery(){galleryCalls++;},renderFrame(){},renderMap(){},redrawCard(){},applyDensity(){},document:{activeElement:null,addEventListener(k,fn){integrationHandlers[k]=fn;},querySelector:()=>card,querySelectorAll:()=>[card]},$:()=>({open:false}),window:{addEventListener(k,fn){windowHandlers[k]=fn;}},matchMedia:()=>({matches:true})});
const integration=fs.readFileSync(new URL('../src/product-integration.js',import.meta.url),'utf8').replace('__MAP_WORKSPACE_URL__',JSON.stringify('http://127.0.0.1:8766/workspace-map'));
vm.runInContext(integration+'\nglobalThis.getSnapshot=mapPhotoSnapshot;globalThis.selectPhoto=chooseMapPhoto;globalThis.cameraTest={photoMapIntent,observeProductPhotos,followProductPhoto,userPhotoScroll};',bridge);
assert.deepEqual(plain(bridge.getSnapshot().photos).map(p=>p.id),['a'],'map shows displayed covers, not filtered-out stack members');
assert.equal(bridge.getSnapshot().photos[0].latitude,0);bridge.renderMap=()=>{};
assert.equal(bridge.getSnapshot().camera.mode,'overview');
bridge.cameraTest.observeProductPhotos();ioCallback([{target:card,isIntersecting:true}]);assert.equal(bridge.getSnapshot().camera.mode,'overview','initial observer delivery must preserve overview');
bridge.cameraTest.userPhotoScroll({type:'wheel'});bridge.cameraTest.followProductPhoto();assert.equal(bridge.getSnapshot().camera.mode,'photo','first real scroll zooms even the initially focused photo');
const photoRevision=bridge.getSnapshot().camera.revision;assert.equal(bridge.getSnapshot().camera.revision,photoRevision,'unchanged inputs do not request another camera move');
S.type='people';const category=bridge.getSnapshot();assert.equal(category.camera.mode,'overview');assert(category.camera.revision>photoRevision);ioCallback([{target:card,isIntersecting:true}]);assert.equal(bridge.getSnapshot().camera.mode,'overview','layout observer delivery after category change must preserve overview');
bridge.cameraTest.photoMapIntent('a');const firstClick=bridge.getSnapshot().camera.revision;bridge.cameraTest.photoMapIntent('a');assert.equal(bridge.getSnapshot().camera.revision,firstClick,'focus plus click coalesces');bridgeClock+=200;bridge.cameraTest.photoMapIntent('a');assert(bridge.getSnapshot().camera.revision>firstClick,'same photo can be recentered later');
const enSnapshot=bridge.getSnapshot();S.lang='de';assert.equal(bridge.getSnapshot().camera.revision,enSnapshot.camera.revision,'language change preserves camera intent');
bridgeClock+=2000;bridge.cameraTest.userPhotoScroll({type:'wheel'});bridge.cameraTest.followProductPhoto();assert(bridge.getSnapshot().camera.revision>enSnapshot.camera.revision,'new scroll session re-focuses same photo after child overview or manual pan');
bridge.cameraTest.userPhotoScroll({type:'wheel'});S.focus='hidden-b';bridge.cameraTest.photoMapIntent('hidden-b');ioCallback([{target:card,isIntersecting:true}]);bridge.cameraTest.followProductPhoto();assert.equal(S.focus,'hidden-b','explicit photo input clears residual scroll so layout cannot override it');
bridge.selectPhoto('a');assert.equal(S.focus,'a');assert.equal(scrolls,1);assert.equal(galleryCalls,1);assert.equal(bridge.getSnapshot().camera.mode,'photo');
groups=[];assert.equal(bridge.getSnapshot().photos.length,0);bridge.selectPhoto('missing');assert.equal(scrolls,1);
groups=Array.from({length:10000},(_,i)=>['z'+i]);for(const g of groups)bridge.byId[g[0]]={date:'',geo:null};assert(bridge.getSnapshot().context.length<100,'large collections use a short stable context');
console.log('Product map synthetic checks passed: exact bridge boundaries, stable frame, local notes origin, filters/covers and selection.');
