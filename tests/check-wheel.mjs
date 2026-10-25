import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
let clock=0, serial=0, reduced=false;
const frames=new Map(), timers=new Map();
const context=vm.createContext({L:{version:'1.9.4',Browser:{any3d:true}},performance:{now:()=>clock},requestAnimationFrame:fn=>{frames.set(++serial,fn);return serial;},cancelAnimationFrame:id=>frames.delete(id),clearTimeout:id=>timers.delete(id),matchMedia:()=>({matches:reduced})});
vm.runInContext(fs.readFileSync(new URL('../src/map-wheel.js',import.meta.url),'utf8')+'\nglobalThis.wheel=MapWheel;',context);
const W=context.wheel;
function surface(){const listeners=new Map();return {listeners,classList:{add(){},remove(){}},addEventListener(k,fn){assert.ok(!listeners.has(k));listeners.set(k,fn);},removeEventListener(k,fn){if(listeners.get(k)===fn)listeners.delete(k);}};}
function fake(){
 const container=surface(),doc=surface(),events=new Map(),calls=[];container.ownerDocument=doc;
 const m={options:{zoomSnap:0},z:5,center:{x:0,y:0},calls,container,events,
 getContainer:()=>container,getZoom(){return this.z;},getCenter(){return this.center;},getSize:()=>({x:800,y:600}),
 project:(p,z)=>({x:p.x*2**z,y:p.y*2**z}),unproject:(p,z)=>({x:p.x/2**z,y:p.y/2**z}),
 mouseEventToContainerPoint:e=>({x:e.clientX??600,y:e.clientY??200}),_limitZoom:z=>Math.max(1,Math.min(10,z)),
 _stop(){calls.push(['stop']);},_moveStart(){this.fire('zoomstart');this.fire('movestart');},
 _move(p,z,data){this.center=p;this.z=z;calls.push(['move',z,data]);this.fire('zoom',data);this.fire('move',data);},
 _moveEnd(){calls.push(['end']);this.fire('zoomend');this.fire('moveend');},
 fire(k,data){for(const fn of [...(events.get(k)||[])])fn(data);},
 on(names,fn){for(const k of names.split(' ')){if(!events.has(k))events.set(k,new Set());events.get(k).add(fn);}},
 off(names,fn){for(const k of names.split(' ')){events.get(k)?.delete(fn);if(!events.get(k)?.size)events.delete(k);}}};
 m.scrollWheelZoom={_enabled:true,nativeAdds:1,nativeRemoves:0,addHooks(){this.nativeAdds++;},removeHooks(){this.nativeRemoves++;},enabled(){return this._enabled;},enable(){if(!this._enabled){this._enabled=true;this.addHooks();}return this;},disable(){if(this._enabled){this._enabled=false;this.removeHooks();}return this;}};return m;
}
function event(deltaY,extra={}){return {deltaY,deltaMode:0,deltaX:0,preventDefault(){},stopPropagation(){},...extra};}
function send(m,e){m.container.listeners.get('wheel')(e);}
function step(){clock+=16;const pending=[...frames.values()];frames.clear();for(const fn of pending)fn(clock);}
function drain(){for(let n=0;frames.size&&n<1000;n++)step();assert.equal(frames.size,0);}
function store(raw=null){return {raw,getItem(){return this.raw;},setItem(k,v){this.raw=v;}};}
assert.equal(W.classify(event(100,{wheelDelta:-120})),'mouse');
for(const e of [event(100),event(0.2,{wheelDelta:120}),event(100,{wheelDelta:-120,deltaX:1}),event(100,{wheelDelta:-120,ctrlKey:true})])assert.notEqual(W.classify(e),'mouse');
const m=fake(),s=store(),a=W.create(m,{storage:s});assert.equal(a.available,true);assert.equal(W.create(m),a);
const anchorBefore=m.unproject({x:200,y:-100},5);
send(m,event(-100,{wheelDelta:120}));assert.equal(m.z,5);step();assert.ok(m.z>5&&m.z<5.25);drain();assert.equal(m.z,5.25);
const p=m.project(anchorBefore,m.z),center=m.project(m.center,m.z);assert.ok(Math.abs(p.x-center.x-200)<1e-8);assert.ok(Math.abs(p.y-center.y+100)<1e-8);
assert.equal(m.calls.filter(c=>c[0]==='end').length,1);const zs=m.calls.filter(c=>c[0]==='move').map(c=>c[1]);assert.ok(zs.every((z,i)=>!i||z>=zs[i-1]));assert.ok(m.calls.filter(c=>c[0]==='move').every(c=>c[2].pinch));
a.setReversed(true);assert.equal(s.raw,'true');send(m,event(-100,{wheelDelta:120}));drain();assert.equal(m.z,5);
send(m,event(-20,{ctrlKey:true}));drain();assert.ok(Math.abs(m.z-5.2)<1e-8);
clock+=200;const before=m.z;send(m,event(-0.5));send(m,event(-100,{wheelDelta:120}));drain();assert.ok(m.z>before); // touchpad tail lock ignores reversal
clock+=200;send(m,event(-100,{wheelDelta:120}));a.setReversed(false);const cancelled=m.z;drain();assert.equal(m.z,cancelled);
clock+=200;send(m,event(-100,{wheelDelta:120}));step();const atSwitch=m.z;send(m,event(-10,{ctrlKey:true}));drain();assert.ok(Math.abs(m.z-atSwitch-0.1)<1e-8);
clock+=200;send(m,event(-999999,{ctrlKey:true}));drain();assert.equal(m.z,10);send(m,event(999999,{ctrlKey:true}));drain();assert.equal(m.z,4);send(m,event(999999,{ctrlKey:true}));drain();assert.equal(m.z,1);
const h=m.scrollWheelZoom;h.disable();assert.equal(m.container.listeners.size,0);h.enable();assert.equal(m.container.listeners.size,4);h.enable();assert.equal(m.container.listeners.size,4);
send(m,event(-30,{ctrlKey:true}));m.fire('movestart');assert.equal(frames.size,0);
reduced=true;send(m,event(-10,{ctrlKey:true}));step();assert.equal(frames.size,0);reduced=false;
const adds=h.nativeAdds;a.dispose();a.dispose();assert.equal(h.nativeAdds,adds+1);assert.equal(h.enabled(),true);assert.equal(m.container.listeners.size,0);assert.equal(m.events.size,0);assert.equal(m.container.ownerDocument.listeners.size,0);
for(const raw of ['true','false']){const x=W.create(fake(),{storage:store(raw)});assert.equal(x.reversed,raw==='true');assert.equal(x.persistent,true);x.dispose();}
for(const raw of ['1','True',' true ','{}','null','']){const st=store(raw),x=W.create(fake(),{storage:st});assert.equal(x.reversed,false);x.setReversed(true);assert.equal(st.raw,raw);assert.equal(x.persistent,false);x.dispose();}
const r=W.create(fake(),{storage:{getItem(){throw Error();}}});r.setReversed(true);assert.equal(r.status,'read-error');r.dispose();
const w=W.create(fake(),{storage:{getItem(){return null;},setItem(){throw Error();}}});w.setReversed(true);assert.equal(w.status,'write-error');w.dispose();
// Dense queued events still produce exactly one camera update in a frame.
const queued=fake(),qa=W.create(queued);queued.scrollWheelZoom._timer=++serial;timers.set(serial,()=>{});
qa.setReversed(true);assert.equal(timers.size,0);
for(let n=0;n<20;n++)send(queued,event(-0.25));
assert.equal(frames.size,1);step();assert.equal(queued.calls.filter(c=>c[0]==='move').length,1);drain();qa.dispose();
// Safari scale input keeps its direction with the mouse preference enabled.
const safari=fake(),sa=W.create(safari);sa.setReversed(true);
safari.container.listeners.get('gesturestart')({scale:1,preventDefault(){}});
safari.container.listeners.get('gesturechange')({scale:2,clientX:600,clientY:200,preventDefault(){}});
send(safari,event(100,{ctrlKey:true}));drain();assert.equal(safari.z,6);
safari.container.listeners.get('gesturechange')({scale:1,clientX:600,clientY:200,preventDefault(){}});drain();assert.equal(safari.z,5);
safari.container.listeners.get('gestureend')({preventDefault(){}});send(safari,event(-10,{ctrlKey:true}));drain();assert.equal(safari.z,5.1);sa.dispose();
// Complete pending CSS animation before capturing own anchor/target.
const css=fake();css._animatingZoom=true;css._onZoomTransitionEnd=function(){this._animatingZoom=false;this.z=6;this.fire('zoomstart');};
const ca=W.create(css);send(css,event(-3,{deltaMode:1}));drain();assert.equal(css.z,6.25);ca.dispose();
const hidden=fake(),ha=W.create(hidden);send(hidden,event(-1));hidden.container.ownerDocument.hidden=true;
hidden.container.ownerDocument.listeners.get('visibilitychange')();assert.equal(frames.size,0);ha.dispose();
context.L.Browser.any3d=false;const flat=fake(),flatOriginal=flat.scrollWheelZoom.addHooks;assert.equal(W.create(flat).available,false);assert.equal(flat.scrollWheelZoom.addHooks,flatOriginal);context.L.Browser.any3d=true;
context.L.version='2';const u=fake(),original=u.scrollWheelZoom.addHooks;assert.equal(W.create(u).available,false);assert.equal(u.scrollWheelZoom.addHooks,original);context.L.version='1.9.4';
const disabled=fake();disabled.scrollWheelZoom.disable();const d=W.create(disabled);assert.equal(disabled.container.listeners.size,0);d.dispose();assert.equal(disabled.scrollWheelZoom.enabled(),false);
const line=fake(),la=W.create(line);send(line,event(-3,{deltaMode:1}));drain();assert.equal(line.z,5.25);la.setReversed(true);clock+=200;send(line,event(-1,{deltaMode:2}));drain();assert.equal(line.z,5);la.dispose();
const unload=fake();W.create(unload);send(unload,event(3,{deltaMode:1}));unload.scrollWheelZoom.disable();unload.fire('unload');assert.equal(frames.size,0);assert.equal(unload.events.size,0);
console.log('PASS: deterministic classifier, mouse-only reversal, fractional anchored frames, source cancellation, bounds, lifecycle and storage. No physical hardware/FPS or browser test.');
