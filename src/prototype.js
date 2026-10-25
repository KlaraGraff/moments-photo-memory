// Prototype-only integration. Existing review files and their storage keys stay untouched.
tr('sample','交互样张 · 自定义地点与动效','Interaction study · Places & motion','Interaktionsentwurf · Orte & Bewegung');
tr('samplehint','独立试用页，旧版记录保留原处。','Separate trial page; earlier notes stay in their original tab.','Separate Testseite; frühere Notizen bleiben im ursprünglichen Tab.');
tr('cpempty','先给这个地点关联几张照片','Add photos to this place','Diesem Ort Fotos zuordnen');
tr('cpemptybody','返回全部照片勾选，再点击这个地点旁的编辑按钮关联。','Select photos in All places, then edit this place to attach them.','Unter Alle Orte Fotos auswählen und sie dann über Ort bearbeiten zuordnen.');
tr('cpsaved','地点已保存','Place saved','Ort gespeichert');
tr('cpremoved','地点标签已删除，照片与回忆保留','Place label removed; photos and memories kept','Ortslabel entfernt; Fotos und Erinnerungen bleiben erhalten');
tr('cpnote','自定义地点 · {n} 张关联照片','Custom place · {n} linked photos','Eigener Ort · {n} zugeordnete Fotos');
tr('cpnewstate','添加地点展开','Add place expanded','Ort hinzufügen, geöffnet');
let cpStorage;try{cpStorage=localStorage;}catch{}
const placeStore=CustomPlaces.create({storage:cpStorage,knownIds:id=>Object.hasOwn(byId,id)});
S.customLocation=null;
let placeDraft=null,placeEditorOpen=false,placeError='',placeRemove=false;
const placeDrafts=new Map();
const placeDraftKey=p=>p.id||'new:'+p.trip;
const selectedPhotoIds=()=>[...new Set(currentGroups().filter(g=>S.selected.has(g[0])).flat())];
const availablePlaces=()=>placeStore.list().filter(p=>S.trip==='all'||p.trip==='all'||p.trip===S.trip);
const originalFiltered=filtered;
filtered=()=>originalFiltered().filter(g=>!S.customLocation||g.some(id=>placeStore.get(S.customLocation)?.photoIds.includes(id)));
const originalLocations=renderLocations;
renderLocations=function(){
  originalLocations();
  const host=$('location-shortcuts'),row=host.querySelector('.location-row'),link=row.querySelector('a');
  for(const p of availablePlaces())link.insertAdjacentHTML('beforebegin',CustomPlaceUI.chip(p,S.customLocation===p.id,S.lang));
  const s=CustomPlaceUI.strings(S.lang);
  link.insertAdjacentHTML('beforebegin',`<button class="location-add" data-action="cp-add" aria-expanded="${placeEditorOpen}" aria-controls="place-editor">${icon('plus')}${esc(s.add)}</button>`);
  if(S.customLocation){row.querySelector('[data-action="location:all"]')?.classList.remove('active');const p=placeStore.get(S.customLocation);if(p)host.insertAdjacentHTML('beforeend',`<div class="custom-location-note moments-ink-reveal"><span>${esc(p.name)} · ${t('cpnote').replace('{n}',p.photoIds.length)}</span>${btn(esc(s.edit),'cp-edit:'+p.id)}${p.clue?`<span>${esc(p.clue)}</span>`:''}</div>`);}
  renderPlaceEditor();
};
function rememberPlaceForm(){if(!placeEditorOpen||!placeDraft||!$('cp-name'))return;placeDraft.name=$('cp-name').value;placeDraft.clue=$('cp-clue').value;if($('cp-attach'))placeDraft.attach=$('cp-attach').checked;placeDrafts.set(placeDraftKey(placeDraft),{...placeDraft});}
function renderPlaceEditor(){
  const host=$('place-editor');
  if(!placeEditorOpen){host.hidden=true;return;}
  host.hidden=false;
  host.innerHTML=CustomPlaceUI.form({lang:S.lang,place:placeDraft?.id?placeDraft:null,selectedCount:selectedPhotoIds().length,error:placeError,confirmRemove:placeRemove,storageStatus:placeStore.storageStatus});
  $('cp-name').value=placeDraft?.name||'';$('cp-clue').value=placeDraft?.clue||'';
  if($('cp-attach'))$('cp-attach').checked=!!placeDraft?.attach;
}
function updatePlaceSelection(){
 if(!placeEditorOpen||!$('cp-name'))return;
 const host=$('place-editor'),n=selectedPhotoIds().length,s=CustomPlaceUI.strings(S.lang);
 host.querySelector('.cp-count').textContent=s.existing+': '+(placeDraft.photoIds?.length||0)+' · '+s.selected+': '+n;
 let label=host.querySelector('.cp-attach');
 if(!n){label?.remove();return;}
 if(!label){label=document.createElement('label');label.className='cp-attach';const checkbox=document.createElement('input');checkbox.id='cp-attach';checkbox.type='checkbox';checkbox.checked=!!placeDraft.attach;label.append(checkbox);host.querySelector('.cp-count').after(label);}
 const checkbox=label.querySelector('input');label.replaceChildren(checkbox,document.createTextNode(' '+s.attach+' ('+n+')'));
}
function openPlaceEditor(id){
  rememberPlaceForm();
  placeDraft=id?placeDrafts.get(id)||(placeStore.get(id)?{...placeStore.get(id),attach:false}:null):placeDrafts.get('new:'+S.trip)||{name:'',clue:'',trip:S.trip,photoIds:[],attach:true};
  if(!placeDraft)return;
  placeEditorOpen=true;placeError='';placeRemove=false;
  renderLocations();Motion.reveal($('place-editor'),true);$('cp-name').focus({preventScroll:true});
}
function closePlaceEditor(){placeEditorOpen=false;placeDraft=null;placeError='';placeRemove=false;const button=document.querySelector('[data-action="cp-add"]');button?.setAttribute('aria-expanded','false');button?.focus({preventScroll:true});Motion.reveal($('place-editor'),false);}
function savePlace(){
  rememberPlaceForm();
  if(!$('cp-name').reportValidity())return;
  try{
    const photoIds=[...new Set([...(placeDraft.photoIds||[]),...(placeDraft.attach?selectedPhotoIds():[])])];
    const p=placeStore.save({...placeDraft,photoIds});
    placeDrafts.delete(placeDraftKey(placeDraft));placeEditorOpen=false;placeDraft=null;placeError='';placeRemove=false;
    S.customLocation=p.id;S.location='all';S.sublocation='all';S.view='gallery';
    renderFrame();toast(placeStore.storageStatus.persistent?t('cpsaved'):CustomPlaceUI.strings(S.lang).local);
    document.querySelector(`[data-action="cp-select:${p.id}"]`)?.focus({preventScroll:true});
  }catch(error){placeError=error.message;renderPlaceEditor();$('cp-name').focus({preventScroll:true});}
}
document.addEventListener('input',e=>{if(e.target.id?.startsWith('cp-'))rememberPlaceForm();},true);
document.addEventListener('change',()=>rememberPlaceForm(),true);
document.addEventListener('change',e=>{if(e.target.dataset.select)updatePlaceSelection();});
document.addEventListener('click',e=>{
  const button=e.target.closest('[data-action]');if(!button)return;
  const [action,id]=button.dataset.action.split(':');
  if(!action.startsWith('cp-')){
    rememberPlaceForm();
    if(['trip','favorites','clearfilter','location','sublocation'].includes(action))S.customLocation=null;
    if(['trip','favorites'].includes(action)){placeEditorOpen=false;placeDraft=null;placeRemove=false;}
    return;
  }
  e.preventDefault();e.stopImmediatePropagation();
  Motion.run(()=>{
    switch(action){
      case 'cp-add':openPlaceEditor();break;
      case 'cp-edit':openPlaceEditor(id);break;
      case 'cp-select':rememberPlaceForm();S.customLocation=id;S.location='all';S.sublocation='all';S.view='gallery';renderFrame();break;
      case 'cp-cancel':if(placeDraft)placeDrafts.delete(placeDraftKey(placeDraft));closePlaceEditor();break;
      case 'cp-save':savePlace();break;
      case 'cp-remove':rememberPlaceForm();placeRemove=true;renderPlaceEditor();$('place-editor').querySelector('[data-action="cp-remove-cancel"]')?.focus();break;
      case 'cp-remove-cancel':placeRemove=false;renderPlaceEditor();$('place-editor').querySelector('[data-action="cp-remove"]')?.focus();break;
      case 'cp-remove-confirm':{
        const oldId=placeDraft?.id;if(!oldId)break;
        placeStore.remove(oldId);placeDrafts.delete(placeDraftKey(placeDraft));placeEditorOpen=false;placeDraft=null;placeRemove=false;
        if(S.customLocation===oldId)S.customLocation=null;
        renderFrame();toast(placeStore.storageStatus.persistent?t('cpremoved'):CustomPlaceUI.strings(S.lang).local);document.querySelector('[data-action="cp-add"]')?.focus({preventScroll:true});break;
      }
    }
  });
},true);
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!e.isComposing&&e.keyCode!==229&&placeEditorOpen&&$('place-editor').contains(e.target)){e.preventDefault();rememberPlaceForm();closePlaceEditor();}});

// Keep the card's composer and image nodes when expanding sibling content.
redrawCard=function(id){
  const existing=document.querySelector(`.card[data-current="${id}"]`);if(!existing)return;
  const group=currentGroups().find(g=>g[0]===existing.dataset.card);if(!group)return;
  if(cover(group)!==id){existing.outerHTML=card(group);return;}
  const template=document.createElement('template');template.innerHTML=card(group);const fresh=template.content.firstElementChild;
  existing.querySelector('.composer-bottom').innerHTML=fresh.querySelector('.composer-bottom').innerHTML;
  if(existing.querySelector('.card-footer'))existing.querySelector('.card-footer').innerHTML=fresh.querySelector('.card-footer').innerHTML;
  for(const [selector,anchor] of [['.member-strip','.image-wrap'],['.inline-details','.composer'],['.source-note',null]]){
    const old=existing.querySelector(selector),next=fresh.querySelector(selector);
    if(next&&!old){if(anchor)existing.querySelector(anchor).after(next);else existing.append(next);Motion.reveal(next,true);}
    else if(old&&!next){Motion.reveal(old,false,true);}
    else if(old&&next&&old.parentElement.dataset.closing==='true'){Motion.reveal(old,true);}
  }
};
const baseBulk=renderBulk;renderBulk=function(){baseBulk();updatePlaceSelection();};
const baseGallery=renderGallery;
renderGallery=function(){baseGallery();if(S.customLocation&&S.view==='gallery'&&!filtered().length){$('gallery').innerHTML=placeStore.get(S.customLocation)?.photoIds.length?emptyView(true):`<section class="empty"><div class="empty-art"><div class="frame">${icon('pin')}</div><div class="frame">${icon('plus')}</div></div><h2>${t('cpempty')}</h2><p>${t('cpemptybody')}</p>${btn(t('allareas'),'location:all','solid')}</section>`;}};
const baseFrame=renderFrame;
renderFrame=function(){rememberPlaceForm();baseFrame();const s=$('sample-state');s.insertAdjacentHTML('beforeend',`<option value="custom-place">${t('cpnewstate')}</option>`);};
const baseChangeView=changeView;
changeView=function(view){if(view==='custom-place'){baseChangeView('gallery');openPlaceEditor();$('sample-state').value=view;}else{S.customLocation=null;placeEditorOpen=false;baseChangeView(view);}};
const baseOpenViewer=openViewer;openViewer=function(id){baseOpenViewer(id);Motion.enterDialog($('viewer'));};
const baseShowDialog=showDialog;showDialog=function(kind){baseShowDialog(kind);Motion.enterDialog($('dialog'));};
for(const dialog of [$('viewer'),$('dialog')])dialog.addEventListener('cancel',e=>{e.preventDefault();Motion.closeDialog(dialog);});
document.addEventListener('click',e=>{const a=e.target.closest('[data-action]')?.dataset.action;if(a==='closeviewer'||a==='closedialog'){e.preventDefault();e.stopImmediatePropagation();Motion.closeDialog($(a==='closeviewer'?'viewer':'dialog'));}},true);
renderFrame=Motion.wrap(renderFrame);renderGallery=Motion.wrap(renderGallery);redrawCard=Motion.wrap(redrawCard);applyDensity=Motion.wrap(applyDensity);
exportTrial=function(){const payload={version:2,kind:'places-motion-prototype',notes:drafts,customPlaces:placeStore.exportData().places};const blob=new Blob([JSON.stringify(payload,null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='moments-places-and-notes.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
window.prototypeState=()=>({places:placeStore.exportData(),filter:S.customLocation,editorOpen:placeEditorOpen,motionReduced:Motion.reduced});

// Viewer details share the same in-place reveal, preserving its live textarea.
document.addEventListener('click',e=>{const button=e.target.closest('[data-action]');if(!button?.dataset.action.startsWith('expand:')||!$('viewer').open)return;e.preventDefault();e.stopImmediatePropagation();const id=button.dataset.action.split(':')[1],host=$('viewer').querySelector('.viewer-bottom');S.expanded.has(id)?S.expanded.delete(id):S.expanded.add(id);const composerTemplate=document.createElement('template');composerTemplate.innerHTML=composer(id,true);host.querySelector('.composer-bottom').innerHTML=composerTemplate.content.querySelector('.composer-bottom').innerHTML;const old=host.querySelector('.inline-details');if(S.expanded.has(id)){if(old)Motion.reveal(old,true);else{const template=document.createElement('template');template.innerHTML=details(id,true);const next=template.content.firstElementChild;host.querySelector('.composer').after(next);Motion.reveal(next,true);}}else if(old)Motion.reveal(old,false,true);host.querySelector('[data-action="expand:'+id+'"]')?.focus({preventScroll:true});},true);
