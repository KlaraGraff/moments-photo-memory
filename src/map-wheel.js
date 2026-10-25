/* Pinned Leaflet 1.9.4: only this map's wheel handler is replaced. */
const MapWheel = (() => {
  const KEY = 'moments-map-wheel-reversed-v1', instances = new WeakMap();
  // WheelEvent has no standard deviceType. Ambiguous pixel streams stay uninverted.
  function classify(e) {
    if (e.ctrlKey) return 'pinch';
    if ((e.deltaX || 0) !== 0 || (e.deltaZ || 0) !== 0 || !Number.isInteger(e.deltaY)) return 'trackpad';
    if (e.deltaMode === 1 || e.deltaMode === 2) return 'mouse';
    const legacy = e.wheelDeltaY ?? e.wheelDelta;
    if (Number.isInteger(legacy) && legacy !== 0 && legacy % 120 === 0) {
      const steps = Math.abs(legacy / 120), dy = Math.abs(e.deltaY);
      if ([1, 3, 100, 120].some(q => Math.abs(dy - q * steps) < 0.01)) return 'mouse';
    }
    return 'trackpad';
  }
  function create(map, {storage, storageKey = KEY, onStatus} = {}) {
    if (instances.has(map)) return instances.get(map);
    const h = map?.scrollWheelZoom, container = map?.getContainer?.();
    const available = globalThis.L?.version === '1.9.4' && globalThis.L?.Browser?.any3d === true && !!h &&
      ['addHooks','removeHooks','enabled','disable','enable'].every(k => typeof h[k] === 'function') &&
      ['_move','_moveStart','_moveEnd','_limitZoom','project','unproject','getCenter','getZoom','getSize','mouseEventToContainerPoint','on','off','fire','_stop'].every(k => typeof map[k] === 'function') &&
      !!container?.addEventListener && !!container?.removeEventListener && map.options?.zoomSnap === 0;
    let reversed = false, persistent = false, disposed = false, writable = !!storage;
    let code = available ? 'memory' : 'unsupported';
    if (available && storage) {
      try {
        const raw = storage.getItem(storageKey);
        if (raw === 'true' || raw === 'false') reversed = raw === 'true';
        else if (raw !== null) { writable = false; code = 'invalid-data'; }
        if (writable) { persistent = true; code = 'ready'; }
      } catch (_) { writable = false; code = 'read-error'; }
    }
    let frame = null, active = false, internal = false, target = 0, anchor, cursor, last = 0;
    let source = null, trackpadUntil = 0, gesture = false, gestureScale = 1, attached = false;
    const originalAdd = h?.addHooks, originalRemove = h?.removeHooks;
    const ownAdd = h && Object.hasOwn(h,'addHooks'), ownRemove = h && Object.hasOwn(h,'removeHooks');
    const doc = container?.ownerDocument;
    function nativePending() {
      if (!h) return;
      if (h._timer !== undefined) clearTimeout(h._timer);
      h._timer = undefined; h._delta = 0; h._startTime = null;
    }
    function guarded(fn) { internal = true; try { return fn(); } finally { internal = false; } }
    function finish() {
      if (frame !== null) cancelAnimationFrame(frame);
      frame = null;
      if (active) {
        active = false;
        guarded(() => { map.fire('zoom'); map._moveEnd(true); });
      }
      container?.classList?.remove('moments-wheel-active'); last = 0;
    }
    function external() { if (!internal) finish(); }
    function tick(now) {
      frame = null;
      if (!active) return;
      const current = map.getZoom();
      const reduced = globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
      const dt = last ? Math.min(64, Math.max(1, now - last)) : 16;
      last = now;
      const remaining = target - current;
      const z = reduced || Math.abs(remaining) < 0.0005 ? target : current + remaining * (1 - Math.exp(-dt / 65));
      const p = map.project(anchor,z), size = map.getSize();
      const center = map.unproject({x:p.x - cursor.x + size.x / 2, y:p.y - cursor.y + size.y / 2},z);
      guarded(() => map._move(center,z,{pinch:true}));
      if (z === target) finish(); else frame = requestAnimationFrame(tick);
    }
    function add(delta,e,nextSource) {
      if (!Number.isFinite(delta) || !delta) return;
      if (active && source !== nextSource) finish();
      if (!active) {
        guarded(() => {
          // Public stop() fires viewreset with zoomSnap:0, rebuilding tile state.
          map._stop();
          if (map._animatingZoom && typeof map._onZoomTransitionEnd === 'function') map._onZoomTransitionEnd();
        });
        target = map.getZoom();
      }
      source = nextSource;
      cursor = map.mouseEventToContainerPoint(e);
      // Re-anchor at the current camera when the pointer moves between events.
      const size = map.getSize(), p = map.project(map.getCenter(),map.getZoom());
      anchor = map.unproject({x:p.x + cursor.x - size.x / 2,y:p.y + cursor.y - size.y / 2},map.getZoom());
      target = map._limitZoom(Math.max(map.getZoom()-6,Math.min(map.getZoom()+6,target+delta)));
      if (!active) {
        active = true; container.classList?.add('moments-wheel-active');
        guarded(() => map._moveStart(true,false));
      }
      if (frame === null) frame = requestAnimationFrame(tick);
    }
    function wheel(e) {
      e.preventDefault(); e.stopPropagation();
      if (gesture) return;
      const now = performance.now();
      let kind = classify(e);
      if (kind === 'trackpad' || kind === 'pinch') trackpadUntil = now + 180;
      else if (now < trackpadUntil) kind = 'trackpad';
      let delta;
      if (kind === 'mouse') {
        const legacy = e.wheelDeltaY ?? e.wheelDelta;
        const steps = e.deltaMode === 1 ? Math.abs(e.deltaY)/3 : e.deltaMode === 2 ? 1 : Math.abs(legacy)/120;
        delta = -Math.sign(e.deltaY) * Math.min(8,steps) * 0.25 * (reversed ? -1 : 1);
      } else delta = -e.deltaY * (e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? map.getSize().y : 1) / (kind === 'pinch' ? 100 : 240);
      add(delta,e,kind);
    }
    function gestureStart(e) { e.preventDefault(); finish(); gesture = true; gestureScale = e.scale || 1; }
    function gestureChange(e) {
      if (!gesture || !(e.scale > 0)) return;
      e.preventDefault(); add(Math.log2(e.scale/gestureScale),e,'gesture'); gestureScale = e.scale;
    }
    function gestureEnd(e) { e.preventDefault(); gesture = false; }
    const options = {passive:false};
    function attach() {
      nativePending();
      if (attached) return;
      attached = true;
      container.addEventListener('wheel',wheel,options);
      container.addEventListener('gesturestart',gestureStart,options);
      container.addEventListener('gesturechange',gestureChange,options);
      container.addEventListener('gestureend',gestureEnd,options);
    }
    function detach() {
      finish(); nativePending(); gesture = false; source = null; trackpadUntil = 0;
      if (!attached) return;
      attached = false;
      container.removeEventListener('wheel',wheel,options);
      container.removeEventListener('gesturestart',gestureStart,options);
      container.removeEventListener('gesturechange',gestureChange,options);
      container.removeEventListener('gestureend',gestureEnd,options);
    }
    function visibility() { if (doc.hidden) { finish(); gesture = false; } }
    const api = {
      get available() { return available && !disposed; },
      get reversed() { return reversed; }, get persistent() { return persistent; }, get status() { return code; },
      setReversed(value) {
        if (!available || disposed) return false;
        const next = value === true;
        if (next !== reversed) { finish(); nativePending(); reversed = next; }
        if (writable) {
          try { storage.setItem(storageKey,String(reversed)); persistent = true; code = 'ready'; }
          catch (_) { writable = false; persistent = false; code = 'write-error'; }
        }
        onStatus?.({available:true,reversed,persistent,code}); return true;
      },
      dispose() {
        if (disposed) return;
        disposed = true;
        if (available) {
          const enabled = h.enabled();
          detach();
          if (h.addHooks === attach && h.removeHooks === detach) {
            if (enabled) h.disable();
            if (ownAdd) h.addHooks = originalAdd; else delete h.addHooks;
            if (ownRemove) h.removeHooks = originalRemove; else delete h.removeHooks;
            if (enabled) h.enable();
          }
          map.off('movestart zoomstart dragstart',external);
          map.off('unload',api.dispose);
          doc?.removeEventListener('visibilitychange',visibility);
        }
        instances.delete(map);
      }
    };
    if (available) {
      const enabled = h.enabled();
      if (enabled) h.disable();
      nativePending(); h.addHooks = attach; h.removeHooks = detach;
      if (enabled) h.enable();
      map.on('movestart zoomstart dragstart',external); map.on('unload',api.dispose);
      doc?.addEventListener('visibilitychange',visibility);
    }
    instances.set(map,api); return api;
  }
  return {create,classify,storageKey:KEY};
})();
