/// The page a friend's browser shows after scanning the QR code: their
/// photos grouped by day, a full-screen viewer (swipe, zoom, download,
/// share, slideshow), picking photos to download as a ZIP, and a PIN prompt
/// when the share is protected. Talks to the LocalSend download API
/// (`prepare-download` / `download`) plus our `/thumb`, `/preview` and
/// `/zip` routes.
const webSharePage = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#0F0E12">
<title>Your photos · ShareBro</title>
<style>
:root{--accent:#D9432B;--on-accent:#fff;--bg:#F6F5F8;--ink:#1A1820;--muted:#5E5A66;--card:#fff;
--glass:rgba(255,255,255,.7);--rim:rgba(255,255,255,.8);--line:rgba(26,24,32,.1);--sel:#D9432B;
--ease:cubic-bezier(.2,.8,.2,1);--cols:4}
@media (prefers-color-scheme:dark){:root{--accent:#FF8A6B;--on-accent:#2A0D06;--bg:#0F0E12;--ink:#F2EFF5;
--muted:#A9A3B3;--card:#1A1820;--glass:rgba(28,26,34,.66);--rim:rgba(255,255,255,.12);--line:rgba(255,255,255,.1);--sel:#FF8A6B}}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0}
body{font:16px/1.45 system-ui,-apple-system,Roboto,sans-serif;color:var(--ink);background:var(--bg);min-height:100vh}
body::before{content:"";position:fixed;inset:-20%;z-index:-1;pointer-events:none;
background:radial-gradient(40% 35% at 15% 10%,rgba(217,67,43,.26),transparent 70%),
radial-gradient(35% 30% at 90% 20%,rgba(110,91,255,.24),transparent 70%),
radial-gradient(40% 35% at 55% 70%,rgba(43,181,166,.2),transparent 70%);animation:drift 26s ease-in-out infinite alternate}
@keyframes drift{to{transform:translate(4%,3%) rotate(6deg)}}
.glass{background:var(--glass);border:1px solid var(--rim);backdrop-filter:blur(20px) saturate(1.4);-webkit-backdrop-filter:blur(20px) saturate(1.4)}
button,.btn{appearance:none;border:0;border-radius:999px;padding:10px 16px;min-height:44px;font:inherit;font-weight:650;cursor:pointer;
display:inline-flex;align-items:center;gap:8px;text-decoration:none;color:var(--ink);background:var(--card);
border:1px solid var(--line);transition:transform .12s var(--ease),background .2s,opacity .2s}
button:active,.btn:active{transform:scale(.95)}
.primary{background:var(--accent);color:var(--on-accent);border-color:transparent}
.icon{width:44px;height:44px;padding:0;justify-content:center}
svg{width:20px;height:20px;flex:none}
header{position:sticky;top:0;z-index:5;padding:12px 16px;padding-top:max(12px,env(safe-area-inset-top));border-width:0 0 1px}
.top{display:flex;align-items:center;gap:12px}
h1{margin:0;font-size:24px;letter-spacing:-.4px;font-weight:800;flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sub{color:var(--muted);font-size:14px}
.bar{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px;align-items:center}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:999px;overflow:hidden;background:var(--card)}
.seg button{border:0;border-radius:0;min-height:40px;padding:8px 12px;background:transparent}
.seg button.on{background:var(--accent);color:var(--on-accent)}
main{padding:4px 4px 120px}
.day{position:sticky;top:var(--hh,120px);z-index:2;display:flex;align-items:center;justify-content:space-between;
padding:14px 8px 8px;font-weight:750;background:linear-gradient(var(--bg) 70%,transparent)}
.day button{min-height:34px;padding:4px 12px;font-size:13px}
.grid{display:grid;grid-template-columns:repeat(var(--cols),1fr);gap:3px}
.tile{position:relative;aspect-ratio:1;overflow:hidden;border-radius:6px;background:var(--card);cursor:pointer;
transition:transform .18s var(--ease),border-radius .18s}
.tile img{width:100%;height:100%;object-fit:cover;display:block;opacity:0;transition:opacity .35s var(--ease),transform .5s var(--ease);transform:scale(1.04)}
.tile img.on{opacity:1;transform:none}
.tile .check{position:absolute;top:6px;right:6px;width:26px;height:26px;border-radius:50%;border:2px solid #fff;
background:rgba(0,0,0,.25);display:none;align-items:center;justify-content:center;transition:transform .15s var(--ease)}
.selecting .tile .check{display:flex}
.tile.sel{transform:scale(.9);border-radius:14px}
.tile.sel .check{background:var(--sel);border-color:var(--sel);transform:scale(1.1)}
.tile.sel .check::after{content:"";width:10px;height:6px;border:solid #fff;border-width:0 0 2.5px 2.5px;transform:rotate(-45deg) translate(1px,-1px)}
.selbar{position:fixed;left:50%;bottom:max(16px,env(safe-area-inset-bottom));transform:translate(-50%,140%);z-index:6;
display:flex;gap:8px;align-items:center;padding:8px;border-radius:999px;transition:transform .35s var(--ease)}
.selbar.show{transform:translate(-50%,0)}
.selbar .n{padding:0 10px;font-weight:700;white-space:nowrap}
.center{min-height:70vh;display:grid;place-items:center;text-align:center;padding:24px}
.card{border-radius:28px;padding:28px;max-width:380px;width:100%}
input{width:100%;font:inherit;font-size:24px;letter-spacing:8px;text-align:center;padding:12px;border-radius:16px;
border:1px solid var(--line);background:var(--card);color:var(--ink);margin:16px 0}
.err{color:#E5484D;min-height:1.4em}
.toast{position:fixed;left:50%;top:max(16px,env(safe-area-inset-top));transform:translate(-50%,-160%);z-index:20;
padding:10px 18px;border-radius:999px;transition:transform .35s var(--ease);font-weight:600}
.toast.show{transform:translate(-50%,0)}
/* Full-screen viewer */
.lb{position:fixed;inset:0;z-index:10;background:rgba(0,0,0,.92);display:flex;flex-direction:column;opacity:0;pointer-events:none;
transition:opacity .25s var(--ease);touch-action:none;color:#fff}
.lb.open{opacity:1;pointer-events:auto}
.lb .stage{flex:1;position:relative;overflow:hidden}
.lb .frame{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;transition:transform .32s var(--ease),opacity .32s}
.lb .frame img{max-width:100%;max-height:100%;object-fit:contain;transform-origin:center;transition:transform .2s var(--ease),filter .3s;user-select:none;-webkit-user-drag:none}
.lb .frame img.loading{filter:blur(12px)}
.lb .tools{position:absolute;left:0;right:0;top:0;display:flex;align-items:center;gap:8px;padding:10px 12px;padding-top:max(10px,env(safe-area-inset-top));
background:linear-gradient(rgba(0,0,0,.55),transparent);transition:opacity .25s;z-index:2}
.lb .tools .count{flex:1;font-weight:650}
.lb button{background:rgba(255,255,255,.14);color:#fff;border-color:rgba(255,255,255,.18)}
.lb .nav{position:absolute;top:50%;transform:translateY(-50%);z-index:2}
.lb .prev{left:12px}.lb .next{right:12px}
.lb .strip{display:flex;gap:4px;overflow-x:auto;padding:8px 8px max(10px,env(safe-area-inset-bottom));scrollbar-width:none;
background:linear-gradient(transparent,rgba(0,0,0,.6));transition:opacity .25s}
.lb .strip img{width:52px;height:52px;object-fit:cover;border-radius:8px;opacity:.5;flex:none;cursor:pointer;transition:opacity .2s,transform .2s var(--ease)}
.lb .strip img.cur{opacity:1;transform:scale(1.08);outline:2px solid #fff}
.lb .info{position:absolute;left:12px;right:12px;bottom:12px;z-index:3;padding:14px 16px;border-radius:18px;font-size:14px;
transform:translateY(130%);transition:transform .3s var(--ease);color:var(--ink)}
.lb .info.show{transform:none}
.lb .progress{position:absolute;left:0;top:0;height:3px;background:var(--accent);width:0;z-index:3}
.lb.chrome-off .tools,.lb.chrome-off .strip,.lb.chrome-off .nav{opacity:0;pointer-events:none}
.lb .sel-on{background:var(--accent);color:var(--on-accent)}
@media (min-width:700px){:root{--cols:6}}@media (min-width:1100px){:root{--cols:8}}
@media (hover:none){.lb .nav{display:none}}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
</style>
</head>
<body>
<div id="app"><div class="center"><div class="sub">Loading your photos…</div></div></div>
<div class="toast glass" id="toast"></div>
<script>
const I = {
  down:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11m0 0l-4-4m4 4l4-4M5 20h14"/></svg>',
  share:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 15V3m0 0L8 7m4-4l4 4M5 12v7a2 2 0 002 2h10a2 2 0 002-2v-7"/></svg>',
  close:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  left:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 5l-7 7 7 7"/></svg>',
  right:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 5l7 7-7 7"/></svg>',
  info:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.01"/></svg>',
  play:'<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>',
  pause:'<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 5h4v14H7zM13 5h4v14h-4z"/></svg>',
  check:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7"/></svg>',
  select:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="16" rx="4"/><path d="M8.5 12l2.5 2.5L15.5 9.5"/></svg>',
};
const params = new URLSearchParams(location.search);
const session = params.get('s');
let pin = sessionStorage.getItem('pin-' + session) || '';
const app = document.getElementById('app');
const q = (o) => new URLSearchParams(Object.assign({ sessionId: session }, pin ? { pin } : {}, o)).toString();
const mb = (n) => n > 1e9 ? (n / 1e9).toFixed(1) + ' GB' : n > 1e6 ? (n / 1e6).toFixed(0) + ' MB' : Math.max(1, Math.round(n / 1e3)) + ' KB';
const el = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; };
let files = [], data = null, selecting = false;
const selected = new Set();

function toast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg; t.classList.add('show');
  clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.remove('show'), 2200);
}

function message(title, text) {
  app.innerHTML = '';
  const c = el('div', 'center'), card = el('div', 'card glass');
  const h = el('h1'); h.textContent = title; h.style.whiteSpace = 'normal';
  const p = el('p', 'sub'); p.textContent = text;
  card.append(h, p); c.append(card); app.append(c);
}

function askPin(wrong) {
  app.innerHTML = '<div class="center"><form class="card glass" id="f"><h1 style="white-space:normal">Enter PIN</h1>' +
    '<div class="sub">Ask the photographer for the code.</div>' +
    '<input id="pin" inputmode="numeric" autocomplete="one-time-code" maxlength="8" autofocus>' +
    '<div class="err">' + (wrong ? 'That PIN didn’t work.' : '') + '</div>' +
    '<button class="primary" type="submit">Open photos</button></form></div>';
  document.getElementById('f').onsubmit = (e) => {
    e.preventDefault();
    pin = document.getElementById('pin').value.trim();
    sessionStorage.setItem('pin-' + session, pin);
    load();
  };
}

async function load() {
  if (!session) return message('Scan the QR code', 'Open the link from the photographer’s QR code.');
  let res;
  try { res = await fetch('/api/localsend/v2/prepare-download?' + q({}), { method: 'POST' }); }
  catch (e) { return message('Can’t reach the phone', 'Make sure you’re on the same Wi-Fi or hotspot as the photographer.'); }
  if (res.status === 401) return askPin(!!pin);
  if (!res.ok) return message('This share has ended', 'Ask the photographer to share again.');
  data = await res.json();
  files = Object.values(data.files).map((f) => Object.assign(f, { at: f.taken ? new Date(f.taken) : null }));
  files.sort((a, b) => (b.at || 0) - (a.at || 0));
  render();
}

function dayLabel(d) {
  if (!d) return 'Photos';
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const that = new Date(d); that.setHours(0, 0, 0, 0);
  const diff = Math.round((today - that) / 864e5);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Yesterday';
  return d.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
}

function render() {
  const total = files.reduce((n, f) => n + f.size, 0);
  app.innerHTML = '';
  const header = el('header', 'glass');
  const top = el('div', 'top');
  const h = el('h1'); h.textContent = data.title || 'Your photos';
  const play = el('button', 'icon', I.play); play.title = 'Slideshow'; play.onclick = () => openViewer(0, true);
  const sel = el('button', '', I.select + '<span>Select</span>'); sel.onclick = () => setSelecting(!selecting);
  top.append(h, play, sel);
  const sub = el('div', 'sub'); sub.textContent = files.length + ' photos · ' + mb(total) + ' · from ' + data.info.alias;
  const bar = el('div', 'bar');
  (data.zipParts || []).forEach((part, i, all) => {
    const a = el('a', 'btn primary', I.down + '<span></span>');
    a.href = '/zip?' + q({ part: i });
    a.querySelector('span').textContent = all.length > 1 ? 'Part ' + (i + 1) + ' of ' + all.length + ' (' + mb(part.size) + ')' : 'Download all (' + mb(part.size) + ')';
    a.onclick = () => toast('Download starting…');
    bar.append(a);
  });
  const seg = el('div', 'seg');
  [['S', 6], ['M', 4], ['L', 2]].forEach(([label, cols]) => {
    const b = el('button'); b.textContent = label; b.title = 'Grid size';
    const saved = +localStorage.getItem('cols') || 0;
    if ((saved || 4) === cols) b.classList.add('on');
    b.onclick = () => { localStorage.setItem('cols', cols); document.documentElement.style.setProperty('--cols', cols);
      seg.querySelectorAll('button').forEach((x) => x.classList.toggle('on', x === b)); };
    seg.append(b);
  });
  if (+localStorage.getItem('cols')) document.documentElement.style.setProperty('--cols', +localStorage.getItem('cols'));
  bar.append(seg);
  header.append(top, sub, bar);

  const main = el('main');
  const io = new IntersectionObserver((entries) => entries.forEach((e) => {
    if (e.isIntersecting) { const img = e.target; img.src = img.dataset.src; io.unobserve(img); }
  }), { rootMargin: '600px' });
  const groups = [];
  files.forEach((f, i) => {
    const key = f.at ? f.at.toDateString() : '';
    if (!groups.length || groups[groups.length - 1].key !== key) groups.push({ key, at: f.at, items: [] });
    groups[groups.length - 1].items.push(i);
  });
  for (const g of groups) {
    const day = el('div', 'day');
    const label = el('span'); label.textContent = dayLabel(g.at) + ' · ' + g.items.length;
    const all = el('button', 'pick-day', 'Select day');
    all.onclick = () => { setSelecting(true); const every = g.items.every((i) => selected.has(files[i].id));
      g.items.forEach((i) => toggle(files[i].id, !every)); };
    day.append(label, all);
    const grid = el('div', 'grid');
    for (const i of g.items) {
      const f = files[i];
      const t = el('div', 'tile'); t.dataset.id = f.id;
      const img = el('img'); img.alt = f.fileName; img.dataset.src = '/thumb?' + q({ fileId: f.id });
      img.decoding = 'async'; img.onload = () => img.classList.add('on');
      t.append(img, el('div', 'check'));
      t.onclick = () => selecting ? toggle(f.id) : openViewer(i);
      grid.append(t); io.observe(img);
    }
    main.append(day, grid);
  }
  const selbar = el('div', 'selbar glass');
  selbar.innerHTML = '<span class="n"></span>';
  const dl = el('button', 'primary', I.down + '<span>Download</span>');
  dl.onclick = downloadSelected;
  const clear = el('button', 'icon', I.close); clear.title = 'Done'; clear.onclick = () => setSelecting(false);
  selbar.append(dl, clear);
  app.append(header, main, selbar);
  requestAnimationFrame(() => document.documentElement.style.setProperty('--hh', header.offsetHeight + 'px'));
  buildViewer();
}

function setSelecting(on) {
  selecting = on;
  document.body.classList.toggle('selecting', on);
  if (!on) { selected.clear(); document.querySelectorAll('.tile.sel').forEach((t) => t.classList.remove('sel')); }
  updateSel();
}

function toggle(id, force) {
  const on = force ?? !selected.has(id);
  on ? selected.add(id) : selected.delete(id);
  const t = document.querySelector('.tile[data-id="' + id + '"]');
  if (t) t.classList.toggle('sel', on);
  updateSel();
}

function updateSel() {
  const bar = document.querySelector('.selbar');
  if (!bar) return;
  const size = files.filter((f) => selected.has(f.id)).reduce((n, f) => n + f.size, 0);
  bar.querySelector('.n').textContent = selected.size + ' selected · ' + mb(size);
  bar.classList.toggle('show', selecting);
}

function downloadSelected() {
  if (!selected.size) return toast('Tap photos to pick them first');
  const picked = files.filter((f) => selected.has(f.id));
  if (picked.reduce((n, f) => n + f.size, 0) > (data.zipLimit || 3.5e9)) return toast('That’s too much for one ZIP — pick fewer');
  if (picked.length === 1) { location.href = '/api/localsend/v2/download?' + q({ fileId: picked[0].id }); return; }
  location.href = '/zip?' + q({ ids: picked.map((f) => f.id).join(',') });
  toast('Download starting…');
}

/* ---------- Full-screen viewer ---------- */
let lb, frame, imgEl, stripEl, idx = 0, scale = 1, tx = 0, ty = 0, playing = false, timer = null, progEl, infoEl;
function buildViewer() {
  lb = el('div', 'lb');
  lb.innerHTML = '<div class="progress"></div><div class="tools"></div><div class="stage"><div class="frame"><img alt=""></div></div><div class="strip"></div><div class="info glass"></div>';
  const tools = lb.querySelector('.tools');
  const btn = (icon, title, fn, cls) => { const b = el('button', 'icon ' + (cls || ''), icon); b.title = title; b.onclick = (e) => { e.stopPropagation(); fn(); }; return b; };
  tools.append(btn(I.close, 'Close (Esc)', closeViewer), el('span', 'count'),
    btn(I.play, 'Slideshow (space)', () => setPlaying(!playing), 'playbtn'),
    btn(I.check, 'Select', () => { setSelecting(true); toggle(files[idx].id); syncTools(); }, 'selbtn'),
    btn(I.info, 'Info', () => infoEl.classList.toggle('show')),
    btn(I.share, 'Share', shareCurrent, 'sharebtn'),
    btn(I.down, 'Download original', () => { location.href = '/api/localsend/v2/download?' + q({ fileId: files[idx].id }); }));
  if (!(navigator.canShare)) tools.querySelector('.sharebtn').style.display = 'none';
  const stage = lb.querySelector('.stage');
  stage.append(btn(I.left, 'Previous (←)', () => go(-1), 'nav prev'), btn(I.right, 'Next (→)', () => go(1), 'nav next'));
  frame = lb.querySelector('.frame'); imgEl = frame.querySelector('img');
  stripEl = lb.querySelector('.strip'); progEl = lb.querySelector('.progress'); infoEl = lb.querySelector('.info');
  files.forEach((f, i) => {
    const t = el('img'); t.loading = 'lazy'; t.src = '/thumb?' + q({ fileId: f.id }); t.onclick = () => show(i);
    stripEl.append(t);
  });
  document.body.append(lb);
  gestures(stage);
  document.addEventListener('keydown', (e) => {
    if (!lb.classList.contains('open')) return;
    if (e.key === 'Escape') closeViewer();
    if (e.key === 'ArrowRight') go(1);
    if (e.key === 'ArrowLeft') go(-1);
    if (e.key === ' ') { e.preventDefault(); setPlaying(!playing); }
  });
}

function openViewer(i, play) {
  lb.classList.add('open'); document.body.style.overflow = 'hidden';
  show(i, 0); if (play) setPlaying(true);
  history.pushState({ viewer: true }, '');
}
function closeViewer() {
  if (!lb.classList.contains('open')) return;
  setPlaying(false); lb.classList.remove('open'); infoEl.classList.remove('show'); document.body.style.overflow = '';
  if (history.state && history.state.viewer) history.back();
}
window.addEventListener('popstate', () => { if (lb && lb.classList.contains('open')) { setPlaying(false); lb.classList.remove('open'); document.body.style.overflow = ''; } });

function show(i, dir) {
  idx = (i + files.length) % files.length;
  const f = files[idx];
  resetZoom();
  if (dir) { frame.style.transition = 'none'; frame.style.transform = 'translateX(' + (dir * 40) + 'px)'; frame.style.opacity = '0';
    requestAnimationFrame(() => { frame.style.transition = ''; frame.style.transform = ''; frame.style.opacity = '1'; }); }
  imgEl.classList.add('loading');
  imgEl.src = '/thumb?' + q({ fileId: f.id });
  const full = new Image(); full.src = '/preview?' + q({ fileId: f.id });
  full.onload = () => { if (files[idx] === f) { imgEl.src = full.src; imgEl.classList.remove('loading'); } };
  [1, -1, 2].forEach((d) => { const n = files[(idx + d + files.length) % files.length]; if (n) new Image().src = '/preview?' + q({ fileId: n.id }); });
  lb.querySelector('.count').textContent = (idx + 1) + ' / ' + files.length;
  [...stripEl.children].forEach((t, k) => t.classList.toggle('cur', k === idx));
  const cur = stripEl.children[idx]; if (cur) cur.scrollIntoView({ inline: 'center', block: 'nearest', behavior: 'smooth' });
  infoEl.innerHTML = '';
  const name = el('div'); name.style.fontWeight = '700'; name.textContent = f.fileName;
  const meta = el('div', 'sub'); meta.textContent = (f.at ? f.at.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) + ' · ' : '') + mb(f.size);
  infoEl.append(name, meta);
  syncTools();
  if (playing) restartTimer();
}
function go(d) { show(idx + d, d); }
function syncTools() {
  const on = selected.has(files[idx].id);
  const b = lb.querySelector('.selbtn'); b.classList.toggle('sel-on', on); b.title = on ? 'Selected' : 'Select';
}

function setPlaying(on) {
  playing = on;
  lb.querySelector('.playbtn').innerHTML = on ? I.pause : I.play;
  lb.classList.toggle('chrome-off', on);
  if (on) restartTimer(); else { clearInterval(timer); progEl.style.transition = 'none'; progEl.style.width = '0'; }
}
function restartTimer() {
  clearInterval(timer);
  progEl.style.transition = 'none'; progEl.style.width = '0';
  requestAnimationFrame(() => { progEl.style.transition = 'width 4s linear'; progEl.style.width = '100%'; });
  timer = setInterval(() => go(1), 4000);
}

async function shareCurrent() {
  const f = files[idx];
  try {
    toast('Preparing…');
    const blob = await (await fetch('/api/localsend/v2/download?' + q({ fileId: f.id }))).blob();
    const file = new File([blob], f.fileName, { type: f.fileType });
    if (navigator.canShare && navigator.canShare({ files: [file] })) await navigator.share({ files: [file], title: f.fileName });
    else toast('Sharing isn’t supported here — use Download');
  } catch (e) { /* cancelled */ }
}

/* Swipe, pinch-zoom, double-tap zoom and pan. */
function resetZoom() { scale = 1; tx = 0; ty = 0; applyZoom(); }
function applyZoom() { imgEl.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')'; }
function gestures(stage) {
  let startX = 0, startY = 0, dx = 0, lastTap = 0, pinchStart = 0, baseScale = 1, panning = false, baseTx = 0, baseTy = 0;
  stage.addEventListener('touchstart', (e) => {
    if (playing) setPlaying(false);
    if (e.touches.length === 2) {
      pinchStart = Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY);
      baseScale = scale; return;
    }
    startX = e.touches[0].clientX; startY = e.touches[0].clientY; dx = 0; baseTx = tx; baseTy = ty; panning = scale > 1;
    frame.style.transition = 'none';
  }, { passive: true });
  stage.addEventListener('touchmove', (e) => {
    if (e.touches.length === 2 && pinchStart) {
      const d = Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY);
      scale = Math.min(5, Math.max(1, baseScale * d / pinchStart)); imgEl.style.transition = 'none'; applyZoom(); return;
    }
    const mx = e.touches[0].clientX - startX, my = e.touches[0].clientY - startY;
    if (panning) { tx = baseTx + mx; ty = baseTy + my; imgEl.style.transition = 'none'; applyZoom(); return; }
    dx = mx; frame.style.transform = 'translateX(' + dx + 'px)';
    if (Math.abs(my) > Math.abs(mx) && my > 0) { frame.style.transform = 'translateY(' + my + 'px) scale(' + Math.max(.8, 1 - my / 1500) + ')'; lb.style.background = 'rgba(0,0,0,' + Math.max(.3, .92 - my / 600) + ')'; }
  }, { passive: true });
  stage.addEventListener('touchend', (e) => {
    imgEl.style.transition = ''; frame.style.transition = ''; lb.style.background = '';
    if (pinchStart) { pinchStart = 0; if (scale < 1.05) resetZoom(); return; }
    const my = (e.changedTouches[0].clientY - startY);
    if (!panning && my > 120 && Math.abs(my) > Math.abs(dx)) { frame.style.transform = ''; closeViewer(); return; }
    if (!panning && Math.abs(dx) > 60) { go(dx < 0 ? 1 : -1); return; }
    frame.style.transform = '';
    const now = Date.now();
    if (now - lastTap < 280 && Math.abs(dx) < 10) {
      if (scale > 1) resetZoom(); else { scale = 2.5; applyZoom(); }
      lastTap = 0; return;
    }
    lastTap = now;
    if (Math.abs(dx) < 10 && Math.abs(my) < 10) setTimeout(() => { if (lastTap === now) lb.classList.toggle('chrome-off'); }, 290);
  });
  stage.addEventListener('dblclick', () => { if (scale > 1) resetZoom(); else { scale = 2.5; applyZoom(); } });
  stage.addEventListener('wheel', (e) => { e.preventDefault(); scale = Math.min(5, Math.max(1, scale - e.deltaY / 400)); if (scale === 1) { tx = ty = 0; } applyZoom(); }, { passive: false });
}

load();
</script>
</body>
</html>
''';
