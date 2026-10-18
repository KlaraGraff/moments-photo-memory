/* Standalone prototype model. Never resolves clues or changes photo metadata. */
const CustomPlaces = (() => {
  const KEY = 'moments-sanitized-custom-places-v1';
  const clone = value => JSON.parse(JSON.stringify(value));
  const normalized = value => value.normalize('NFKC').trim().replace(/\s+/gu, ' ').toLocaleLowerCase('en');
  const validId = id => typeof id === 'string' && /^[A-Za-z0-9_-]{1,100}$/.test(id);
  function create({storage, storageKey = KEY, knownIds = []} = {}) {
    const allowed = new Set(knownIds), status = {code:'memory', persistent:false};
    let rows = [], serial = 0, corrupted = false;
    function validate(value, existing = rows) {
      if (!value || typeof value !== 'object' || !validId(value.id) || !validId(value.trip)) throw new Error('invalid-id');
      if (typeof value.name !== 'string' || !value.name.trim() || [...value.name.trim()].length > 60) throw new Error('invalid-name');
      if (typeof value.clue !== 'string' || [...value.clue].length > 1200) throw new Error('invalid-clue');
      if (!Array.isArray(value.photoIds) || value.photoIds.some(id => !validId(id) || !allowed.has(id))) throw new Error('invalid-photo');
      if (existing.some(p => p.id !== value.id && p.trip === value.trip && normalized(p.name) === normalized(value.name))) throw new Error('duplicate-name');
      return {id:value.id, name:value.name.trim(), clue:value.clue, trip:value.trip, photoIds:[...new Set(value.photoIds)]};
    }
    try {
      if (storage) {
        const raw = storage.getItem(storageKey);
        if (raw !== null) {
          const parsed = JSON.parse(raw);
          if (!parsed || parsed.version !== 1 || !Array.isArray(parsed.places)) throw new Error('invalid-data');
          const loaded = [];
          for (const p of parsed.places) {
            if (loaded.some(row => row.id === p.id)) throw new Error('duplicate-id');
            loaded.push(validate(p, loaded));
          }
          rows = loaded;
        }
        status.code = 'ready'; status.persistent = true;
      }
    } catch (_) { corrupted = true; status.code = 'read-error'; status.persistent = false; }
    function persist() {
      if (!storage || corrupted) return;
      try { storage.setItem(storageKey, JSON.stringify({version:1, places:rows})); status.code='ready'; status.persistent=true; }
      catch (_) { status.code='write-error'; status.persistent=false; }
    }
    return {
      list:trip => clone(rows.filter(p => trip === undefined || p.trip === trip)),
      get:id => { const p=rows.find(p=>p.id===id); return p ? clone(p) : null; },
      save(input) {
        if (!input || typeof input !== 'object') throw new Error('invalid-data');
        if (input.id !== undefined && !rows.some(p=>p.id===input.id)) throw new Error('unknown-id');
        let id=input.id;
        if (!id) { do { id='cp_'+Date.now().toString(36)+'_'+(++serial).toString(36); } while(rows.some(p=>p.id===id)); }
        const p=validate({...input,id,clue:input.clue ?? '',photoIds:input.photoIds ?? []});
        const index=rows.findIndex(row=>row.id===id);
        if(index<0) rows.push(p); else rows[index]=p;
        persist(); return clone(p);
      },
      remove(id) { const index=rows.findIndex(p=>p.id===id); if(index<0) return false; rows.splice(index,1); persist(); return true; },
      exportData:() => clone({version:1,places:rows}),
      storageStatus:status
    };
  }
  return {create, storageKey:KEY};
})();

/* HTML helpers are inert. Host handles data-action events and selected-photo unions. */
const CustomPlaceUI = (() => {
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const copy = {
    zh:{add:'添加地点',edit:'编辑地点',name:'地点名称',clue:'位置线索（可选）',hint:'可填写名称、链接或坐标；仅保存文字，不解析或定位。',attach:'关联当前选中的照片',save:'保存地点',cancel:'取消',remove:'删除地点',confirm:'确认删除地点？照片将保持不变。',yes:'删除地点',no:'保留地点',existing:'已关联照片',selected:'当前选中',local:'当前修改仅保存在内存中；可导出备份。',read:'本地存储无法读取；原始数据未覆盖，当前修改仅保存在内存中。',duplicate:'此行程已有同名地点。',invalid:'请检查地点名称、线索和照片。'},
    en:{add:'Add place',edit:'Edit place',name:'Place name',clue:'Location clue (optional)',hint:'A name, link or coordinates; saved as text, without lookup or positioning.',attach:'Attach currently selected photos',save:'Save place',cancel:'Cancel',remove:'Remove place',confirm:'Remove this place? Photos will remain unchanged.',yes:'Remove place',no:'Keep place',existing:'Attached photos',selected:'Currently selected',local:'Changes are held in memory only; export a backup.',read:'Local storage could not be read. Original data is preserved; changes are held in memory only.',duplicate:'This trip already has a place with that name.',invalid:'Check the place name, clue and photos.'},
    de:{add:'Ort hinzufügen',edit:'Ort bearbeiten',name:'Ortsname',clue:'Ortshinweis (optional)',hint:'Name, Link oder Koordinaten; nur als Text gespeichert, ohne Suche oder Ortung.',attach:'Aktuell ausgewählte Fotos zuordnen',save:'Ort speichern',cancel:'Abbrechen',remove:'Ort entfernen',confirm:'Diesen Ort entfernen? Die Fotos bleiben unverändert.',yes:'Ort entfernen',no:'Ort behalten',existing:'Zugeordnete Fotos',selected:'Aktuell ausgewählt',local:'Änderungen bleiben nur im Arbeitsspeicher; Sicherung exportieren.',read:'Lokaler Speicher nicht lesbar. Originaldaten bleiben erhalten; Änderungen bleiben nur im Arbeitsspeicher.',duplicate:'Diese Reise enthält bereits einen Ort mit diesem Namen.',invalid:'Ortsname, Hinweis und Fotos prüfen.'}
  };
  const strings = lang => ({...(copy[lang] || copy.en)});
  const button=(label,action,cls='')=>`<button type="button" class="cp-button ${cls}" data-action="${esc(action)}">${esc(label)}</button>`;
  function form({lang='en',place=null,selectedCount=0,error='',confirmRemove=false,storageStatus}={}) {
    const s=strings(lang), count=Math.max(0,Number(selectedCount)||0), existing=place?.photoIds?.length||0;
    const message=error === 'duplicate-name' ? s.duplicate : error ? (error.startsWith('invalid-')||error==='unknown-id' ? s.invalid : error) : '';
    return `<section class="cp-form" aria-label="${esc(place?s.edit:s.add)}"><h3>${esc(place?s.edit:s.add)}</h3><label for="cp-name">${esc(s.name)} <span aria-hidden="true">*</span></label><input id="cp-name" name="cp-name" type="text" required maxlength="60" value="${esc(place?.name)}" autocomplete="off"><label for="cp-clue">${esc(s.clue)}</label><textarea id="cp-clue" name="cp-clue" maxlength="1200" rows="2" aria-describedby="cp-hint">${esc(place?.clue)}</textarea><p id="cp-hint" class="cp-hint">${esc(s.hint)}</p><p class="cp-count">${esc(s.existing)}: ${existing} · ${esc(s.selected)}: ${count}</p>${count?`<label class="cp-attach"><input id="cp-attach" type="checkbox" ${place?'':'checked'}> ${esc(s.attach)} (${count})</label>`:''}${message?`<p class="cp-error" role="alert">${esc(message)}</p>`:''}${storageStatus && !storageStatus.persistent?`<p class="cp-storage" role="status">${esc(storageStatus.code==='read-error'?s.read:s.local)}</p>`:''}<div class="cp-actions">${button(s.save,'cp-save','cp-primary')}${button(s.cancel,'cp-cancel')}${place?button(s.remove,'cp-remove','cp-remove'):''}</div>${place&&confirmRemove?`<div class="cp-confirm" role="group" aria-label="${esc(s.confirm)}"><p>${esc(s.confirm)}</p><div class="cp-actions">${button(s.yes,'cp-remove-confirm','cp-danger')}${button(s.no,'cp-remove-cancel')}</div></div>`:''}</section>`;
  }
  function chip(place,active=false,lang='en') {
    const s=strings(lang);
    return `<span class="cp-chip ${active?'active':''}">${button(place.name,'cp-select:'+place.id,'cp-select').replace('<button ', '<button aria-pressed="'+active+'" ')}${active?`<button type="button" class="cp-chip-edit" data-action="${esc('cp-edit:'+place.id)}" aria-label="${esc(s.edit+' · '+place.name)}">✎</button>`:''}</span>`;
  }
  return {strings,form,chip};
})();
