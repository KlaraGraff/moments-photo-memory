import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const context = vm.createContext({AbortController, setTimeout, clearTimeout});
vm.runInContext(fs.readFileSync(new URL('../src/road-routing.js', import.meta.url), 'utf8') + '\nglobalThis.R = RoadRouting;', context);
const R = context.R;
const input = {start:{latitude:10,longitude:20},end:{latitude:11,longitude:21},mode:'car',consent:true};
const body = () => ({code:'Ok', routes:[{geometry:{type:'LineString',coordinates:[[20,10],[21,11]]},distance:100,duration:20}],waypoints:[{distance:3},{distance:4}]});
const response = payload => ({ok:true,status:200,json:async()=>payload});
const code = async (promise, expected) => assert.rejects(promise, e=>e.code===expected);
let calls=[];
const client=R.create({minIntervalMs:0,fetchImpl:async(url,options)=>{calls.push({url,options});return response(body());}});
await code(client.plan({...input,consent:false}),'consent-required'); assert.equal(calls.length,0);
for (const change of [{start:{latitude:91,longitude:0}},{start:{latitude:NaN,longitude:0}},{start:{latitude:0,longitude:181}},{end:input.start},{start:{latitude:'10',longitude:20}}]) await code(client.plan({...input,...change}),'invalid-points');
await code(client.plan({...input,mode:'train'}),'invalid-mode');assert.equal(calls.length,0);
for (const mode of ['car','foot','bike']) {
 const result=await client.plan({...input,mode});assert.equal(result.distance,100);assert.equal(result.geometry.coordinates.length,2);assert.equal(result.waypointDistances[0],3);
 assert.ok(calls.at(-1).url.startsWith(`https://routing.openstreetmap.de/routed-${mode}/route/v1/driving/20,10;21,11?`));
 assert.equal(calls.at(-1).options.cache,'no-store');assert.equal(calls.at(-1).options.redirect,'error');
 assert.equal(calls.at(-1).options.credentials,'omit');assert.equal(calls.at(-1).options.referrerPolicy,'strict-origin-when-cross-origin');
 result.geometry.coordinates[0][0]=99;
 const cached=await client.plan({...input,mode});assert.equal(cached.geometry.coordinates[0][0],20);
}
assert.equal(calls.length,3); await code(client.plan({...input,consent:1}),'consent-required');
await client.plan({...input,start:{latitude:10.000000001,longitude:20}});assert.equal(calls.length,4);
client.clearCache();await client.plan(input);assert.equal(calls.length,5);
for (const [reply,expected] of [[{ok:false,status:429},'rate-limit'],[{ok:false,status:500},'network'],[response({code:'NoRoute'}),'no-route'],[response({code:'NoSegment'}),'no-route'],[response({code:'Ok',routes:[]}), 'invalid-response'],[response({...body(),routes:[{...body().routes[0],distance:Infinity}]}),'invalid-response'],[response({...body(),routes:[{...body().routes[0],geometry:{type:'LineString',coordinates:[[181,0],[0,0]]}}]}),'invalid-response']]) {
 let count=0;const c=R.create({minIntervalMs:0,fetchImpl:async()=>{count++;return reply;}});await code(c.plan(input),expected);await code(c.plan(input),expected);assert.equal(count,2);
}
for (const osrmCode of ['NoRoute', 'NoSegment']) {
 const c=R.create({fetchImpl:async()=>({ok:false,status:400,json:async()=>({code:osrmCode})})});
 await code(c.plan(input),'no-route');
}
const malformedError=R.create({fetchImpl:async()=>({ok:false,status:400,json:async()=>{throw Error('not JSON');}})});
await code(malformedError.plan(input),'network');
const unknownError=R.create({fetchImpl:async()=>({ok:false,status:400,json:async()=>({code:'InvalidQuery'})})});
await code(unknownError.plan(input),'network');
const badJson=R.create({fetchImpl:async()=>({ok:true,json:async()=>{throw Error('bad')}})});await code(badJson.plan(input),'invalid-response');
const offline=R.create({fetchImpl:async()=>{throw Error('offline')}});await code(offline.plan(input),'network');
const redirected=R.create({fetchImpl:async(_url,options)=>{assert.equal(options.redirect,'error');throw new TypeError('Redirect rejected');}});
await code(redirected.plan(input),'network');
let resolveOld, count=0, states=[];
const stale=R.create({minIntervalMs:0,onState:s=>states.push(s),fetchImpl:()=>++count===1?new Promise(resolve=>{resolveOld=resolve;}):Promise.resolve(response(body()))});
const old=stale.plan(input);const oldCheck=code(old,'aborted');await stale.plan({...input,mode:'bike'});await oldCheck;
resolveOld(response(body()));await new Promise(r=>setTimeout(r,0));assert.equal(states.filter(s=>s.status==='success').length,1);
await stale.plan(input);assert.equal(count,3);
const timeout=R.create({timeoutMs:5,fetchImpl:()=>new Promise(()=>{})});await code(timeout.plan(input),'timeout');
const aborter=new AbortController();const external=R.create({fetchImpl:()=>new Promise(()=>{})});const pending=external.plan({...input,signal:aborter.signal});aborter.abort();await code(pending,'aborted');
let clock=0, release, starts=[];
const throttled=R.create({now:()=>clock,minIntervalMs:1100,sleep:ms=>new Promise(resolve=>{assert.equal(ms,1100);release=resolve;}),fetchImpl:async()=>{starts.push(clock);return response(body());}});
await throttled.plan(input);const queued=throttled.plan({...input,mode:'bike'});const queuedCheck=code(queued,'aborted');throttled.cancel();release();await queuedCheck;assert.equal(starts.length,1);
const next=throttled.plan({...input,mode:'foot'});clock=1100;release();await next;assert.deepEqual(starts,[0,1100]);
let evictionCount=0;const eviction=R.create({minIntervalMs:0,fetchImpl:async()=>{evictionCount++;return response(body());}});
for(let i=0;i<21;i++)await eviction.plan({...input,start:{latitude:i,longitude:20}});
await eviction.plan({...input,start:{latitude:0,longitude:20}});assert.equal(evictionCount,22);
console.log('Road routing: consent, modes, coordinates, validation, errors, cache isolation/precision/eviction, cancellation, stale responses, timeout and throttle passed (offline mocks only).');
