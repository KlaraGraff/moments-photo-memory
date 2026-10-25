import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const js=readFileSync(new URL('../src/footprints.js',import.meta.url),'utf8');
const css=readFileSync(new URL('../src/footprints.css',import.meta.url),'utf8');
const page=readFileSync(new URL('../dist/index.html',import.meta.url),'utf8');
const globe=readFileSync(new URL('../src/globe-workspace.html',import.meta.url),'utf8');
const bridge=readFileSync(new URL('../src/globe-bridge.js',import.meta.url),'utf8');

for(const token of ['footprints-workspace','3D GLOBE','data-fp-view','data-footprint-photo','motion-off','seedExpanded','ProductGlobe.create','placeRecords'])assert(js.includes(token),token);
for(const token of ['data-engine="local"','loadScript(src,timeout=2800)','pendingKind','generation','本地地球','WORLD_ATLAS_COUNTRIES','WORLD_ATLAS_LAND','country.shapes','COUNTRY_FEATURES','polygonGeoJsonGeometry','COUNTRY_LABEL_POINTS','showGraticules(false)','pointOfView({lat:24,lng:12','国家边界','国家名称','overviewArcs','routeDistanceKm','polygonsTransitionDuration(0)','arcsTransitionDuration(0)','labelsTransitionDuration(0)','autoRotate=false','location.protocol===\'file:\'','本机预览服务','globe.gl@2.46.2','cesium@1.118.2'])assert(globe.includes(token),token);
for(const token of ['sync(value,isVisible=true)','if(visible&&!frame)start()','send(\'visibility\',{visible:false})'])assert(bridge.includes(token),token);
assert(js.indexOf('seedExpanded();original.apply')<js.indexOf('refreshFootprints();'), 'seed memory before first render');
assert(js.includes("if(action==='timeline'){state.view='timeline';refreshFootprints();return}"), 'timeline switch avoids full redraw');
assert(js.includes("if(action==='more'){state.limit+=36;refreshFootprints();return}"), 'timeline pagination avoids full redraw');
for(const token of ['footprints-workspace','footprints-map-host','footprints-day','prefers-reduced-motion'])assert(css.includes(token),token);
for(const token of ['footprints-workspace','footprintsWorkspace','data-footprints-nav','3D GLOBE'])assert(page.includes(token),token);
assert.equal((page.match(/id='footprints-workspace'/g)||[]).length,1);
assert(page.includes("host.id='footprints-workspace'"));
console.log('Footprints workspace build, shared focus hooks, default-memory seed, sample states and reduced-motion styles passed.');
