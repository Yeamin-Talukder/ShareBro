/// The page a friend's browser shows after scanning the QR code: their
/// photos grouped by day (pinch or Ctrl+scroll to resize the grid, a date
/// scrubber, filters, long-press and drag to pick), a full-screen viewer
/// (swipe, pinch/wheel zoom to the finger or cursor, pan with momentum,
/// full-quality zoom, video playback, slideshow, share, download) and a
/// PIN prompt when the share is protected. Talks to the LocalSend download
/// API (`prepare-download` / `download`) plus our `/thumb`, `/preview` and
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
:root{--accent:#BF3A22;--on-accent:#fff;--bg:#F6F5F8;--ink:#1A1820;--muted:#5E5A66;--card:#fff;--skel:#E6E3EB;
--glass:rgba(255,255,255,.74);--rim:rgba(255,255,255,.85);--line:rgba(26,24,32,.1);--shadow:0 12px 32px rgba(20,16,30,.16);
--ease:cubic-bezier(.2,.8,.2,1);--cols:4;--gap:3px;--r:6px;--hh:64px}
@media (prefers-color-scheme:dark){:root{--accent:#FF8A6B;--on-accent:#2A0D06;--bg:#0F0E12;--ink:#F2EFF5;--muted:#A9A3B3;
--card:#1A1820;--skel:#1E1C24;--glass:rgba(28,26,34,.72);--rim:rgba(255,255,255,.12);--line:rgba(255,255,255,.1);--shadow:0 12px 32px rgba(0,0,0,.5)}}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0}
html.locked,html.locked body{overflow:hidden}
body{font:16px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:var(--ink);background:var(--bg);min-height:100vh}
body::before{content:"";position:fixed;inset:-20%;z-index:-1;pointer-events:none;
background:radial-gradient(40% 35% at 15% 10%,rgba(217,67,43,.24),transparent 70%),
radial-gradient(35% 30% at 90% 20%,rgba(110,91,255,.22),transparent 70%),
radial-gradient(40% 35% at 55% 70%,rgba(43,181,166,.18),transparent 70%);animation:drift 26s ease-in-out infinite alternate}
@keyframes drift{to{transform:translate(4%,3%) rotate(6deg)}}
.glass{background:var(--glass);border:1px solid var(--rim);backdrop-filter:blur(20px) saturate(1.4);-webkit-backdrop-filter:blur(20px) saturate(1.4)}
button,.btn{appearance:none;border:1px solid var(--line);border-radius:999px;padding:10px 16px;min-height:44px;font:inherit;font-weight:650;cursor:pointer;
display:inline-flex;align-items:center;justify-content:center;gap:8px;text-decoration:none;color:var(--ink);background:var(--card);
transition:transform .12s var(--ease),background .2s,opacity .2s,color .2s;white-space:nowrap}
button:active,.btn:active{transform:scale(.95)}
button:disabled{opacity:.4;cursor:default}
button:disabled:active{transform:none}
:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
.primary{background:var(--accent);color:var(--on-accent);border-color:transparent}
.icon{width:44px;height:44px;padding:0;flex:none}
.small{min-height:36px;padding:6px 12px;font-size:14px}
svg{width:20px;height:20px;flex:none}
.sub{color:var(--muted);font-size:14px}
.grow{flex:1}
/* Header */
header{position:fixed;left:0;right:0;top:0;z-index:5;padding:10px 16px;padding-top:max(10px,env(safe-area-inset-top));
padding-left:max(16px,env(safe-area-inset-left));padding-right:max(16px,env(safe-area-inset-right));border-width:0 0 1px}
.top{display:flex;align-items:center;gap:8px}
.titles{flex:1;min-width:0}
h1{margin:0;font-size:22px;line-height:1.2;letter-spacing:-.4px;font-weight:800;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;transition:font-size .25s var(--ease)}
.titles .sub{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
header.mini h1{font-size:18px}
.bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-top:10px;max-height:240px;transition:max-height .3s var(--ease),opacity .2s,margin .3s var(--ease)}
header.mini .bar{max-height:0;opacity:0;margin-top:0;overflow:hidden;pointer-events:none}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:999px;overflow:hidden;background:var(--card)}
.seg button{border:0;border-radius:0;min-height:36px;padding:6px 12px;font-size:14px;background:transparent}
.seg button.on{background:var(--accent);color:var(--on-accent)}
.seg button.icon{width:40px;padding:0}
.selbtn.on{background:var(--accent);color:var(--on-accent);border-color:transparent}
@media (hover:none){.zg{display:none}}
@media (max-width:480px){.sortbtn span{display:none}.sortbtn{width:36px;padding:0}.bar .seg button{padding:6px 10px}}
/* Grid */
main{padding:0 4px 140px;padding-left:max(4px,env(safe-area-inset-left));padding-right:max(4px,env(safe-area-inset-right));touch-action:pan-x pan-y;transform-origin:50% 0}
.day{position:sticky;top:var(--hh);z-index:2;display:flex;align-items:center;justify-content:space-between;gap:8px;
padding:14px 8px 8px;font-weight:750;background:linear-gradient(var(--bg) 70%,transparent)}
.day .cnt{color:var(--muted);font-weight:600;font-size:14px;margin-left:8px}
.day button{min-height:32px;padding:4px 12px;font-size:13px}
.grid{display:grid;grid-template-columns:repeat(var(--cols),minmax(0,1fr));gap:var(--gap)}
.tile{position:relative;aspect-ratio:1;overflow:hidden;border-radius:var(--r);background:var(--skel);cursor:pointer;
-webkit-touch-callout:none;user-select:none;-webkit-user-select:none;transition:transform .18s var(--ease),border-radius .18s}
.tile:not(.ok)::before{content:"";position:absolute;inset:0;background:linear-gradient(100deg,transparent 30%,rgba(255,255,255,.16) 50%,transparent 70%);
background-size:220% 100%;animation:shim 1.3s linear infinite}
@keyframes shim{from{background-position:120% 0}to{background-position:-120% 0}}
.tile img{width:100%;height:100%;object-fit:cover;display:block;opacity:0;transition:opacity .35s var(--ease),transform .5s var(--ease);transform:scale(1.04);-webkit-user-drag:none;pointer-events:none}
.tile.ok img{opacity:1;transform:none}
.tile .badge{position:absolute;left:6px;bottom:6px;display:flex;align-items:center;gap:3px;padding:2px 7px 2px 5px;border-radius:999px;
background:rgba(0,0,0,.5);color:#fff;font-size:11px;font-weight:700}
.tile .badge svg{width:12px;height:12px}
.tile .fname{position:absolute;left:0;right:0;bottom:0;padding:16px 6px 5px;font-size:11px;font-weight:650;color:#fff;
background:linear-gradient(transparent,rgba(0,0,0,.6));white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tile .check{position:absolute;top:6px;right:6px;width:26px;height:26px;border-radius:50%;border:2px solid #fff;
background:rgba(0,0,0,.25);display:none;align-items:center;justify-content:center;transition:transform .15s var(--ease),opacity .15s;box-shadow:0 1px 4px rgba(0,0,0,.3)}
.selecting .tile .check{display:flex}
@media (hover:hover){.tile:hover .check{display:flex;opacity:.9}.tile:hover img{transform:scale(1.03)}}
.tile.sel{transform:scale(.88);border-radius:calc(var(--r) + 8px)}
.tile.sel .check{background:var(--accent);border-color:var(--accent);transform:scale(1.1);opacity:1}
.tile.sel .check::after{content:"";width:10px;height:6px;border:solid #fff;border-width:0 0 2.5px 2.5px;transform:rotate(-45deg) translate(1px,-1px)}
.tile.flash{animation:flash 1.1s var(--ease)}
@keyframes flash{0%,60%{box-shadow:inset 0 0 0 3px var(--accent)}100%{box-shadow:inset 0 0 0 0 transparent}}
.tile.broken::after{content:"!";position:absolute;inset:0;display:grid;place-items:center;color:var(--muted);font-weight:800}
/* Selection bar */
.selbar{position:fixed;left:50%;bottom:max(14px,env(safe-area-inset-bottom));width:min(560px,calc(100% - 24px));transform:translate(-50%,160%);z-index:6;
display:flex;gap:6px;align-items:center;padding:6px;border-radius:999px;transition:transform .35s var(--ease);box-shadow:var(--shadow)}
.selbar.show{transform:translate(-50%,0)}
.selbar .n{flex:1;min-width:0;line-height:1.2;padding-left:4px}
.selbar .n b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.selbar .n span{font-size:13px;color:var(--muted)}
@media (max-width:400px){.selbar .dl span{display:none}.selbar .dl{width:44px;padding:0}}
/* Date scrubber */
.scrub{position:fixed;right:0;top:var(--hh);bottom:0;width:48px;z-index:4;pointer-events:none;opacity:0;transition:opacity .3s}
.scrub.show,.scrub.drag{opacity:1}
.scrub.show .sthumb{pointer-events:auto}
.sthumb{position:absolute;right:6px;top:0;width:32px;height:48px;border-radius:16px;display:grid;place-items:center;cursor:grab;touch-action:none;box-shadow:var(--shadow);color:var(--muted)}
.scrub.drag .sthumb{cursor:grabbing;color:var(--accent)}
.bubble{position:absolute;right:52px;top:6px;white-space:nowrap;padding:7px 14px;border-radius:999px;font-weight:750;font-size:14px;
opacity:0;transform:translateX(8px);transition:opacity .2s,transform .2s var(--ease);box-shadow:var(--shadow)}
.scrub.drag .bubble{opacity:1;transform:none}
/* Cards, PIN, toast */
.center{min-height:80vh;display:grid;place-items:center;text-align:center;padding:24px 16px}
.card{border-radius:28px;padding:28px 24px;max-width:380px;width:100%;box-shadow:var(--shadow)}
.card h1{white-space:normal;margin-bottom:6px}
.card .sub{margin:0 0 4px}
.card .lockic{width:56px;height:56px;border-radius:50%;margin:0 auto 14px;display:grid;place-items:center;background:color-mix(in srgb,var(--accent) 14%,transparent);color:var(--accent)}
.card .lockic svg{width:26px;height:26px}
.card .wide{width:100%;margin-top:6px}
input.pin{width:100%;font:inherit;font-size:26px;letter-spacing:10px;text-align:center;padding:12px;border-radius:16px;
border:1px solid var(--line);background:var(--card);color:var(--ink);margin:18px 0 6px}
input.pin:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 25%,transparent)}
.err{color:#D13438;min-height:1.5em;font-size:14px;font-weight:600}
.shake{animation:shake .4s}
@keyframes shake{20%,60%{transform:translateX(-8px)}40%,80%{transform:translateX(8px)}}
.toast{position:fixed;left:50%;top:max(14px,env(safe-area-inset-top));transform:translate(-50%,-180%);z-index:30;max-width:calc(100% - 24px);
display:flex;align-items:center;gap:10px;padding:8px 8px 8px 18px;min-height:44px;border-radius:999px;transition:transform .35s var(--ease);font-weight:600;box-shadow:var(--shadow);color:var(--ink)}
.toast.show{transform:translate(-50%,0)}
.toast:not(.act){padding-right:18px}
.toast button{min-height:34px;padding:4px 14px}
.skel-h{height:22px;width:55%;border-radius:8px;background:var(--skel);margin:8px 0}
.skel-s{height:14px;width:35%;border-radius:6px;background:var(--skel)}
/* Full-screen viewer */
.lb{position:fixed;inset:0;z-index:10;color:#fff;visibility:hidden;touch-action:none;user-select:none;-webkit-user-select:none;overscroll-behavior:contain}
.lb.open{visibility:visible}
.lb .bg{position:absolute;inset:0;background:#000;opacity:0;transition:opacity .28s var(--ease)}
.lb.open .bg{opacity:1}
.lb .stage{position:absolute;inset:0;overflow:hidden;cursor:zoom-in}
.lb.zoomed .stage{cursor:grab}
.lb .stage.dragging{cursor:grabbing}
.lb.nozoom .stage{cursor:default}
.slide{position:absolute;inset:0;will-change:transform}
.slide .pic{position:absolute;left:0;top:0;width:100%;height:100%;object-fit:contain;transform-origin:center;pointer-events:none;-webkit-user-drag:none;transition:filter .3s}
.slide .pic.blur{filter:blur(10px)}
.slide video{position:absolute;left:0;width:100%;top:calc(env(safe-area-inset-top) + 64px);
height:calc(100% - env(safe-area-inset-top) - env(safe-area-inset-bottom) - 136px);object-fit:contain;background:#000;outline:none}
.lb.bare .slide video{top:0;height:100%}
.vplay{position:absolute;left:50%;top:50%;width:76px;height:76px;margin:-38px 0 0 -38px;padding:0;border-radius:50%;
background:rgba(0,0,0,.45);border:2px solid rgba(255,255,255,.85);color:#fff;backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px)}
.vplay svg{width:32px;height:32px;margin-left:4px}
.fcap{position:absolute;left:50%;bottom:calc(env(safe-area-inset-bottom) + 110px);transform:translateX(-50%);display:flex;flex-direction:column;align-items:center;gap:10px;
max-width:calc(100% - 32px);text-align:center;font-weight:650}
.fcap .nm{max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.lb .tools{position:absolute;left:0;right:0;top:0;z-index:3;display:flex;align-items:center;gap:6px;padding:10px 12px 26px;
padding-top:max(10px,env(safe-area-inset-top));background:linear-gradient(rgba(0,0,0,.62),transparent);transition:opacity .25s,transform .25s var(--ease)}
.lb .meta{flex:1;min-width:0;line-height:1.2;padding:0 4px}
.lb .meta b{display:block;font-size:15px}
.lb .meta span{display:block;font-size:12.5px;opacity:.8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.lb button{background:rgba(255,255,255,.14);color:#fff;border-color:rgba(255,255,255,.16)}
.lb button:hover{background:rgba(255,255,255,.24)}
.lb button.on{background:var(--accent);color:var(--on-accent);border-color:transparent}
.lb .zgrp{display:flex;align-items:center;border-radius:999px;background:rgba(255,255,255,.1);border:1px solid rgba(255,255,255,.14)}
.lb .zgrp button{background:transparent;border:0;width:40px;height:40px;min-height:40px}
.lb .zgrp .pct{width:auto;min-width:58px;padding:0 6px;font-size:13px;font-variant-numeric:tabular-nums}
.lb .nav{position:absolute;top:50%;margin-top:-26px;z-index:2;width:52px;height:52px;transition:opacity .25s}
.lb .prev{left:max(12px,env(safe-area-inset-left))}.lb .next{right:max(12px,env(safe-area-inset-right))}
.lb .strip{position:absolute;left:0;right:0;bottom:0;z-index:2;display:flex;gap:4px;overflow-x:auto;padding:22px 10px max(10px,env(safe-area-inset-bottom));
scrollbar-width:none;background:linear-gradient(transparent,rgba(0,0,0,.65));transition:opacity .25s,transform .25s var(--ease)}
.lb .strip::-webkit-scrollbar{display:none}
.lb .strip img{width:48px;height:48px;object-fit:cover;border-radius:8px;opacity:.5;flex:none;cursor:pointer;transition:opacity .2s,transform .2s var(--ease);background:#222;-webkit-user-drag:none}
.lb .strip img:hover{opacity:.8}
.lb .strip img.cur{opacity:1;transform:scale(1.1);outline:2px solid #fff;outline-offset:-1px}
.lb .info{position:absolute;left:50%;bottom:max(12px,env(safe-area-inset-bottom));width:min(440px,calc(100% - 24px));z-index:4;padding:16px 18px;border-radius:22px;font-size:14px;
transform:translate(-50%,140%);transition:transform .32s var(--ease);color:var(--ink);box-shadow:var(--shadow)}
.lb .info.show{transform:translate(-50%,0)}
.lb .info .nm{font-weight:750;font-size:16px;word-break:break-all;margin-bottom:8px}
.lb .info dl{display:grid;grid-template-columns:auto 1fr;gap:4px 14px;margin:0 0 12px}
.lb .info dt{color:var(--muted)}.lb .info dd{margin:0}
.lb .info button{background:var(--accent);color:var(--on-accent);border:0;width:100%}
.lb .hud{position:absolute;left:50%;top:calc(max(10px,env(safe-area-inset-top)) + 64px);transform:translate(-50%,-6px);z-index:4;padding:6px 14px;border-radius:999px;
background:rgba(0,0,0,.6);font-size:13px;font-weight:700;opacity:0;transition:opacity .2s,transform .2s var(--ease);pointer-events:none;display:flex;align-items:center;gap:8px;
font-variant-numeric:tabular-nums}
.lb .hud.show{opacity:1;transform:translate(-50%,0)}
.spin{width:14px;height:14px;border-radius:50%;border:2px solid rgba(255,255,255,.3);border-top-color:#fff;animation:spin .8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.lb .progress{position:absolute;left:0;top:0;height:3px;background:var(--accent);width:0;z-index:5}
.lb.bare .tools{opacity:0;transform:translateY(-14px);pointer-events:none}
.lb.bare .strip{opacity:0;transform:translateY(14px);pointer-events:none}
.lb.bare .nav,.lb.zoomed .nav,.lb.drag .nav{opacity:0;pointer-events:none}
.lb.zoomed .strip,.lb.drag .strip,.lb.drag .tools{opacity:0;pointer-events:none}
.lb.single .nav{display:none}
@media (hover:none){.lb .nav,.lb .zgrp,.lb .fsbtn{display:none}}
@media (max-width:420px){.lb .tools{gap:4px;padding-left:8px;padding-right:8px}.lb .tools button.icon{width:40px;height:40px;min-height:40px}}
@media (prefers-reduced-motion:reduce){*,*::before{transition:none!important;animation:none!important}}
</style>
</head>
<body>
<div id="app"><header class="glass"><div class="skel-h"></div><div class="skel-s"></div></header>
<main style="padding-top:96px"><div class="grid">
<div class="tile"></div><div class="tile"></div><div class="tile"></div><div class="tile"></div><div class="tile"></div><div class="tile"></div>
<div class="tile"></div><div class="tile"></div><div class="tile"></div><div class="tile"></div><div class="tile"></div><div class="tile"></div>
<div class="tile"></div><div class="tile"></div><div class="tile"></div><div class="tile"></div><div class="tile"></div><div class="tile"></div>
</div></main></div>
<div class="toast glass" id="toast" role="status" aria-live="polite"></div>
<script>
const P = 'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"';
const I = {
  down:'<svg viewBox="0 0 24 24" ' + P + '><path d="M12 4v11m0 0l-4-4m4 4l4-4M5 20h14"/></svg>',
  share:'<svg viewBox="0 0 24 24" ' + P + '><path d="M12 15V3m0 0L8 7m4-4l4 4M5 12v7a2 2 0 002 2h10a2 2 0 002-2v-7"/></svg>',
  close:'<svg viewBox="0 0 24 24" ' + P + ' stroke-width="2.2"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  left:'<svg viewBox="0 0 24 24" ' + P + ' stroke-width="2.2"><path d="M15 5l-7 7 7 7"/></svg>',
  right:'<svg viewBox="0 0 24 24" ' + P + ' stroke-width="2.2"><path d="M9 5l7 7-7 7"/></svg>',
  info:'<svg viewBox="0 0 24 24" ' + P + '><circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.01"/></svg>',
  play:'<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>',
  pause:'<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 5h4v14H7zM13 5h4v14h-4z"/></svg>',
  check:'<svg viewBox="0 0 24 24" ' + P + ' stroke-width="2.4"><path d="M5 12.5l4.5 4.5L19 7"/></svg>',
  select:'<svg viewBox="0 0 24 24" ' + P + '><rect x="4" y="4" width="16" height="16" rx="4"/><path d="M8.5 12l2.5 2.5L15.5 9.5"/></svg>',
  zin:'<svg viewBox="0 0 24 24" ' + P + '><circle cx="11" cy="11" r="6.5"/><path d="M20 20l-4.2-4.2M11 8.5v5M8.5 11h5"/></svg>',
  zout:'<svg viewBox="0 0 24 24" ' + P + '><circle cx="11" cy="11" r="6.5"/><path d="M20 20l-4.2-4.2M8.5 11h5"/></svg>',
  big:'<svg viewBox="0 0 24 24" ' + P + '><rect x="4" y="4" width="16" height="16" rx="3"/></svg>',
  many:'<svg viewBox="0 0 24 24" ' + P + '><rect x="4" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.5"/></svg>',
  sort:'<svg viewBox="0 0 24 24" ' + P + '><path d="M7 4v16m0 0l-3-3m3 3l3-3M17 20V4m0 0l-3 3m3-3l3 3"/></svg>',
  fs:'<svg viewBox="0 0 24 24" ' + P + '><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/></svg>',
  fsx:'<svg viewBox="0 0 24 24" ' + P + '><path d="M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5"/></svg>',
  lock:'<svg viewBox="0 0 24 24" ' + P + '><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 018 0v3"/></svg>',
  grip:'<svg viewBox="0 0 24 24" ' + P + '><path d="M8 10l4-4 4 4M8 14l4 4 4-4"/></svg>',
  vid:'<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>',
};
const RM = matchMedia('(prefers-reduced-motion: reduce)').matches;
const HOVER = matchMedia('(hover: hover)').matches;
const store = (s) => ({ get: (k) => { try { return s().getItem(k); } catch (e) { return null; } },
  set: (k, v) => { try { s().setItem(k, v); } catch (e) {} } });
const local = store(() => localStorage), sess = store(() => sessionStorage);
const params = new URLSearchParams(location.search);
const session = params.get('s');
let pin = sess.get('pin-' + session) || '';
const app = document.getElementById('app');
const q = (o) => new URLSearchParams(Object.assign({ sessionId: session }, pin ? { pin } : {}, o)).toString();
const mb = (n) => n >= 1e9 ? (n / 1e9).toFixed(1) + ' GB' : n >= 1e6 ? (n / 1e6).toFixed(n < 1e7 ? 1 : 0) + ' MB' : Math.max(1, Math.round(n / 1e3)) + ' KB';
const el = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; };
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const plural = (n, w) => n + ' ' + w + (n === 1 ? '' : 's');
const kindOf = (f) => /^image\//i.test(f.fileType || '') ? 'image' : /^video\//i.test(f.fileType || '') ? 'video' : 'file';
const thumbUrl = (f) => '/thumb?' + q({ fileId: f.id });
const previewUrl = (f) => '/preview?' + q({ fileId: f.id });
const fileUrl = (f, inline) => '/api/localsend/v2/download?' + q(inline ? { fileId: f.id, inline: 1 } : { fileId: f.id });
const sumSize = (fs) => fs.reduce((n, f) => n + f.size, 0);
function iconBtn(icon, label, fn, cls) {
  const b = el('button', 'icon ' + (cls || ''), icon);
  b.title = label; b.setAttribute('aria-label', label);
  b.onclick = (e) => { e.stopPropagation(); fn(e); };
  return b;
}
function save(url) { const a = el('a'); a.href = url; a.download = ''; document.body.append(a); a.click(); a.remove(); }

let files = [], list = [], data = null, selecting = false, filter = 'all';
let newestFirst = local.get('order') !== 'old';
const selected = new Set();
let header, main, selbar, scrub, io, tiles = [], groups = [];

/* ---------- Toast ---------- */
function toast(msg, o) {
  o = o || {};
  const t = document.getElementById('toast');
  t.innerHTML = ''; const s = el('span'); s.textContent = msg; t.append(s);
  t.classList.toggle('act', !!o.action);
  if (o.action) { const b = el('button', 'primary', ''); b.textContent = o.action; b.onclick = () => { hideToast(); o.fn(); }; t.append(b); }
  t.classList.add('show');
  clearTimeout(toast.t);
  if (o.ms !== 0) toast.t = setTimeout(hideToast, o.ms || (o.action ? 6000 : 2400));
}
function hideToast() { document.getElementById('toast').classList.remove('show'); }

/* ---------- Loading, errors, PIN ---------- */
function message(title, text, retry) {
  app.innerHTML = '';
  const c = el('div', 'center'), card = el('div', 'card glass');
  const h = el('h1'); h.textContent = title;
  const p = el('p', 'sub'); p.textContent = text;
  card.append(h, p);
  if (retry) { const b = el('button', 'primary wide', 'Try again'); b.onclick = () => { b.disabled = true; b.textContent = 'Connecting…'; retry(); }; card.append(b); }
  c.append(card); app.append(c);
}

function askPin(wrong) {
  app.innerHTML = '<div class="center"><form class="card glass" id="f" autocomplete="off"><div class="lockic">' + I.lock + '</div>' +
    '<h1>Enter PIN</h1><p class="sub">These photos are protected. Ask the person sharing them for the code.</p>' +
    '<input class="pin" id="pin" inputmode="numeric" pattern="[0-9]*" autocomplete="one-time-code" maxlength="8" aria-label="PIN" required>' +
    '<div class="err" role="alert"></div><button class="primary wide" type="submit">Open photos</button></form></div>';
  const f = document.getElementById('f'), input = document.getElementById('pin'), btn = f.querySelector('button');
  if (wrong) { f.querySelector('.err').textContent = 'That PIN didn’t work — try again.'; f.classList.add('shake'); }
  input.focus();
  input.oninput = () => { input.value = input.value.replace(/\D/g, ''); f.querySelector('.err').textContent = ''; };
  f.onsubmit = (e) => {
    e.preventDefault();
    if (!input.value.trim()) return;
    pin = input.value.trim();
    sess.set('pin-' + session, pin);
    btn.disabled = true; btn.textContent = 'Checking…';
    load();
  };
}

async function load() {
  if (!session) return message('Scan the QR code', 'Open the link from the photographer’s QR code.');
  let res;
  try { res = await fetch('/api/localsend/v2/prepare-download?' + q({}), { method: 'POST' }); }
  catch (e) { return message('Can’t reach the phone', 'Make sure you’re on the same Wi-Fi or hotspot as the person sharing, and that their app is still open.', load); }
  if (res.status === 401) return askPin(!!pin);
  if (!res.ok) return message('This share has ended', 'Ask the photographer to share again.');
  data = await res.json();
  files = Object.values(data.files).map((f) => Object.assign(f, { at: f.taken ? new Date(f.taken) : null, kind: kindOf(f) }));
  if (!files.length) return message('Nothing here yet', 'This share doesn’t have any photos in it.');
  document.title = (data.title || 'Your photos') + ' · ShareBro';
  render();
}

function dayLabel(d, short) {
  if (!d) return 'Undated';
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const that = new Date(d); that.setHours(0, 0, 0, 0);
  const diff = Math.round((today - that) / 864e5);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Yesterday';
  if (short) return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
  const sameYear = d.getFullYear() === today.getFullYear();
  return d.toLocaleDateString(undefined, sameYear ? { weekday: 'short', day: 'numeric', month: 'long' } : { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
}

function applyList() {
  list = files.filter((f) => filter === 'all' || f.kind === filter);
  list.sort((a, b) => newestFirst ? (b.at || 0) - (a.at || 0) : (a.at || 0) - (b.at || 0));
}

/* ---------- Gallery ---------- */
let selBtn, sortBtn, zBig, zMany, selCount, allBtn, dlSel, shareSel;
function render() {
  applyList();
  app.innerHTML = '';
  header = el('header', 'glass');
  const top = el('div', 'top');
  const titles = el('div', 'titles');
  const h = el('h1'); h.textContent = data.title || 'Your photos';
  const counts = { image: 0, video: 0, file: 0 };
  files.forEach((f) => counts[f.kind]++);
  const parts = [];
  if (counts.image) parts.push(plural(counts.image, 'photo'));
  if (counts.video) parts.push(plural(counts.video, 'video'));
  if (counts.file) parts.push(plural(counts.file, 'file'));
  const sub = el('div', 'sub'); sub.textContent = parts.join(', ') + ' · ' + mb(sumSize(files)) + ' · from ' + data.info.alias;
  titles.append(h, sub);
  const play = iconBtn(I.play, 'Slideshow', () => openViewer(0, null, true));
  selBtn = el('button', 'selbtn', I.select + '<span>Select</span>');
  selBtn.onclick = () => setSelecting(!selecting);
  top.append(titles, play, selBtn);

  const bar = el('div', 'bar');
  (data.zipParts || []).forEach((part, i, all) => {
    const a = el('a', 'btn primary small', I.down + '<span></span>');
    a.href = '/zip?' + q({ part: i });
    a.querySelector('span').textContent = all.length > 1 ? 'Part ' + (i + 1) + ' of ' + all.length + ' · ' + mb(part.size) : 'Download all · ' + mb(part.size);
    a.onclick = () => toast('Download starting…');
    bar.append(a);
  });
  if ((counts.image > 0) + (counts.video > 0) + (counts.file > 0) > 1) {
    const seg = el('div', 'seg'); seg.setAttribute('role', 'group'); seg.setAttribute('aria-label', 'Show');
    [['all', 'All'], ['image', 'Photos'], ['video', 'Videos'], ['file', 'Files']].forEach(([k, label]) => {
      if (k !== 'all' && !counts[k]) return;
      const b = el('button', k === filter ? 'on' : ''); b.textContent = label;
      b.onclick = () => { filter = k; seg.querySelectorAll('button').forEach((x) => x.classList.toggle('on', x === b)); refreshGrid(); };
      seg.append(b);
    });
    bar.append(seg);
  }
  bar.append(el('span', 'grow'));
  sortBtn = el('button', 'small sortbtn', I.sort + '<span></span>');
  sortBtn.onclick = () => { newestFirst = !newestFirst; local.set('order', newestFirst ? 'new' : 'old'); refreshGrid(); };
  const zg = el('div', 'seg zg'); zg.setAttribute('role', 'group'); zg.setAttribute('aria-label', 'Photo size');
  zMany = iconBtn(I.many, 'Smaller photos (Ctrl + scroll or pinch)', () => zoomGrid(1));
  zBig = iconBtn(I.big, 'Bigger photos (Ctrl + scroll or pinch)', () => zoomGrid(-1));
  zg.append(zMany, zBig);
  bar.append(sortBtn, zg);
  header.append(top, bar);

  main = el('main');
  selbar = el('div', 'selbar glass');
  const done = iconBtn(I.close, 'Done selecting', () => setSelecting(false));
  selCount = el('div', 'n', '<b></b><span></span>');
  allBtn = el('button', 'small'); allBtn.onclick = selectAllToggle;
  shareSel = iconBtn(I.share, 'Share selected', () => shareFiles(files.filter((f) => selected.has(f.id))));
  if (!navigator.canShare) shareSel.style.display = 'none';
  dlSel = el('button', 'primary dl', I.down + '<span>Download</span>'); dlSel.onclick = downloadSelected;
  selbar.append(done, selCount, allBtn, shareSel, dlSel);

  scrub = buildScrub();
  app.append(header, main, selbar, scrub);
  new ResizeObserver(syncHeader).observe(header);
  syncHeader();
  initCols();
  wireGrid();
  renderGrid();
  buildViewer();
  addEventListener('scroll', onScroll, { passive: true });
  if (!HOVER && !local.get('tip')) { local.set('tip', 1); setTimeout(() => toast('Tip: pinch the grid to make photos bigger or smaller', { ms: 4500 }), 1200); }
  addEventListener('resize', () => { snapCols(); if (vOpen) relayout(); cacheOffsets(); });
}

let expandedH = 0;
function syncHeader() {
  const h = header.offsetHeight;
  document.documentElement.style.setProperty('--hh', h + 'px');
  if (!header.classList.contains('mini')) { expandedH = h; main.style.paddingTop = h + 'px'; }
}

function refreshGrid() {
  applyList();
  renderGrid();
  scrollTo(0, 0);
}

function renderGrid() {
  sortBtn.querySelector('span').textContent = newestFirst ? 'Newest' : 'Oldest';
  sortBtn.title = newestFirst ? 'Showing newest first' : 'Showing oldest first';
  if (io) io.disconnect();
  io = new IntersectionObserver((entries) => entries.forEach((e) => {
    if (e.isIntersecting) { const img = e.target; if (img.getAttribute('src') !== img.dataset.src) img.src = img.dataset.src; io.unobserve(img); }
  }), { rootMargin: '800px 0px' });
  main.innerHTML = '';
  tiles = []; groups = [];
  list.forEach((f, i) => {
    const key = f.at ? f.at.toDateString() : '';
    if (!groups.length || groups[groups.length - 1].key !== key) groups.push({ key, at: f.at, items: [] });
    groups[groups.length - 1].items.push(i);
  });
  const frag = document.createDocumentFragment();
  for (const g of groups) {
    const day = el('div', 'day');
    const label = el('span', '', '<b></b><span class="cnt"></span>');
    label.querySelector('b').textContent = dayLabel(g.at);
    label.querySelector('.cnt').textContent = g.items.length;
    g.btn = el('button', 'pick-day', 'Select');
    g.btn.onclick = () => {
      setSelecting(true);
      const every = g.items.every((i) => selected.has(list[i].id));
      g.items.forEach((i) => setSel(list[i].id, !every));
      updateSel();
    };
    day.append(label, g.btn);
    g.el = day;
    const grid = el('div', 'grid');
    for (const i of g.items) grid.append(makeTile(list[i], i));
    frag.append(day, grid);
  }
  main.append(frag);
  tiles.forEach((t) => io.observe(t.img));
  stripDirty = true;
  updateSel();
  requestAnimationFrame(cacheOffsets);
}

function makeTile(f, i) {
  const t = el('div', 'tile');
  t.dataset.i = i; t.tabIndex = 0; t.setAttribute('role', 'button');
  t.setAttribute('aria-label', f.fileName + (f.at ? ', ' + f.at.toLocaleString() : ''));
  if (selected.has(f.id)) t.classList.add('sel');
  const img = el('img'); img.alt = ''; img.draggable = false; img.decoding = 'async';
  img.dataset.src = tileSrc(f);
  img.onload = () => t.classList.add('ok');
  img.onerror = () => {
    if (img.dataset.retry) { t.classList.add('ok', 'broken'); return; }
    img.dataset.retry = 1; setTimeout(() => { img.src = img.dataset.src + '&retry=1'; }, 1500);
  };
  t.append(img);
  if (f.kind === 'video') t.append(el('span', 'badge', I.vid + 'Video'));
  if (f.kind === 'file') { const n = el('span', 'fname'); n.textContent = f.fileName; t.append(n); }
  t.append(el('span', 'check'));
  t.img = img; t.f = f;
  tiles[i] = t;
  return t;
}

/* Grid size: pinch, Ctrl+scroll, + / - keys or the header buttons. */
const STEPS = [1, 2, 3, 4, 5, 6, 8, 10, 12, 16];
let cols = 4;
const gridW = () => (main && main.clientWidth) || innerWidth;
const allowed = () => { const w = gridW(); const a = STEPS.filter((c) => w / c >= 60 && w / c <= 560); return a.length ? a : [3]; };
const nearest = (arr, v) => arr.reduce((b, c) => Math.abs(c - v) < Math.abs(b - v) ? c : b, arr[0]);
const bigTiles = () => gridW() / cols * (devicePixelRatio || 1) > 440;
function initCols() {
  const w = gridW();
  cols = nearest(allowed(), +local.get('cols') || Math.round(w / (w < 700 ? 100 : 170)));
  applyCols();
}
function snapCols() {
  if (!local.get('cols')) return initCols();
  const c = nearest(allowed(), cols);
  if (c !== cols) { cols = c; applyCols(); }
}
function applyCols() {
  const r = document.documentElement.style;
  r.setProperty('--cols', cols);
  r.setProperty('--gap', cols <= 2 ? '6px' : cols <= 5 ? '3px' : '2px');
  r.setProperty('--r', cols <= 2 ? '14px' : cols <= 5 ? '6px' : '3px');
  const a = allowed();
  if (zBig) { zBig.disabled = cols <= a[0]; zMany.disabled = cols >= a[a.length - 1]; }
  const big = bigTiles();
  for (const t of tiles) {
    const want = tileSrc(t.f, big);
    if (t.img.dataset.src !== want) { t.img.dataset.src = want; if (t.img.getAttribute('src')) io.observe(t.img); }
  }
}
function tileSrc(f, big) { return (big == null ? bigTiles() : big) && f.kind !== 'file' ? previewUrl(f) : thumbUrl(f); }
function zoomGrid(dir, fx, fy) {
  const a = allowed();
  const k = a.indexOf(nearest(a, cols)) + dir;
  if (k < 0 || k >= a.length) return;
  fx = fx == null ? innerWidth / 2 : fx; fy = fy == null ? innerHeight / 2 : fy;
  const hit = document.elementFromPoint(fx, fy);
  const anchor = (hit && hit.closest('.tile')) || tiles.find((t) => t.getBoundingClientRect().bottom > expandedH);
  const before = anchor ? anchor.getBoundingClientRect().top : 0;
  const old = cols;
  cols = a[k]; local.set('cols', cols); applyCols();
  if (anchor) scrollBy(0, anchor.getBoundingClientRect().top - before);
  if (!RM && main.animate) {
    const r = main.getBoundingClientRect();
    main.style.transformOrigin = fx + 'px ' + (fy - r.top) + 'px';
    main.animate([{ transform: 'scale(' + (cols / old) + ')', opacity: .55 }, { transform: 'none', opacity: 1 }],
      { duration: 260, easing: 'cubic-bezier(.2,.8,.2,1)' });
  }
  cacheOffsets();
}

/* Taps, long-press + drag to pick, pinch to resize the grid. */
let lp = null, pinch = null, suppressClick = 0, lastClicked = null, wheelAcc = 0, wheelT = 0;
const dist = (a, b) => Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
function wireGrid() {
  main.addEventListener('click', (e) => {
    const t = e.target.closest('.tile');
    if (!t || Date.now() - suppressClick < 600) return;
    const i = +t.dataset.i, f = list[i];
    if (e.target.closest('.check') && !selecting) { setSelecting(true); toggle(f.id); lastClicked = i; return; }
    if (!selecting && (e.ctrlKey || e.metaKey)) setSelecting(true);
    if (selecting) {
      if (e.shiftKey && lastClicked != null) {
        const on = !selected.has(f.id);
        for (let k = Math.min(lastClicked, i); k <= Math.max(lastClicked, i); k++) setSel(list[k].id, on);
        updateSel();
      } else toggle(f.id);
      lastClicked = i;
    } else openViewer(i, t);
  });
  main.addEventListener('keydown', (e) => {
    const t = e.target.closest('.tile');
    if (t && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); t.click(); }
  });
  main.addEventListener('contextmenu', (e) => { if (e.target.closest('.tile') && (lp || !HOVER)) e.preventDefault(); });
  main.addEventListener('touchstart', (e) => {
    if (e.touches.length === 2) {
      cancelLp();
      pinch = { d: dist(e.touches[0], e.touches[1]) };
      return;
    }
    if (e.touches.length !== 1) return;
    const t = e.target.closest('.tile');
    if (!t) return;
    const p = e.touches[0];
    lp = { x: p.clientX, y: p.clientY, cx: p.clientX, cy: p.clientY, active: false, timer: setTimeout(() => startDragPick(t), 430) };
  }, { passive: true });
  main.addEventListener('touchmove', (e) => {
    if (pinch && e.touches.length === 2) {
      e.preventDefault();
      const a = e.touches[0], b = e.touches[1], d = dist(a, b);
      const mx = (a.clientX + b.clientX) / 2, my = (a.clientY + b.clientY) / 2;
      if (d / pinch.d > 1.3) { zoomGrid(-1, mx, my); pinch.d = d; }
      else if (d / pinch.d < 0.77) { zoomGrid(1, mx, my); pinch.d = d; }
      return;
    }
    if (!lp) return;
    const p = e.touches[0];
    if (!lp.active) { if (Math.hypot(p.clientX - lp.x, p.clientY - lp.y) > 10) cancelLp(); return; }
    e.preventDefault();
    lp.cx = p.clientX; lp.cy = p.clientY;
    dragPickAt();
  }, { passive: false });
  const end = (e) => {
    if (e.touches.length < 2) pinch = null;
    if (lp && !e.touches.length) { if (lp.active) suppressClick = Date.now(); cancelLp(); }
  };
  main.addEventListener('touchend', end);
  main.addEventListener('touchcancel', end);
  document.addEventListener('gesturestart', (e) => { if (!vOpen) e.preventDefault(); });
  addEventListener('wheel', (e) => {
    if (vOpen || !e.ctrlKey) return;
    e.preventDefault();
    clearTimeout(wheelT); wheelT = setTimeout(() => { wheelAcc = 0; }, 250);
    wheelAcc += e.deltaY * (e.deltaMode ? 30 : 1);
    if (wheelAcc > 50) { zoomGrid(1, e.clientX, e.clientY); wheelAcc = 0; }
    else if (wheelAcc < -50) { zoomGrid(-1, e.clientX, e.clientY); wheelAcc = 0; }
  }, { passive: false });
}
function cancelLp() { if (lp) { clearTimeout(lp.timer); cancelAnimationFrame(lp.raf); } lp = null; }
function startDragPick(t) {
  if (!lp) return;
  if (navigator.vibrate) navigator.vibrate(12);
  setSelecting(true);
  const i = +t.dataset.i;
  Object.assign(lp, { active: true, anchor: i, lo: i, hi: i, on: !selected.has(list[i].id), snap: new Set(selected) });
  setSel(list[i].id, lp.on); updateSel();
  const edge = () => {
    if (!lp || !lp.active) return;
    const top = expandedH ? parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--hh')) : 0;
    const v = lp.cy < top + 70 ? -(top + 70 - lp.cy) / 4 : lp.cy > innerHeight - 90 ? (lp.cy - innerHeight + 90) / 4 : 0;
    if (v) { scrollBy(0, v); dragPickAt(); }
    lp.raf = requestAnimationFrame(edge);
  };
  lp.raf = requestAnimationFrame(edge);
}
function dragPickAt() {
  const hit = document.elementFromPoint(lp.cx, lp.cy);
  const t = hit && hit.closest('.tile');
  if (!t) return;
  const j = +t.dataset.i, a = Math.min(lp.anchor, j), b = Math.max(lp.anchor, j);
  for (let k = Math.min(a, lp.lo); k <= Math.max(b, lp.hi); k++) {
    const id = list[k].id;
    setSel(id, k >= a && k <= b ? lp.on : lp.snap.has(id));
  }
  lp.lo = a; lp.hi = b;
  updateSel();
}

/* Header collapse + date scrubber, on scroll. */
let lastY = 0, upBy = 0, scrollRaf = 0, scrubT = 0, offsets = [];
function onScroll() {
  if (scrollRaf) return;
  scrollRaf = requestAnimationFrame(() => {
    scrollRaf = 0;
    const y = scrollY;
    upBy = y < lastY ? upBy + lastY - y : 0;
    if (y < 30 || upBy > 60) header.classList.remove('mini');
    else if (y > lastY && y > 80) header.classList.add('mini');
    lastY = y;
    if (!scrub.classList.contains('drag')) placeScrub(true);
  });
}
function cacheOffsets() { offsets = groups.map((g) => g.el.getBoundingClientRect().top + scrollY); }
function groupAt(y) {
  let lo = 0, hi = offsets.length - 1, best = 0;
  while (lo <= hi) { const m = (lo + hi) >> 1; if (offsets[m] <= y) { best = m; lo = m + 1; } else hi = m - 1; }
  return groups[best];
}
function buildScrub() {
  const s = el('div', 'scrub');
  const bub = el('div', 'bubble glass'), th = el('div', 'sthumb glass', I.grip);
  th.setAttribute('aria-hidden', 'true');
  s.append(bub, th);
  const track = () => { const hh = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--hh')) || 0; return { hh, len: innerHeight - hh - 48 - 24 }; };
  th.addEventListener('pointerdown', (e) => {
    e.preventDefault(); th.setPointerCapture(e.pointerId); s.classList.add('drag');
    const r = th.getBoundingClientRect(); th.off = e.clientY - r.top;
  });
  th.addEventListener('pointermove', (e) => {
    if (!s.classList.contains('drag')) return;
    const { hh, len } = track();
    const k = clamp((e.clientY - th.off - hh - 12) / len, 0, 1);
    const max = document.documentElement.scrollHeight - innerHeight;
    scrollTo(0, k * max);
    th.style.transform = bub.style.transform = 'translateY(' + (12 + k * len) + 'px)';
    const g = groupAt(k * max + hh + 40);
    bub.textContent = g ? dayLabel(g.at, true) : '';
  });
  const up = () => { s.classList.remove('drag'); placeScrub(true); };
  th.addEventListener('pointerup', up); th.addEventListener('pointercancel', up);
  s.bub = bub; s.th = th; s.track = track;
  return s;
}
function placeScrub(reveal) {
  const max = document.documentElement.scrollHeight - innerHeight;
  if (max < innerHeight * 2.5) { scrub.classList.remove('show'); return; }
  const { len } = scrub.track();
  const ty = 'translateY(' + (12 + clamp(scrollY / max, 0, 1) * len) + 'px)';
  scrub.th.style.transform = ty; scrub.bub.style.transform = '';
  if (reveal) {
    scrub.classList.add('show');
    clearTimeout(scrubT); scrubT = setTimeout(() => { if (!scrub.classList.contains('drag')) scrub.classList.remove('show'); }, 1400);
  }
}

/* ---------- Selection ---------- */
function setSelecting(on) {
  selecting = on;
  document.body.classList.toggle('selecting', on);
  selBtn.classList.toggle('on', on);
  selBtn.querySelector('span').textContent = on ? 'Cancel' : 'Select';
  if (!on) { selected.clear(); tiles.forEach((t) => t.classList.remove('sel')); lastClicked = null; }
  updateSel();
}
function setSel(id, on) {
  on ? selected.add(id) : selected.delete(id);
  const t = tileById(id);
  if (t) t.classList.toggle('sel', on);
}
let idIndex = null;
function tileById(id) {
  if (!idIndex || idIndex.list !== list) { idIndex = new Map(); idIndex.list = list; list.forEach((f, i) => idIndex.set(f.id, i)); }
  const i = idIndex.get(id);
  return i == null ? null : tiles[i];
}
function toggle(id, force) { setSel(id, force == null ? !selected.has(id) : force); updateSel(); }
function selectAllToggle() {
  const every = list.length && list.every((f) => selected.has(f.id));
  list.forEach((f) => setSel(f.id, !every));
  updateSel();
}
function updateSel() {
  if (!selbar) return;
  const picked = files.filter((f) => selected.has(f.id));
  selCount.querySelector('b').textContent = picked.length ? picked.length + ' selected' : 'Select items';
  selCount.querySelector('span').textContent = picked.length ? mb(sumSize(picked)) : (HOVER ? 'Click, or Shift-click a range' : 'Tap, or long-press and drag');
  selbar.classList.toggle('show', selecting);
  dlSel.disabled = shareSel.disabled = !picked.length;
  allBtn.textContent = list.length && list.every((f) => selected.has(f.id)) ? 'None' : 'All';
  for (const g of groups) g.btn.textContent = g.items.every((i) => selected.has(list[i].id)) && selecting ? 'Deselect' : 'Select';
  if (vOpen) syncSelBtn();
}
function downloadSelected() {
  const picked = files.filter((f) => selected.has(f.id));
  if (!picked.length) return toast('Pick some photos first');
  if (sumSize(picked) > (data.zipLimit || 3.5e9)) return toast('That’s too much for one ZIP — pick fewer');
  if (picked.length === 1) { save(fileUrl(picked[0])); toast('Download starting…'); return; }
  save('/zip?' + q({ ids: picked.map((f) => f.id).join(',') }));
  toast('Downloading ' + picked.length + ' items as a ZIP…');
}
async function shareFiles(fs) {
  if (!fs.length) return;
  if (!navigator.canShare) return toast('Sharing isn’t supported here — use Download');
  if (fs.length > 30 || sumSize(fs) > 250e6) return toast('Share up to 30 items (250 MB) at a time — or use Download');
  const out = [];
  try {
    for (let k = 0; k < fs.length; k++) {
      toast(fs.length > 1 ? 'Preparing ' + (k + 1) + ' of ' + fs.length + '…' : 'Preparing…', { ms: 0 });
      const blob = await (await fetch(fileUrl(fs[k]))).blob();
      out.push(new File([blob], fs[k].fileName, { type: fs[k].fileType || blob.type }));
    }
  } catch (e) { return toast('Couldn’t get the files — try again'); }
  hideToast();
  if (!navigator.canShare({ files: out })) return toast('This browser can’t share these — use Download');
  const go = () => navigator.share({ files: out }).catch(() => {});
  try { await navigator.share({ files: out }); }
  catch (e) { if (e.name === 'NotAllowedError') toast('Ready to share', { action: 'Share', fn: go }); }
}

/* ---------- Full-screen viewer ---------- */
let lb, stage, bgEl, stripEl, infoEl, hudEl, progEl, metaB, metaS, pctBtn, playBtn, selVBtn, fsBtn;
let slides = [], idx = 0, vOpen = false, playing = false, timer = 0, wake = null, stripDirty = true;
let SW = innerWidth, SH = innerHeight, z = { s: 1, x: 0, y: 0 }, idleT = 0, hudT = 0;
const GAP = 24, MAX = 8;
const wrap = (i) => (i % list.length + list.length) % list.length;

function buildViewer() {
  lb = el('div', 'lb');
  lb.setAttribute('role', 'dialog'); lb.setAttribute('aria-modal', 'true'); lb.setAttribute('aria-label', 'Photo viewer');
  lb.innerHTML = '<div class="bg"></div><div class="stage"></div><div class="progress"></div><div class="tools"></div><div class="hud"></div><div class="strip"></div><div class="info glass"></div>';
  stage = lb.querySelector('.stage'); bgEl = lb.querySelector('.bg'); stripEl = lb.querySelector('.strip');
  infoEl = lb.querySelector('.info'); hudEl = lb.querySelector('.hud'); progEl = lb.querySelector('.progress');
  const tools = lb.querySelector('.tools');
  const meta = el('div', 'meta', '<b></b><span></span>');
  metaB = meta.querySelector('b'); metaS = meta.querySelector('span');
  const zg = el('div', 'zgrp');
  pctBtn = el('button', 'pct', '100%'); pctBtn.title = 'Fit to screen (0)';
  pctBtn.onclick = (e) => { e.stopPropagation(); z.s > 1.01 ? animateZ({ s: 1, x: 0, y: 0 }, 260) : zoomAt(2, SW / 2, SH / 2); };
  zg.append(iconBtn(I.zout, 'Zoom out (−)', () => zoomAt(z.s / 1.6, SW / 2, SH / 2)), pctBtn,
    iconBtn(I.zin, 'Zoom in (+)', () => zoomAt(z.s * 1.6, SW / 2, SH / 2)));
  playBtn = iconBtn(I.play, 'Slideshow (Space)', () => setPlaying(!playing));
  selVBtn = iconBtn(I.check, 'Select (S)', () => { setSelecting(true); toggle(cur().f.id); });
  const shareBtn = iconBtn(I.share, 'Share', () => shareFiles([cur().f]));
  if (!navigator.canShare) shareBtn.style.display = 'none';
  fsBtn = iconBtn(I.fs, 'Full screen (F)', toggleFs, 'fsbtn');
  if (!document.fullscreenEnabled) fsBtn.style.display = 'none';
  tools.append(iconBtn(I.close, 'Close (Esc)', () => closeViewer()), meta, zg, playBtn, selVBtn,
    iconBtn(I.info, 'Info (I)', toggleInfo), shareBtn, iconBtn(I.down, 'Download original (D)', downloadCurrent), fsBtn);
  tools.addEventListener('pointerenter', () => { tools.hover = true; });
  tools.addEventListener('pointerleave', () => { tools.hover = false; });
  lb.append(iconBtn(I.left, 'Previous (←)', () => go(-1), 'nav prev'), iconBtn(I.right, 'Next (→)', () => go(1), 'nav next'));
  for (let k = 0; k < 3; k++) {
    const s = { el: el('div', 'slide'), img: el('img', 'pic'), f: null };
    s.img.draggable = false; s.img.alt = '';
    s.el.append(s.img); stage.append(s.el); slides.push(s);
  }
  stripEl.addEventListener('click', (e) => { const t = e.target.closest('img'); if (t) jump(+t.dataset.i); });
  document.body.append(lb);
  gestures();
  document.addEventListener('keydown', onKey);
  document.addEventListener('fullscreenchange', () => {
    const on = !!document.fullscreenElement;
    fsBtn.innerHTML = on ? I.fsx : I.fs;
    setTimeout(relayout, 60);
  });
  addEventListener('popstate', () => { if (vOpen) closeViewer({ fromPop: true }); });
  lb.addEventListener('pointermove', (e) => { if (e.pointerType === 'mouse') pokeChrome(); });
}
const cur = () => slides[1];

function onKey(e) {
  if (e.target.closest && e.target.closest('input,textarea')) return;
  if (!vOpen) {
    if (!main) return;
    if (e.key === '+' || e.key === '=') zoomGrid(-1);
    else if (e.key === '-') zoomGrid(1);
    else if (e.key === 'Escape' && selecting) setSelecting(false);
    else if ((e.ctrlKey || e.metaKey) && e.key === 'a' && selecting) { e.preventDefault(); selectAllToggle(); }
    return;
  }
  if (e.ctrlKey || e.metaKey || e.altKey) return;
  const k = e.key;
  if (k === 'Escape') { if (infoEl.classList.contains('show')) toggleInfo(); else if (z.s > 1.01) animateZ({ s: 1, x: 0, y: 0 }, 240); else closeViewer(); }
  else if (k === 'ArrowRight') go(1);
  else if (k === 'ArrowLeft') go(-1);
  else if (k === 'Home') jump(0);
  else if (k === 'End') jump(list.length - 1);
  else if (k === ' ') setPlaying(!playing);
  else if (k === '+' || k === '=') zoomAt(z.s * 1.5, SW / 2, SH / 2);
  else if (k === '-' || k === '_') zoomAt(z.s / 1.5, SW / 2, SH / 2);
  else if (k === '0') animateZ({ s: 1, x: 0, y: 0 }, 240);
  else if (k === 'i' || k === 'I') toggleInfo();
  else if (k === 'd' || k === 'D') downloadCurrent();
  else if (k === 's' || k === 'S') { setSelecting(true); toggle(cur().f.id); }
  else if (k === 'f' || k === 'F') toggleFs();
  else return;
  e.preventDefault();
}

function measure() { SW = stage.clientWidth || innerWidth; SH = stage.clientHeight || innerHeight; }
function relayout() {
  if (!vOpen) return;
  measure(); slides.forEach(fit); Object.assign(z, clampZ(z)); place(0); applyZoom();
}

/* Each slide is a photo fitted to the screen; zoom transforms the current one. */
function loadSlide(s, i) {
  const f = list[i];
  if (s.f === f) return;
  killVideo(s);
  s.f = f; s.i = i; s.nw = s.nh = 0; s.hd = 'none'; s.ow = s.oh = 0;
  const token = s.token = {};
  s.el.querySelectorAll('.vplay,.fcap').forEach((n) => n.remove());
  s.img.style.transform = ''; s.img.style.visibility = '';
  s.img.className = 'pic blur';
  s.img.alt = f.fileName;
  fit(s);
  s.img.src = thumbUrl(f);
  const full = new Image();
  full.decoding = 'async';
  full.onload = () => {
    if (s.token !== token) return;
    s.nw = full.naturalWidth; s.nh = full.naturalHeight;
    s.img.src = full.src; s.img.classList.remove('blur');
    fit(s);
    if (s === cur()) { Object.assign(z, clampZ(z)); applyZoom(); }
  };
  full.onerror = () => { if (s.token === token) s.img.classList.remove('blur'); };
  full.src = previewUrl(f);
  if (f.kind === 'video') {
    const b = el('button', 'vplay', I.play); b.setAttribute('aria-label', 'Play video');
    b.onclick = (e) => { e.stopPropagation(); playVideo(s); };
    s.el.append(b);
  } else if (f.kind === 'file') {
    const c = el('div', 'fcap', '<div class="nm"></div>');
    c.querySelector('.nm').textContent = f.fileName;
    const b = el('button', '', I.down + '<span>Download · ' + mb(f.size) + '</span>');
    b.onclick = (e) => { e.stopPropagation(); save(fileUrl(f)); toast('Download starting…'); };
    c.append(b); s.el.append(c);
  }
}
function fit(s) {
  if (s.nw && s.nh && s.f && s.f.kind !== 'file') {
    const k = Math.min(SW / s.nw, SH / s.nh, 4);
    s.w = s.nw * k; s.h = s.nh * k;
  } else { s.w = SW; s.h = SH; }
  const st = s.img.style;
  st.width = s.w + 'px'; st.height = s.h + 'px'; st.left = (SW - s.w) / 2 + 'px'; st.top = (SH - s.h) / 2 + 'px';
}
function place(dx) {
  slides.forEach((s, k) => { s.el.style.transform = 'translate3d(' + ((k - 1) * (SW + GAP) + dx) + 'px,0,0)'; });
}
const zoomable = (s) => s && s.f && s.f.kind === 'image';
function bounds(s, sc) { return { mx: Math.max(0, (s.w * sc - SW) / 2), my: Math.max(0, (s.h * sc - SH) / 2) }; }
function clampZ(t) {
  const s = clamp(t.s, 1, MAX), b = bounds(cur(), s);
  return { s, x: clamp(t.x, -b.mx, b.mx), y: clamp(t.y, -b.my, b.my) };
}
function applyZoom() {
  const s = cur();
  s.img.style.transform = z.s === 1 && !z.x && !z.y ? '' : 'translate3d(' + z.x + 'px,' + z.y + 'px,0) scale(' + z.s + ')';
  pctBtn.textContent = Math.round(z.s * 100) + '%';
  lb.classList.toggle('zoomed', z.s > 1.01);
  lb.classList.toggle('nozoom', !zoomable(s));
}

/* One animation at a time; a new touch finishes (or, for momentum, stops) it. */
const ease = (t) => 1 - Math.pow(1 - t, 3);
function tween(dur, fn, done, soft) {
  finishTween();
  if (RM || !dur) { fn(1); if (done) done(); return; }
  const t0 = performance.now();
  const tw = tween.cur = { fn, done, soft, id: 0 };
  const tick = (now) => {
    if (tween.cur !== tw) return;
    const t = Math.min(1, (now - t0) / dur);
    fn(ease(t));
    if (t < 1) tw.id = requestAnimationFrame(tick);
    else { tween.cur = null; if (done) done(); }
  };
  tw.id = requestAnimationFrame(tick);
}
function finishTween(stopOnly) {
  const tw = tween.cur;
  if (!tw) return;
  tween.cur = null; cancelAnimationFrame(tw.id);
  if (stopOnly && tw.soft) return;
  tw.fn(1); if (tw.done) tw.done();
}
function animateZ(t, dur, soft) {
  const f = { s: z.s, x: z.x, y: z.y };
  tween(dur, (k) => { z.s = f.s + (t.s - f.s) * k; z.x = f.x + (t.x - f.x) * k; z.y = f.y + (t.y - f.y) * k; applyZoom(); }, settled, soft);
}
function zoomAt(ns, cx, cy, dur) {
  if (!zoomable(cur())) return;
  ns = clamp(ns, 1, MAX);
  const px = cx - SW / 2, py = cy - SH / 2;
  const t = ns <= 1.001 ? { s: 1, x: 0, y: 0 } : clampZ({ s: ns, x: px - (px - z.x) * ns / z.s, y: py - (py - z.y) * ns / z.s });
  animateZ(t, dur == null ? 220 : dur);
  hud(Math.round(t.s * 100) + '%');
}
function settled() { if (z.s > 1.01) maybeHD(); }
function hud(text, keep, spin) {
  hudEl.innerHTML = spin ? '<span class="spin"></span>' : '';
  hudEl.append(text);
  hudEl.classList.add('show');
  clearTimeout(hudT);
  if (!keep) hudT = setTimeout(() => hudEl.classList.remove('show'), 900);
}
/* Past the preview's resolution, swap in the original for sharp detail. */
function maybeHD() {
  const s = cur(), f = s.f;
  if (!f || f.kind !== 'image' || s.hd !== 'none' || !s.nw) return;
  if (z.s * s.w * (devicePixelRatio || 1) <= s.nw * 1.15) return;
  if (!/^image\/(jpe?g|png|webp|gif|avif|bmp)$/i.test(f.fileType || '') || f.size > 40e6) return;
  s.hd = 'loading';
  const token = s.token, im = new Image();
  hud('Loading full quality…', true, true);
  im.onload = () => {
    if (s.token !== token) return;
    s.hd = 'done'; s.ow = im.naturalWidth; s.oh = im.naturalHeight; s.img.src = im.src;
    if (s === cur()) { hud('Full quality'); fillInfo(); }
  };
  im.onerror = () => { if (s.token === token) { s.hd = 'fail'; hudEl.classList.remove('show'); } };
  im.src = fileUrl(f, true);
}

function gestures() {
  const pts = new Map();
  let g = null, lastTap = { t: 0, x: 0, y: 0 }, tapT = 0, wheelNav = 0, wheelNavT = 0;
  const mid = () => { const [a, b] = [...pts.values()]; return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, d: Math.hypot(a.x - b.x, a.y - b.y) }; };
  const rubber = (v, m) => v > m ? m + (v - m) * .35 : v < -m ? -m + (v + m) * .35 : v;
  const velocity = (h) => {
    const now = performance.now(), r = h.filter((p) => now - p[0] < 120);
    if (r.length < 2) return { x: 0, y: 0 };
    const a = r[0], b = r[r.length - 1], dt = Math.max(8, b[0] - a[0]);
    return { x: (b[1] - a[1]) / dt, y: (b[2] - a[2]) / dt };
  };
  const startPinch = () => {
    const m = mid();
    if (g && g.mode === 'swipe') place(0);
    g = zoomable(cur()) ? { mode: 'pinch', d0: Math.max(m.d, 1), s0: z.s, m0: m, x0: z.x, y0: z.y, last: m } : { mode: 'none' };
  };
  stage.addEventListener('pointerdown', (e) => {
    if (e.target.closest('video,.vplay,.fcap')) return;
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    try { stage.setPointerCapture(e.pointerId); } catch (err) {}
    pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
    finishTween(true);
    if (playing) setPlaying(false);
    if (pts.size === 1) {
      const now = performance.now();
      g = { mode: '', sx: e.clientX, sy: e.clientY, t0: now, bx: z.x, by: z.y, hist: [[now, e.clientX, e.clientY]], type: e.pointerType };
    } else if (pts.size === 2) { clearTimeout(tapT); startPinch(); }
  });
  stage.addEventListener('pointermove', (e) => {
    if (!pts.has(e.pointerId)) return;
    pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (!g) return;
    if (g.mode === 'pinch') {
      if (pts.size < 2) return;
      const m = mid();
      let ns = g.s0 * m.d / g.d0;
      if (ns > MAX) ns = MAX + (ns - MAX) * .25;
      if (ns < 1) ns = Math.max(.5, 1 - (1 - ns) * .5);
      const px = g.m0.x - SW / 2, py = g.m0.y - SH / 2;
      z.s = ns;
      z.x = px - (px - g.x0) * ns / g.s0 + (m.x - g.m0.x);
      z.y = py - (py - g.y0) * ns / g.s0 + (m.y - g.m0.y);
      g.last = m;
      applyZoom(); hud(Math.round(ns * 100) + '%');
      return;
    }
    const dx = e.clientX - g.sx, dy = e.clientY - g.sy, now = performance.now();
    g.hist.push([now, e.clientX, e.clientY]); if (g.hist.length > 8) g.hist.shift();
    if (!g.mode) {
      if (Math.hypot(dx, dy) < 7) return;
      if (z.s > 1.01) g.mode = 'pan';
      else if (Math.abs(dx) > Math.abs(dy)) g.mode = 'swipe';
      else if (dy > 0 && g.type !== 'mouse') g.mode = 'dismiss';
      else g.mode = 'none';
      clearTimeout(tapT);
      stage.classList.add('dragging');
      if (g.mode === 'swipe' || g.mode === 'dismiss') lb.classList.add('drag');
    }
    if (g.mode === 'pan') {
      const b = bounds(cur(), z.s);
      z.x = rubber(g.bx + dx, b.mx); z.y = rubber(g.by + dy, b.my);
      applyZoom();
    } else if (g.mode === 'swipe') {
      const edge = list.length < 2;
      place(edge ? dx * .25 : dx);
    } else if (g.mode === 'dismiss') {
      const k = Math.max(0, dy);
      cur().el.style.transform = 'translate3d(' + dx * .5 + 'px,' + k + 'px,0) scale(' + Math.max(.72, 1 - k / 1100) + ')';
      bgEl.style.transition = 'none';
      bgEl.style.opacity = Math.max(0, 1 - k / 420);
    }
  });
  const end = (e) => {
    if (!pts.has(e.pointerId)) return;
    pts.delete(e.pointerId);
    stage.classList.remove('dragging');
    if (!g) return;
    if (g.mode === 'pinch') {
      if (pts.size === 1) {
        const [r] = [...pts.values()], now = performance.now();
        g = { mode: z.s > 1.01 ? 'pan' : 'none', sx: r.x, sy: r.y, t0: 0, bx: z.x, by: z.y, hist: [[now, r.x, r.y]], type: e.pointerType };
        return;
      }
      if (pts.size) return;
      const m = g.last; g = null;
      if (z.s < 1) animateZ({ s: 1, x: 0, y: 0 }, 260);
      else if (z.s > MAX) zoomAt(MAX, m.x, m.y, 240);
      else animateZ(clampZ(z), 240);
      return;
    }
    if (pts.size) return;
    lb.classList.remove('drag');
    const dx = e.clientX - g.sx, dy = e.clientY - g.sy, v = velocity(g.hist), mode = g.mode, t0 = g.t0;
    g = null;
    if (mode === 'pan') {
      const b = bounds(cur(), z.s);
      if (list.length > 1 && Math.abs(z.x) > b.mx + 80) return go(z.x > 0 ? -1 : 1);
      animateZ(clampZ({ s: z.s, x: z.x + v.x * 280, y: z.y + v.y * 280 }), 480, true);
      return;
    }
    if (mode === 'swipe') {
      const fling = Math.abs(v.x) > .45 && Math.sign(v.x) === Math.sign(dx);
      if (list.length > 1 && (Math.abs(dx) > SW * .18 || fling)) go(dx < 0 ? 1 : -1, dx);
      else { const from = list.length < 2 ? dx * .25 : dx; tween(220, (k) => place(from * (1 - k))); }
      return;
    }
    if (mode === 'dismiss') {
      bgEl.style.transition = '';
      if (dy > 110 || v.y > .6) return closeViewer();
      const s = cur(), from = s.el.style.transform;
      bgEl.style.opacity = '';
      s.el.animate ? s.el.animate([{ transform: from }, { transform: 'translate3d(0,0,0)' }], { duration: 220, easing: 'ease-out' }) : 0;
      place(0);
      return;
    }
    if (mode === 'none' || e.type === 'pointercancel' || performance.now() - t0 > 350) return;
    const now = performance.now();
    if (now - lastTap.t < 300 && Math.hypot(e.clientX - lastTap.x, e.clientY - lastTap.y) < 40) {
      clearTimeout(tapT); lastTap.t = 0;
      if (!zoomable(cur())) return;
      if (z.s > 1.01) animateZ({ s: 1, x: 0, y: 0 }, 280);
      else zoomAt(2.5, e.clientX, e.clientY, 300);
    } else {
      lastTap = { t: now, x: e.clientX, y: e.clientY };
      clearTimeout(tapT);
      tapT = setTimeout(() => { if (infoEl.classList.contains('show')) toggleInfo(); else lb.classList.toggle('bare'); }, 300);
    }
  };
  stage.addEventListener('pointerup', end);
  stage.addEventListener('pointercancel', end);
  stage.addEventListener('wheel', (e) => {
    e.preventDefault();
    const dy = e.deltaY * (e.deltaMode === 1 ? 30 : e.deltaMode === 2 ? SH : 1);
    const dxw = e.deltaX * (e.deltaMode === 1 ? 30 : 1);
    if (!e.ctrlKey && z.s <= 1.01 && Math.abs(dxw) > Math.abs(dy)) {
      wheelNav += dxw; clearTimeout(wheelNavT); wheelNavT = setTimeout(() => { wheelNav = 0; }, 200);
      if (Math.abs(wheelNav) > 90) { go(wheelNav > 0 ? 1 : -1); wheelNav = -1e4 * Math.sign(wheelNav); }
      return;
    }
    if (!zoomable(cur())) return;
    finishTween(true);
    const ns = clamp(z.s * Math.exp(-dy * (e.ctrlKey ? .01 : .0022)), 1, MAX);
    const px = e.clientX - SW / 2, py = e.clientY - SH / 2;
    Object.assign(z, ns <= 1.001 ? { s: 1, x: 0, y: 0 } : clampZ({ s: ns, x: px - (px - z.x) * ns / z.s, y: py - (py - z.y) * ns / z.s }));
    applyZoom(); hud(Math.round(z.s * 100) + '%');
    clearTimeout(stage.wt); stage.wt = setTimeout(settled, 180);
  }, { passive: false });
}

function pokeChrome() {
  if (playing) return;
  lb.classList.remove('bare');
  clearTimeout(idleT);
  idleT = setTimeout(() => {
    const tools = lb.querySelector('.tools');
    if (vOpen && !tools.hover && !infoEl.classList.contains('show') && !cur().vid) lb.classList.add('bare');
  }, 2800);
}

function openViewer(i, tile, play) {
  if (!list.length) return;
  if (stripDirty) buildStrip();
  document.documentElement.classList.add('locked');
  measure();
  vOpen = true;
  slides.forEach((x) => { if (x.el.getAnimations) x.el.getAnimations().forEach((a) => a.cancel()); });
  idx = wrap(i);
  slides.forEach((s) => { s.f = null; });
  slides.forEach((s, k) => loadSlide(s, wrap(idx + k - 1)));
  z = { s: 1, x: 0, y: 0 };
  place(0); applyZoom();
  lb.classList.toggle('single', list.length < 2);
  lb.classList.remove('bare', 'drag');
  bgEl.style.opacity = '';
  lb.classList.add('open');
  document.documentElement.classList.add('locked');
  if (tile && !RM && cur().el.animate) {
    const r = tile.getBoundingClientRect();
    const k = r.width / Math.min(SW, SH);
    cur().el.animate([
      { transform: 'translate3d(' + (r.left + r.width / 2 - SW / 2) + 'px,' + (r.top + r.height / 2 - SH / 2) + 'px,0) scale(' + k + ')', opacity: .3 },
      { transform: 'translate3d(0,0,0) scale(1)', opacity: 1 }], { duration: 300, easing: 'cubic-bezier(.2,.8,.2,1)' });
  }
  history.pushState({ viewer: true }, '');
  afterShow();
  if (play) setPlaying(true);
  else if (HOVER) pokeChrome();
}

function closeViewer(o) {
  o = o || {};
  if (!vOpen) return;
  vOpen = false;
  setPlaying(false);
  finishTween();
  infoEl.classList.remove('show');
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  slides.forEach(killVideo);
  const s = cur(), tile = tiles[idx];
  if (tile) {
    let r = tile.getBoundingClientRect();
    const hh = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--hh')) || 0;
    if (r.top < hh || r.bottom > innerHeight) { scrollBy(0, r.top - (innerHeight - r.height) / 2); r = tile.getBoundingClientRect(); }
    tile.classList.remove('flash'); void tile.offsetWidth; tile.classList.add('flash');
    if (!RM && s.el.animate) {
      const k = r.width / Math.min(SW, SH);
      s.el.animate([{ transform: s.el.style.transform || 'none', opacity: 1 },
        { transform: 'translate3d(' + (r.left + r.width / 2 - SW / 2) + 'px,' + (r.top + r.height / 2 - SH / 2) + 'px,0) scale(' + k + ')', opacity: 0 }],
        { duration: 260, easing: 'cubic-bezier(.2,.8,.2,1)', fill: 'forwards' });
    }
  }
  bgEl.style.transition = ''; bgEl.style.opacity = '0';
  setTimeout(() => {
    if (vOpen) return;
    lb.classList.remove('open', 'zoomed', 'drag');
    bgEl.style.opacity = '';
    slides.forEach((x) => { if (x.el.getAnimations) x.el.getAnimations().forEach((a) => a.cancel()); });
    z = { s: 1, x: 0, y: 0 }; applyZoom(); place(0);
  }, RM ? 0 : 280);
  document.documentElement.classList.remove('locked');
  if (!o.fromPop && history.state && history.state.viewer) history.back();
}

function go(dir, from) {
  if (list.length < 2 || !vOpen) return;
  finishTween();
  const start = from || 0, endX = -dir * (SW + GAP);
  tween(RM ? 0 : 300, (k) => place(start + (endX - start) * k), () => commit(dir));
}
function fadeTo(dir) {
  if (list.length < 2) return;
  finishTween();
  const nx = slides[dir > 0 ? 2 : 0], c = cur();
  nx.el.style.transform = 'translate3d(0,0,0)'; nx.el.style.zIndex = 2; nx.el.style.opacity = 0;
  tween(700, (k) => { nx.el.style.opacity = k; c.el.style.opacity = 1 - k; }, () => {
    nx.el.style.opacity = ''; nx.el.style.zIndex = ''; c.el.style.opacity = '';
    commit(dir);
  });
}
function commit(dir) {
  const old = cur();
  old.img.style.transform = '';
  killVideo(old);
  if (dir > 0) slides.push(slides.shift()); else slides.unshift(slides.pop());
  idx = wrap(idx + dir);
  loadSlide(slides[dir > 0 ? 2 : 0], wrap(idx + dir));
  z ={ s: 1, x: 0, y: 0 };
  place(0); applyZoom();
  afterShow();
}
function jump(i) {
  if (!vOpen) return;
  finishTween();
  idx = wrap(i);
  slides.forEach((s, k) => loadSlide(s, wrap(idx + k - 1)));
  z = { s: 1, x: 0, y: 0 }; place(0); applyZoom();
  if (!RM && cur().el.animate) cur().el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 180 });
  afterShow();
}

function afterShow() {
  const f = cur().f;
  hudEl.classList.remove('show');
  metaB.textContent = (idx + 1) + ' / ' + list.length;
  metaS.textContent = f.at ? f.at.toLocaleString(undefined, { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit' }) : f.fileName;
  const prevCur = stripEl.querySelector('.cur'); if (prevCur) prevCur.classList.remove('cur');
  const th = stripEl.children[idx];
  if (th) {
    th.classList.add('cur');
    const left = th.offsetLeft - stripEl.clientWidth / 2 + th.offsetWidth / 2;
    stripEl.scrollTo({ left, behavior: RM ? 'auto' : 'smooth' });
  }
  [2, -2].forEach((d) => { const n = list[wrap(idx + d)]; if (n && n.kind !== 'file') new Image().src = previewUrl(n); });
  syncSelBtn();
  fillInfo();
  if (playing) restartTimer();
}
function syncSelBtn() {
  const on = selected.has(cur().f.id);
  selVBtn.classList.toggle('on', on);
  selVBtn.title = on ? 'Selected (S)' : 'Select (S)';
}
function buildStrip() {
  stripEl.innerHTML = '';
  const frag = document.createDocumentFragment();
  list.forEach((f, i) => {
    const t = el('img'); t.loading = 'lazy'; t.decoding = 'async'; t.alt = ''; t.draggable = false;
    t.dataset.i = i; t.src = thumbUrl(f);
    frag.append(t);
  });
  stripEl.append(frag);
  stripDirty = false;
}
function toggleInfo() {
  infoEl.classList.toggle('show');
  if (infoEl.classList.contains('show')) lb.classList.remove('bare');
}
function fillInfo() {
  const s = cur(), f = s.f;
  infoEl.innerHTML = '<div class="nm"></div><dl></dl>';
  infoEl.querySelector('.nm').textContent = f.fileName;
  const dl = infoEl.querySelector('dl');
  const row = (k, v) => { const dt = el('dt'), dd = el('dd'); dt.textContent = k; dd.textContent = v; dl.append(dt, dd); };
  if (f.at) row('Taken', f.at.toLocaleString(undefined, { dateStyle: 'full', timeStyle: 'short' }));
  row('Size', mb(f.size));
  row('Type', (f.fileType || 'file').split('/').pop().toUpperCase());
  if (s.ow) row('Dimensions', s.ow + ' × ' + s.oh);
  row('From', data.info.alias);
  const b = el('button', '', I.down + '<span>Download original</span>');
  b.onclick = downloadCurrent;
  infoEl.append(b);
}
function downloadCurrent() { const f = cur().f; save(fileUrl(f)); toast('Downloading ' + f.fileName + '…'); }

function playVideo(s) {
  if (playing) setPlaying(false);
  const v = el('video');
  v.controls = true; v.playsInline = true; v.autoplay = true; v.preload = 'auto';
  v.poster = previewUrl(s.f); v.src = fileUrl(s.f, true);
  v.onerror = () => toast('This video can’t play in the browser — download it instead', { action: 'Download', fn: () => save(fileUrl(s.f)) });
  s.el.querySelectorAll('.vplay').forEach((n) => n.remove());
  s.img.style.visibility = 'hidden';
  s.el.append(v); s.vid = v;
  v.play().catch(() => {});
}
function killVideo(s) {
  if (!s.vid) return;
  s.vid.pause(); s.vid.removeAttribute('src'); s.vid.load(); s.vid.remove(); s.vid = null;
  s.img.style.visibility = '';
  if (s.f && s.f.kind === 'video' && !s.el.querySelector('.vplay')) {
    const b = el('button', 'vplay', I.play); b.setAttribute('aria-label', 'Play video');
    b.onclick = (e) => { e.stopPropagation(); playVideo(s); };
    s.el.append(b);
  }
}

function setPlaying(on) {
  if (on && list.length < 2) return;
  playing = on;
  playBtn.innerHTML = on ? I.pause : I.play;
  playBtn.classList.toggle('on', on);
  lb.classList.toggle('bare', on);
  clearTimeout(timer);
  if (on) {
    if (z.s > 1.01) animateZ({ s: 1, x: 0, y: 0 }, 200);
    killVideo(cur());
    restartTimer();
    if (navigator.wakeLock) navigator.wakeLock.request('screen').then((w) => { wake = w; }).catch(() => {});
  } else {
    progEl.style.transition = 'none'; progEl.style.width = '0';
    if (wake) { wake.release().catch(() => {}); wake = null; }
  }
}
function restartTimer() {
  clearTimeout(timer);
  progEl.style.transition = 'none'; progEl.style.width = '0';
  void progEl.offsetWidth;
  progEl.style.transition = 'width 4s linear'; progEl.style.width = '100%';
  timer = setTimeout(() => fadeTo(1), 4000);
}
function toggleFs() {
  if (!document.fullscreenEnabled) return;
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  else document.documentElement.requestFullscreen().catch(() => {});
}

load();
</script>
</body>
</html>
''';
