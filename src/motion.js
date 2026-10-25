/* One motion owner: short, interruptible transitions; no timers delaying state. */
const Motion = (() => {
  const preference = matchMedia('(prefers-reduced-motion: reduce)');
  const active = new Set(), layout = new Set(), panels = new WeakMap(), owners = new WeakMap();
  let ready = false, depth = 0, quiet = false, scheduled = 0;
  const duration = {layout: 220, enter: 180, panel: 240, dialog: 180};
  const easing = 'cubic-bezier(.2,.75,.25,1)';
  const allowed = () => ready && !quiet && !preference.matches;
  const visible = r => r.width > 0 && r.height > 0 && r.bottom > -80 && r.top < innerHeight + 120;
  function play(node, frames, options = {}, bucket = layout) {
    if (!node?.animate || !allowed()) return null;
    owners.get(node)?.cancel();
    const animation = node.animate(frames, {duration: duration.layout, easing, ...options});
    owners.set(node,animation);
    active.add(animation); bucket?.add(animation);
    const cleanup = () => {active.delete(animation); bucket?.delete(animation);if(owners.get(node)===animation)owners.delete(node);};
    animation.finished.then(cleanup, cleanup);
    return animation;
  }
  function snapshot() {
    const result = new Map();
    for (const node of document.querySelectorAll('.card[data-card], .timeline-item, #map-panel, #filter-panel, #place-editor')) {
      if (node.hidden) continue;
      const r = node.getBoundingClientRect();
      if (!visible(r)) continue;
      const key = node.dataset.card ? 'photo:' + node.dataset.card : node.dataset.day ? 'day:' + node.dataset.day : node.id;
      if (key) result.set(key, {node, r});
      if (result.size >= 30) break;
    }
    return result;
  }
  function cancelLayout() {for (const animation of [...layout]) animation.cancel();layout.clear();}
  function run(fn) {
    if (depth) return fn();
    const focused=document.activeElement;
    const restoreFocus=()=>{
      if(!focused||focused.isConnected)return;
      const current=document.activeElement;
      if(current?.isConnected&&current!==document.body&&current!==document.documentElement)return;
      const next=focused.id?document.getElementById(focused.id):focused.dataset?.action?[...document.querySelectorAll('[data-action]')].find(n=>n.dataset.action===focused.dataset.action):null;
      if(next&&!next.disabled&&!next.closest('[hidden]'))next.focus({preventScroll:true});
    };
    if (!allowed()) {try{return fn();}finally{restoreFocus();}}
    if (scheduled) {cancelAnimationFrame(scheduled);scheduled = 0;}
    const before = snapshot();
    cancelLayout();
    depth++;
    let result;
    try {result = fn();} finally {depth--;restoreFocus();}
    scheduled = requestAnimationFrame(() => {
      scheduled = 0;
      const after = snapshot();
      for (const [key, {node, r}] of after) {
        const old = before.get(key)?.r;
        if (old) {
          const dx = old.left-r.left, dy = old.top-r.top, sx=old.width/r.width, sy=old.height/r.height;
          if (Math.abs(dx)+Math.abs(dy)+Math.abs(old.width-r.width)+Math.abs(old.height-r.height)<.5) continue;
          // Do not scale an active editor while the person is typing in it.
          const editing = node.contains(document.activeElement) && document.activeElement.matches('input,textarea');
          play(node,[{transformOrigin:'top left',transform:`translate(${dx}px,${dy}px) scale(${editing?1:sx},${editing?1:sy})`},{transformOrigin:'top left',transform:'none'}]);
        } else {
          play(node,[{opacity:0,transform:'translateY(10px)'},{opacity:1,transform:'none'}],{duration:duration.enter});
        }
      }
    });
    return result;
  }
  function wrap(fn) {return function(...args){return run(()=>fn.apply(this,args));};}
  function reveal(node, opening, remove = false) {
    let wrapper = node.classList.contains('motion-reveal') ? node : node.parentElement?.classList.contains('motion-reveal') ? node.parentElement : null;
    if (!wrapper) {wrapper=document.createElement('div');wrapper.className='motion-reveal';node.before(wrapper);wrapper.append(node);}
    const previous=panels.get(wrapper), from=previous ? wrapper.getBoundingClientRect().height : opening ? 0 : wrapper.getBoundingClientRect().height;
    if (previous) previous.cancel();
    wrapper.style.height='auto';wrapper.hidden=false;wrapper.inert=!opening;
    wrapper.dataset.closing=String(!opening);
    const target=opening?wrapper.getBoundingClientRect().height:0;
    const finish=()=>{wrapper.style.removeProperty('height');wrapper.style.removeProperty('overflow');if(!opening){if(remove)wrapper.remove();else wrapper.hidden=true;}};
    if(!allowed()||!wrapper.animate){panels.delete(wrapper);finish();return;}
    wrapper.style.overflow='hidden';
    const animation=play(wrapper,[{height:from+'px',opacity:opening?.5:1},{height:target+'px',opacity:opening?1:0}],{duration:duration.panel},null);
    panels.set(wrapper,animation);
    animation.finished.then(()=>{if(panels.get(wrapper)===animation){panels.delete(wrapper);finish();}},()=>{});
  }
  function enterDialog(dialog) {play(dialog,[{opacity:0,transform:'translateY(12px) scale(.985)'},{opacity:1,transform:'none'}],{duration:duration.dialog},null);}
  function closeDialog(dialog) {
    if(!dialog.open)return;
    const animation=play(dialog,[{opacity:1,transform:'none'},{opacity:0,transform:'translateY(8px) scale(.99)'}],{duration:140},null);
    if(animation) animation.finished.then(()=>{if(dialog.open)dialog.close();},()=>{});else dialog.close();
  }
  function ink(node, options = {}) {
    if (!node || node.dataset.inkPlayed === 'true') return null;
    node.dataset.inkPlayed = 'true';
    return play(node,[{opacity:0,filter:'blur(5px)',transform:'translateY(3px)'},{opacity:1,filter:'blur(0)',transform:'none'}],{duration:options.duration ?? 360,easing:'cubic-bezier(.2,.75,.25,1)'},null);
  }
  function feedback(node, options = {}) {
    if (!node) return;
    node.classList.remove('moments-success');
    void node.offsetWidth;
    node.classList.add('moments-success');
    clearTimeout(node.__momentsFeedbackTimer);
    node.__momentsFeedbackTimer = setTimeout(() => node.classList.remove('moments-success'), options.hideAfter ?? 2500);
  }
  document.addEventListener('input',()=>{quiet=true;queueMicrotask(()=>quiet=false);},true);
  preference.addEventListener?.('change',()=>{if(preference.matches){cancelLayout();for(const a of [...active])a.finish();}});
  return {run,wrap,reveal,ink,feedback,enterDialog,closeDialog,play,start(){ready=true;},get reduced(){return preference.matches;}};
})();
