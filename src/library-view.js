/* Pure pagination model: independent of the private asset catalog and DOM. */
const LibraryView = (() => {
  function create(size = 48) {
    let signature = null, limit = size, items = [];
    return {
      reset(next, context = '') {
        const key = context + '|' + next.map(g => g.join(',')).join(';');
        if (key !== signature) { signature = key; limit = size; }
        items = next;
        return this.visible();
      },
      visible() { return items.slice(0, limit); },
      more() { limit = Math.min(items.length, limit + size); return this.visible(); },
      ensure(id) {
        const index = items.findIndex(g => g.includes(id));
        if (index >= limit) limit = Math.ceil((index + 1) / size) * size;
        return index >= 0;
      },
      get remaining() { return Math.max(0, items.length - limit); },
      get count() { return Math.min(items.length, limit); }
    };
  }
  function dateDay(value) {
    const match = /^(\d{4})[:-](\d{2})[:-](\d{2})(?:$|[ T])/.exec(value || '');
    if (!match) return '';
    const day = `${match[1]}-${match[2]}-${match[3]}`;
    const d = new Date(day + 'T12:00:00Z');
    return Number.isFinite(d.valueOf()) && d.toISOString().slice(0, 10) === day ? day : '';
  }
  function videoURL(asset, protocol) {
    if (protocol !== 'file:' || asset?.isLivePhoto || asset?.type !== 'video') return '';
    try { const url = new URL(asset.originalURL || ''); return url.protocol === 'file:' ? url.href : ''; } catch { return ''; }
  }
  return { create, dateDay, videoURL };
})();
if (typeof module !== 'undefined' && module.exports) module.exports = LibraryView;

if (typeof A !== 'undefined' && typeof LIBRARY !== 'undefined') {
  (() => {
    tr('samplephotos','照片与视频','Photos & videos','Fotos & Videos');
    tr('rawminute','当天归属已确认；原文件的具体分钟尚未独立确认。','The day is confirmed; the original minute-level time has not been independently verified.','Der Tag ist bestätigt; die genaue Uhrzeit der Originaldatei ist nicht unabhängig bestätigt.');
    const configGroups = LIBRARY.groups || {};
    const usesJourneyKeys = Object.hasOwn(groups, 'journeyA') || Object.hasOwn(groups, 'journeyB');
    Object.assign(groups, configGroups);
    if (usesJourneyKeys && configGroups.china) groups.journeyA = configGroups.china;
    if (usesJourneyKeys && configGroups.morocco) groups.journeyB = configGroups.morocco;
    for (const [id, note] of Object.entries(LIBRARY.sourceNotes || {})) if (!sourceNotes[id]) sourceNotes[id] = note;
    for (const id of LIBRARY.favoriteIds || []) if (byId[id]) S.favorites.add(id);
    for (const a of A) { a.tags ||= []; a.dataURI ||= a.previewURL || ''; }
    const previousCurrentGroups = currentGroups;
    currentGroups = function () {
      if (S.trip !== 'all') return groups[S.trip] || previousCurrentGroups();
      const seen = new Set();
      const candidates=Object.values(configGroups).flat(),covered=new Set(candidates.flat());
      // Sources imported after boot must also be reachable from All photos.
      for(const asset of A)if(!covered.has(asset.id))candidates.push([asset.id]);
      return candidates.filter(g => g?.length && byId[g[0]] && !seen.has(g[0]) && seen.add(g[0]));
    };
    shotDay = id => LibraryView.dateDay(byId[id]?.date) || LibraryView.dateDay(byId[id]?.confirmedDateDay);
    shotOrder = id => shotDay(id) + (byId[id]?.date?.slice(10) || '');
    shotLabel = id => {
      const a = byId[id], day = shotDay(id);
      if (!day) return a?.confirmedDateLabel || t('dateunknownyear');
      return S.lang === 'zh' ? Number(day.slice(5, 7)) + '月' + Number(day.slice(8)) + '日' : new Intl.DateTimeFormat(S.lang === 'de' ? 'de-DE' : 'en-GB', {day:'numeric',month:'short',timeZone:'UTC'}).format(new Date(day+'T12:00:00Z'));
    };
    const previousCard = card;
    const previousDetails = details;
    details=function(id,viewer=false){
      const html=previousDetails(id,viewer);if(byId[id]?.timeConfidence!=='raw-minute-unconfirmed')return html;
      const at=html.lastIndexOf('</div>');return html.slice(0,at)+`<p class="library-time-note">${esc(t('rawminute'))}</p>`+html.slice(at);
    };
    card = function (g) {
      let html = previousCard(g), a = byId[cover(g)];
      if (!shotDay(a.id)) html = html.replace('<span class="date"></span>', '<span class="date">' + esc(shotLabel(a.id)) + '</span>');
      if (a.type === 'video' && !a.isLivePhoto) {
        const duration = Number(a.durationSeconds ?? a.duration);
        const label = Number.isFinite(duration) ? ` ${Math.floor(duration/60)}:${String(Math.floor(duration%60)).padStart(2,'0')}` : '';
        html = html.replace('</div>', `<span class="library-video-badge" aria-label="${S.lang==='zh'?'视频':'Video'}">▶${label}</span></div>`);
      }
      return html;
    };
    const batch = LibraryView.create(48);
    let sentinelObserver = null, pendingEnsure = null;
    const context = () => JSON.stringify([S.trip,S.mode,S.view,S.sort,S.search,S.location,S.sublocation,S.type,S.from,S.to,S.onlyFavorites,S.customLocation]);
    const finish = () => { renderMap(); if (typeof observeProductPhotos === 'function') observeProductPhotos(); };
    const moreLabel = () => S.lang === 'zh' ? '加载更多' : S.lang === 'de' ? 'Mehr laden' : 'Load more';
    function addSentinel(el) {
      if (!batch.remaining) return;
      const footer = document.createElement('div');
      footer.className = 'library-load-more';
      const button = document.createElement('button');
      button.type = 'button'; button.className = 'outline'; button.textContent = moreLabel();
      button.addEventListener('click', appendBatch); footer.append(button);
      const sentinel = document.createElement('div'); sentinel.className='library-sentinel'; sentinel.setAttribute('aria-hidden','true');footer.append(sentinel);el.append(footer);
      if (typeof IntersectionObserver !== 'undefined') {
        sentinelObserver = new IntersectionObserver(entries => { if(entries.some(e=>e.isIntersecting)) appendBatch(); }, {rootMargin:'240px 0px'});
        sentinelObserver.observe(sentinel);
      }
    }
    function appendBatch() {
      sentinelObserver?.disconnect();
      const el=$('gallery'), before=batch.count, visible=batch.more();
      el.querySelector('.library-load-more')?.remove();
      el.insertAdjacentHTML('beforeend', visible.slice(before).map(card).join(''));
      addSentinel(el); finish();
    }
    renderGallery = function () {
      sentinelObserver?.disconnect();
      const el=$('gallery');
      if (S.view==='empty' || S.view==='loading') {
        batch.reset([],context()); S.focus=null;
        el.innerHTML = S.view==='empty' ? emptyView(false) : `<div class="loading-note"><div><strong><span class="spinner"></span>${t('preparing')}</strong><p>${t('preparingbody')}</p></div>${btn(t('showready'),'ready','quiet-button')}</div>`;
        finish(); return;
      }
      const items=filtered();batch.reset(items,context());
      if(pendingEnsure){batch.ensure(pendingEnsure);pendingEnsure=null;}
      if(!items.some(g=>g.includes(S.focus))) S.focus=items.length?cover(items[0]):null;
      if(!items.length){
        el.innerHTML= S.customLocation && !placeStore.get(S.customLocation)?.photoIds.length ? `<section class="empty"><h2>${t('cpempty')}</h2><p>${t('cpemptybody')}</p>${btn(t('allareas'),'location:all','solid')}</section>` : emptyView(true);
      } else if(S.mode==='timeline') {
        const days=new Map();for(const g of items){const day=shotDay(cover(g));if(!days.has(day))days.set(day,[]);days.get(day).push(g);}
        el.innerHTML=[...days.values()].map(gs=>{const id=cover(gs[0]);return `<section class="timeline-item"><small>${esc(shotLabel(id))}</small><h2>${esc(place(id))}</h2><p>${t('timelinehint')}</p><div class="timeline-photos">${gs.map(g=>btn(img(cover(g)),'jump:'+cover(g))).join('')}</div></section>`;}).join('');
      } else { el.innerHTML=batch.visible().map(card).join('');addSentinel(el); }
      finish();
    };
    const previousChoose = chooseMapPhoto;
    chooseMapPhoto = function (id) {pendingEnsure=id;previousChoose(id);pendingEnsure=null;};
    document.addEventListener('click',e=>{
      const target=e.target.closest('[data-action]');
      if(!target?.dataset.action.startsWith('jump:'))return;
      e.preventDefault();e.stopImmediatePropagation();chooseMapPhoto(target.dataset.action.slice(5));
    },true);
    const previousViewer=openViewer;
    openViewer=function(id){
      const a=byId[id];if(a.type!=='video'||a.isLivePhoto){previousViewer(id);return;}
      S.focus=id;renderMap();const v=$('viewer');v.dataset.photo=id;
      v.innerHTML=`${btn(icon('close'),'closeviewer','close-viewer')}<div class="library-video-stage"></div><div class="viewer-bottom">${viewerBottom(id)}</div>`;
      const url=LibraryView.videoURL(a,location.protocol),stage=v.querySelector('.library-video-stage');
      if(url){const video=document.createElement('video');video.controls=true;video.preload='none';video.playsInline=true;video.src=url;if(a.previewURL||a.dataURI)video.poster=a.previewURL||a.dataURI;stage.append(video);}
      else {stage.innerHTML=img(id);const note=document.createElement('p');note.textContent=S.lang==='zh'?'请在本地打开此页面播放原视频。':'Open this page locally to play the original video.';stage.append(note);}
      v.showModal();
      if(typeof Motion!=='undefined')Motion.enterDialog(v);
    };
    $('viewer').addEventListener('close',()=>{$('viewer').querySelectorAll('video').forEach(video=>{video.pause();video.removeAttribute('src');video.load();});});
    window.addEventListener('pagehide',()=>sentinelObserver?.disconnect());
  })();
}
