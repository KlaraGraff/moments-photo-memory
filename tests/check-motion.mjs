import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const events={},preference={matches:false,addEventListener:(type,fn)=>events[type]=fn};
let raf=0;const frames=new Map();
class Node {
  constructor(){this.hidden=false;this.inert=false;this.isConnected=true;this.dataset={};this.style={removeProperty(k){delete this[k];}};this.classList={contains:k=>k==='motion-reveal'};this.animations=[];this.open=true;this.closed=0;this.focused=0;this.id='';}
  getBoundingClientRect(){return {height:160,width:300,left:0,top:0,bottom:160};}
  animate(){let resolve,reject;const finished=new Promise((r,j)=>{resolve=r;reject=j;});const a={finished,state:'running',cancel(){if(a.state!=='running')return;a.state='cancelled';reject(new Error('cancelled'));},finish(){if(a.state!=='running')return;a.state='finished';resolve();}};this.animations.push(a);return a;}
  focus(){this.focused++;document.activeElement=this;}
  close(){this.closed++;this.open=false;}
  closest(){return null;}
  remove(){this.removed=true;this.isConnected=false;}
}
const body=new Node(),replacement=new Node(),document={body,documentElement:new Node(),activeElement:body,addEventListener(){},querySelectorAll:()=>[],getElementById:()=>replacement};
const ctx=vm.createContext({document,matchMedia:()=>preference,innerHeight:900,requestAnimationFrame:fn=>{frames.set(++raf,fn);return raf;},cancelAnimationFrame:id=>frames.delete(id),queueMicrotask,console});
vm.runInContext(fs.readFileSync(new URL('../src/motion.js',import.meta.url),'utf8')+'\nglobalThis.motion=Motion;',ctx);
const M=ctx.motion;M.start();const tick=async()=>{await Promise.resolve();await Promise.resolve();};
const checks=[];
const panel=new Node();M.reveal(panel,false);const old=panel.animations.at(-1);M.reveal(panel,true);assert.equal(old.state,'cancelled');panel.animations.at(-1).finish();await tick();assert.equal(panel.hidden,false);assert.equal(panel.inert,false);assert.equal(panel.style.overflow,undefined);checks.push('Rapid collapse then reopen cancels stale hiding and clears temporary styles');
M.reveal(panel,false);preference.matches=true;events.change();await tick();assert.equal(panel.hidden,true);assert.equal(panel.inert,true);checks.push('Switching to reduced motion completes the pending collapse');
const count=panel.animations.length;M.reveal(panel,true);assert.equal(panel.hidden,false);assert.equal(panel.animations.length,count);checks.push('Reduced motion opens immediately without creating an animation');
const clicked=new Node();clicked.id='cp-add';document.activeElement=clicked;const input=new Node();M.run(()=>{clicked.isConnected=false;document.activeElement=input;});assert.equal(replacement.focused,0);assert.equal(document.activeElement,input);checks.push('Intentional focus into the place editor is preserved');
const button=new Node();button.id='density';document.activeElement=button;M.run(()=>{button.isConnected=false;document.activeElement=body;});assert.equal(replacement.focused,1);checks.push('Lost keyboard focus is restored after a control is rebuilt');
preference.matches=false;const dialog=new Node();M.closeDialog(dialog);const closing=dialog.animations.at(-1);M.enterDialog(dialog);assert.equal(closing.state,'cancelled');dialog.animations.at(-1).finish();await tick();assert.equal(dialog.open,true);assert.equal(dialog.closed,0);checks.push('An interrupted close does not close a subsequently reopened dialog');
const n=new Node();M.play(n,[{},{}]);const first=n.animations.at(-1);M.play(n,[{},{}]);assert.equal(first.state,'cancelled');n.animations.at(-1).finish();await tick();checks.push('Each element has only one active motion owner');
const report={scope:'Offline animation API doubles and state checks. No browser, rendering, network or frame-rate measurement.',passed:checks.length,checks};

console.log(JSON.stringify(report,null,2));
