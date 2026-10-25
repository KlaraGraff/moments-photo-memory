/* Two-endpoint, opt-in road routing. Coordinates and successful results stay in memory. */
const RoadRouting = (() => {
  const BASE = 'https://routing.openstreetmap.de';
  const GRAPHS = {car: 'routed-car', bike: 'routed-bike', foot: 'routed-foot'};
  const error = code => Object.assign(new Error(code), {code});
  const coordinate = p => p && typeof p.latitude === 'number' && Number.isFinite(p.latitude) &&
    Math.abs(p.latitude) <= 90 && typeof p.longitude === 'number' && Number.isFinite(p.longitude) && Math.abs(p.longitude) <= 180;
  const clone = value => JSON.parse(JSON.stringify(value));
  function create({fetchImpl = globalThis.fetch, now = Date.now, sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
    timeoutMs = 15000, minIntervalMs = 1100, onState} = {}) {
    let active = null, lastStart = -Infinity;
    const cache = new Map();
    function cancel() { if (active) active.abort('aborted'); }
    async function plan({start, end, mode = 'car', consent, signal} = {}) {
      cancel();
      if (consent !== true) throw error('consent-required');
      if (!Object.hasOwn(GRAPHS, mode)) throw error('invalid-mode');
      if (!coordinate(start) || !coordinate(end) || (start.latitude === end.latitude && start.longitude === end.longitude)) throw error('invalid-points');
      // Snapshot only coordinates so caller edits during a queued request cannot change its destination.
      start = {latitude:start.latitude, longitude:start.longitude};
      end = {latitude:end.latitude, longitude:end.longitude};
      const controller = new AbortController();
      let rejectAbort, timer, abortCode;
      const aborted = new Promise((_, reject) => { rejectAbort = reject; });
      const operation = {abort(code) {
        if (abortCode) return;
        abortCode = code; controller.abort(); rejectAbort(error(code));
      }};
      active = operation;
      const externalAbort = () => operation.abort('aborted');
      if (signal) signal.addEventListener('abort', externalAbort, {once:true});
      if (signal?.aborted) externalAbort();
      const check = () => { if (abortCode || active !== operation) throw error(abortCode || 'aborted'); };
      const emit = state => { check(); if (onState) onState(state); };
      const key = JSON.stringify([mode, start.longitude, start.latitude, end.longitude, end.latitude]);
      try {
        return await Promise.race([aborted, (async () => {
          check();
          if (cache.has(key)) {
            const result = cache.get(key); cache.delete(key); cache.set(key, result);
            emit({status:'success', cached:true}); return clone(result);
          }
          emit({status:'loading'});
          const wait = Math.max(0, lastStart + minIntervalMs - now());
          if (wait) await Promise.race([sleep(wait), aborted]);
          check(); lastStart = now();
          timer = setTimeout(() => operation.abort('timeout'), timeoutMs);
          const points = `${start.longitude},${start.latitude};${end.longitude},${end.latitude}`;
          const url = `${BASE}/${GRAPHS[mode]}/route/v1/driving/${points}?overview=full&geometries=geojson&steps=false&alternatives=false`;
          let response;
          try { response = await Promise.race([fetchImpl(url, {signal:controller.signal, credentials:'omit', cache:'no-store', redirect:'error', referrerPolicy:'strict-origin-when-cross-origin'}), aborted]); }
          catch (e) { check(); throw error('network'); }
          check();
          if (!response) throw error('invalid-response');
          if (response.status === 429) throw error('rate-limit');
          if (typeof response.json !== 'function') throw error(response.ok ? 'invalid-response' : 'network');
          let payload;
          try { payload = await Promise.race([response.json(), aborted]); }
          catch (e) { check(); throw error(response.ok ? 'invalid-response' : 'network'); }
          check();
          if (payload?.code === 'NoRoute' || payload?.code === 'NoSegment') throw error('no-route');
          if (!response.ok) throw error('network');
          const route = payload?.routes?.[0], coords = route?.geometry?.coordinates;
          if (payload?.code !== 'Ok' || route?.geometry?.type !== 'LineString' || !Array.isArray(coords) || coords.length < 2 || coords.length > 100000 ||
            coords.some(p => !Array.isArray(p) || p.length !== 2 || !coordinate({longitude:p[0], latitude:p[1]})) ||
            typeof route.distance !== 'number' || !Number.isFinite(route.distance) || route.distance < 0 ||
            typeof route.duration !== 'number' || !Number.isFinite(route.duration) || route.duration < 0) throw error('invalid-response');
          const result = {geometry:{type:'LineString', coordinates:coords.map(p => [...p])}, distance:route.distance, duration:route.duration,
            waypointDistances: Array.isArray(payload.waypoints) ? payload.waypoints.slice(0, 2).map(p => typeof p?.distance === 'number' && Number.isFinite(p.distance) && p.distance >= 0 ? p.distance : null) : [],
            provider:'FOSSGIS / OSRM', mode};
          check(); cache.set(key, clone(result));
          if (cache.size > 20) cache.delete(cache.keys().next().value);
          emit({status:'success', cached:false}); return result;
        })()]);
      } finally {
        clearTimeout(timer);
        if (signal) signal.removeEventListener('abort', externalAbort);
        if (active === operation) active = null;
      }
    }
    return {plan, cancel, clearCache() { cache.clear(); }};
  }
  return {create};
})();
