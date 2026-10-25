import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
class Node {
  constructor(tag,doc){this.tag=tag;this.doc=doc;this.children=[];this.dataset={};this.attrs={};this.listeners={};this.className='';this.disabled=false;this.value='';this.rebuilds=0;this.classList={add:c=>{this.className+=' '+c;},remove:c=>{this.className=this.className.split(' ').filter(x=>x!==c).join(' ');}};}
  append(...nodes){for(const n of nodes){n.parent=this;this.children.push(n);}}
  replaceChildren(...nodes){this.rebuilds++;this.children=[];this.append(...nodes);}
  setAttribute(k,v){this.attrs[k]=v;}
  addEventListener(k,fn){(this.listeners[k]??=[]).push(fn);}
  removeEventListener(k,fn){this.listeners[k]=(this.listeners[k]||[]).filter(x=>x!==fn);}
  contains(n){return n===this||this.children.some(c=>c.contains(n));}
  querySelector(selector){const match=n=>selector.startsWith('.')?n.className.split(' ').includes(selector.slice(1)):n.dataset.roadFocus===selector.match(/"([^"]+)"/)?.[1];for(const n of this.children){if(match(n))return n;const nested=n.querySelector(selector);if(nested)return nested;}return null;}
  focus(){if(!this.disabled)this.doc.activeElement=this;}
  fire(kind,event={}){if(this.disabled)return;for(const fn of this.listeners[kind]||[])fn(event);}
}
const document={activeElement:null,createElement(tag){return new Node(tag,this);},createTextNode(text){const n=new Node('#text',this);n.textContent=text;return n;}};
const sandbox={document,console,matchMedia:()=>({matches:true})};
vm.createContext(sandbox);vm.runInContext(fs.readFileSync(new URL('../src/road-panel.js',import.meta.url),'utf8')+'\nglobalThis.Panel=RoadPanel;',sandbox);
const tick=async()=>{await Promise.resolve();await Promise.resolve();};
const plain=x=>JSON.parse(JSON.stringify(x));
const geometry={geometry:{coordinates:[[1,2],[3,4]]},distance:1000,duration:120,waypointDistances:[0,0],provider:'Synthetic / OSRM'};
function fixture(initial=[{id:'synthetic-a',title:'Synthetic A',latitude:2,longitude:1},{id:'synthetic-b',title:'Synthetic B',latitude:4,longitude:3},{id:'synthetic-c',title:'Synthetic C',latitude:6,longitude:5}]){
  let points=initial,context='synthetic-context-a',language='en',fallbacks=0;
  const host=new Node('host',document),calls=[],pending=[];
  const client={cancels:0,clears:0,cancel(){this.cancels++;},clearCache(){this.clears++;},plan(args){calls.push(plain(args));return new Promise((resolve,reject)=>pending.push({resolve,reject}));}};
  const map={adds:0,removes:0,fits:0,removeLayer(){this.removes++;},fitBounds(){this.fits++;}};
  const L={polyline(coords,opts){assert.deepEqual(plain(coords),[[2,1],[4,3]]);assert.equal(opts.weight,4);return {addTo(){map.adds++;return this;},getBounds(){return 'synthetic-bounds';}};}};
  const ui=sandbox.Panel.mount({host,map,L,client,getPoints:()=>points,getContextKey:()=>context,getLanguage:()=>language,onFallback:()=>fallbacks++});
  const control=key=>{const n=host.querySelector(`[data-road-focus="${key}"]`);assert.ok(n,`Missing ${key}`);return n;};
  const click=key=>control(key).fire('click');
  const select=(key,value)=>{const n=control(key);n.value=value;n.fire('change');};
  return {host,client,map,calls,pending,ui,control,click,select,setPoints:p=>{points=p;},setContext:c=>{context=c;},setLanguage:l=>{language=l;}};
}
{
  const f=fixture();assert.equal(f.calls.length,0);f.ui.update();assert.equal(f.calls.length,0);
  f.click('toggle');f.click('plan');assert.equal(f.calls.length,0);assert.ok(f.control('allow'));
  f.click('deny');assert.equal(f.calls.length,0);f.click('plan');f.click('allow');assert.equal(f.calls.length,1);
  assert.deepEqual(f.calls[0],{start:{latitude:2,longitude:1},end:{latitude:6,longitude:5},mode:'car',consent:true});
  assert.ok(!JSON.stringify(f.calls[0]).includes('synthetic'));
  const before=f.client.cancels;f.select('end','synthetic-b');assert.ok(f.client.cancels>before);
  f.pending[0].resolve(geometry);await tick();assert.equal(f.map.adds,0,'stale selection response ignored');
  f.click('plan');assert.equal(f.calls.length,2);f.pending[1].resolve(geometry);await tick();assert.equal(f.map.adds,1);assert.equal(f.map.fits,1);
  const rebuilds=f.host.rebuilds;f.ui.update();assert.equal(f.host.rebuilds,rebuilds,'identical photo update preserves DOM');assert.equal(f.map.fits,1);
  f.control('end').focus();f.setLanguage('de');f.ui.update();assert.equal(f.map.adds,1);assert.equal(f.map.fits,1);assert.equal(document.activeElement.dataset.roadFocus,'end');assert.equal(f.control('end').value,'synthetic-b');
  f.select('start','synthetic-c');assert.equal(f.map.removes,1,'endpoint change removes route');
  f.click('plan');f.setContext('synthetic-context-b');f.ui.update();f.pending[2].resolve(geometry);await tick();assert.equal(f.map.adds,1,'stale context response ignored');assert.equal(f.control('start').value,'synthetic-a');assert.equal(f.control('end').value,'synthetic-c');
  f.click('plan');f.pending[3].resolve(geometry);await tick();assert.equal(f.map.adds,2);f.setContext('synthetic-context-c');f.ui.update();assert.equal(f.map.removes,2,'context removes successful route');
  f.click('revoke');assert.equal(f.client.clears,1);f.click('plan');assert.equal(f.calls.length,4,'revoked consent cannot send');f.click('allow');assert.equal(f.calls.length,5);
  const cancels=f.client.cancels;f.click('toggle');assert.ok(f.client.cancels>cancels);f.pending[4].resolve(geometry);await tick();assert.equal(f.map.adds,2,'closed route remains absent');
  f.ui.dispose();const disposedRebuilds=f.host.rebuilds;f.ui.update();assert.equal(f.host.rebuilds,disposedRebuilds);
}

{
  const f=fixture();f.click('toggle');
  f.control('plan').focus();f.click('plan');assert.equal(document.activeElement.dataset.roadFocus,'allow','consent entry focuses Allow');
  f.click('allow');assert.equal(document.activeElement.dataset.roadFocus,'cancel','Allow transition focuses enabled Cancel');
  const outside=new Node('outside',document);outside.focus();f.pending[0].resolve(geometry);await tick();assert.equal(document.activeElement,outside,'async success never steals external focus');
  f.control('clear').focus();f.click('clear');assert.equal(document.activeElement.dataset.roadFocus,'plan','Clear falls back to Plan');
  f.control('plan').focus();f.click('plan');assert.equal(document.activeElement.dataset.roadFocus,'cancel','disabled Plan falls back to Cancel');
  f.click('cancel');assert.equal(document.activeElement.dataset.roadFocus,'plan','Cancel falls back to Plan');
  f.control('revoke').focus();f.click('revoke');assert.equal(document.activeElement.dataset.roadFocus,'plan','Revoke falls back to Plan');
  f.control('plan').focus();f.setPoints([]);f.ui.update();assert.equal(document.activeElement.dataset.roadFocus,'toggle','disabled Plan falls back to toggle');
  f.ui.dispose();
}

for(const points of [[],[{id:'synthetic-a',latitude:1,longitude:1}],[{id:'synthetic-a',latitude:1,longitude:1},{id:'synthetic-b',latitude:1,longitude:1}],[{id:'synthetic-a',latitude:91,longitude:1},{id:'synthetic-b',latitude:2,longitude:2}],[{id:'synthetic-a',latitude:NaN,longitude:1},{id:'synthetic-b',latitude:2,longitude:2}],[{id:'synthetic-a',latitude:1,longitude:181},{id:'synthetic-b',latitude:2,longitude:2}]]){
  const f=fixture(points);f.click('toggle');assert.equal(f.control('plan').disabled,true);f.click('plan');assert.equal(f.calls.length,0);f.ui.dispose();
}
console.log('RoadPanel fake-DOM checks passed: consent, cancellation, stale results, rendering, privacy, invalid points.');
