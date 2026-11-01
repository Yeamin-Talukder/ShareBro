/// The page a friend's browser shows for a "Find my photos" link: take a
/// selfie (or pick one), it's shrunk here in the browser and checked on the
/// sharing phone, then the friend lands on a gallery of the photos they're
/// in. Talks to `/find/info` and `POST /find`.
const findMePage = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#0F0E12">
<title>Find your photos · ShareBro</title>
<style>
:root{--accent:#D9432B;--on-accent:#fff;--bg:#F6F5F8;--ink:#1A1820;--muted:#5E5A66;--card:#fff;--line:rgba(26,24,32,.1);
--ease:cubic-bezier(.2,.8,.2,1)}
@media (prefers-color-scheme:dark){:root{--accent:#FF8A6B;--on-accent:#2A0D06;--bg:#0F0E12;--ink:#F2EFF5;--muted:#A9A3B3;
--card:#1A1820;--line:rgba(255,255,255,.1)}}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0}
body{font:16px/1.45 system-ui,-apple-system,Roboto,sans-serif;color:var(--ink);background:var(--bg);min-height:100vh;
display:grid;place-items:center;padding:24px 16px}
body::before{content:"";position:fixed;inset:-20%;z-index:-1;pointer-events:none;
background:radial-gradient(40% 35% at 15% 10%,rgba(217,67,43,.26),transparent 70%),
radial-gradient(35% 30% at 90% 20%,rgba(110,91,255,.24),transparent 70%),
radial-gradient(40% 35% at 55% 70%,rgba(43,181,166,.2),transparent 70%);animation:drift 26s ease-in-out infinite alternate}
@keyframes drift{to{transform:translate(4%,3%) rotate(6deg)}}
main{width:100%;max-width:400px;text-align:center}
.card{background:var(--card);border:1px solid var(--line);border-radius:28px;padding:28px 22px}
h1{margin:0 0 6px;font-size:28px;letter-spacing:-.5px;font-weight:800}
p{margin:0;color:var(--muted)}
.from{font-size:14px;margin-bottom:22px}
.face{position:relative;width:168px;height:168px;margin:6px auto 22px}
.face .ring{position:absolute;inset:0;border-radius:50%;border:3px solid var(--line)}
.face .spin{position:absolute;inset:0;border-radius:50%;border:3px solid transparent;border-top-color:var(--accent);
animation:spin 1s linear infinite;display:none}
.face img,.face .ph{position:absolute;inset:10px;width:calc(100% - 20px);height:calc(100% - 20px);border-radius:50%;object-fit:cover}
.face .ph{display:grid;place-items:center;background:color-mix(in srgb,var(--accent) 14%,transparent);color:var(--accent)}
.face .ph svg{width:64px;height:64px}
.face .scan{position:absolute;left:10px;right:10px;height:3px;border-radius:2px;background:var(--accent);top:50%;display:none;
animation:sweep 1.6s ease-in-out infinite alternate}
.face .tick{position:absolute;right:6px;bottom:6px;width:44px;height:44px;border-radius:50%;background:var(--accent);
color:var(--on-accent);display:none;place-items:center;transform:scale(0);transition:transform .4s var(--ease)}
.face .tick svg{width:24px;height:24px}
.working .face .spin,.working .face .scan{display:block}
.done .face .tick{display:grid;transform:scale(1)}
.done .face .ring{border-color:var(--accent)}
@keyframes spin{to{transform:rotate(360deg)}}
@keyframes sweep{from{top:18%}to{top:80%}}
.status{font-size:20px;font-weight:750;margin-bottom:4px;min-height:1.4em}
.hint{font-size:14px;min-height:2.8em}
.actions{display:grid;gap:10px;margin-top:22px}
button,.btn{appearance:none;border:1px solid var(--line);border-radius:999px;min-height:50px;padding:12px 18px;font:inherit;
font-weight:650;cursor:pointer;display:flex;align-items:center;justify-content:center;gap:8px;color:var(--ink);background:var(--card);
transition:transform .12s var(--ease),opacity .2s}
button:active,.btn:active{transform:scale(.96)}
.primary{background:var(--accent);color:var(--on-accent);border-color:transparent}
button svg,.btn svg{width:20px;height:20px}
input[type=file]{display:none}
input.pin{width:100%;font:inherit;font-size:24px;letter-spacing:8px;text-align:center;padding:12px;border-radius:16px;
border:1px solid var(--line);background:var(--bg);color:var(--ink);margin-top:16px}
.hide{display:none!important}
.privacy{font-size:13px;margin-top:18px;padding:0 8px}
@media (prefers-reduced-motion:reduce){body::before,.face .spin,.face .scan{animation:none}}
</style>
</head>
<body>
<main>
<div class="card" id="card">
  <h1 id="title">Find your photos</h1>
  <p class="from" id="from">&nbsp;</p>
  <div class="face">
    <div class="ring"></div><div class="spin"></div>
    <div class="ph" id="ph"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zm0 2c-3.3 0-8 1.7-8 5v1h16v-1c0-3.3-4.7-5-8-5z"/></svg></div>
    <img id="shot" class="hide" alt="Your selfie">
    <div class="scan"></div>
    <div class="tick"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></div>
  </div>
  <div class="status" id="status">Take a selfie</div>
  <p class="hint" id="hint">We'll find every photo you're in and show them to you.</p>
  <input class="pin hide" id="pin" inputmode="numeric" maxlength="4" placeholder="PIN" autocomplete="off">
  <div class="actions" id="actions">
    <label class="btn primary" for="cam"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M9 3 7.2 5H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-3.2L15 3H9zm3 15a5 5 0 1 1 0-10 5 5 0 0 1 0 10z"/></svg><span>Take a selfie</span></label>
    <label class="btn" for="pick"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M21 19V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2zM8.5 13.5l2.5 3 3.5-4.5 4.5 6H5l3.5-4.5z"/></svg><span>Choose a photo of you</span></label>
    <button class="primary hide" id="go">See my photos</button>
  </div>
  <input type="file" id="cam" accept="image/*" capture="user">
  <input type="file" id="pick" accept="image/*">
  <p class="privacy">Your selfie is only used to find you, on the phone sharing these photos, and is deleted right after.</p>
</div>
</main>
<script>
const $=id=>document.getElementById(id);
const q=new URLSearchParams(location.search),link=q.get('f');
const card=$('card'),statusEl=$('status'),hint=$('hint'),pinEl=$('pin'),go=$('go');
let pin=null,pending=null,gallery=null;
function say(s,h){statusEl.textContent=s;hint.textContent=h||''}
function choosing(on){for(const l of document.querySelectorAll('label.btn'))l.classList.toggle('hide',!on)}
async function info(){
  try{
    const r=await fetch('/find/info?f='+encodeURIComponent(link||''));
    if(!r.ok)throw 0;
    const j=await r.json();
    document.title=j.title+' · ShareBro';
    $('from').textContent=j.title+' · from '+j.from;
    if(j.pin){pinEl.classList.remove('hide');hint.textContent='Enter the PIN you were given, then take a selfie.'}
  }catch(e){gone()}
}
function gone(){
  say('This link has ended','Ask for a new QR code.');choosing(false);$('from').innerHTML='&nbsp;';
}
async function shrink(file){
  let src;
  try{src=await createImageBitmap(file,{imageOrientation:'from-image'})}
  catch(e){src=await new Promise((ok,no)=>{const i=new Image();i.onload=()=>ok(i);i.onerror=no;i.src=URL.createObjectURL(file)})}
  const w=src.width,h=src.height,k=Math.min(1,1280/Math.max(w,h));
  const c=document.createElement('canvas');c.width=Math.round(w*k);c.height=Math.round(h*k);
  c.getContext('2d').drawImage(src,0,0,c.width,c.height);
  const blob=await new Promise(ok=>c.toBlob(ok,'image/jpeg',.9));
  return {blob,url:c.toDataURL('image/jpeg',.6)};
}
async function send(blob){
  card.className='card working';choosing(false);
  say('Looking for you…','Checking faces on the other phone. This takes a few seconds.');
  const p=pin||pinEl.value.trim();
  let r;
  try{
    r=await fetch('/find?f='+encodeURIComponent(link)+(p?'&pin='+encodeURIComponent(p):''),
      {method:'POST',headers:{'Content-Type':'image/jpeg'},body:blob});
  }catch(e){card.className='card';choosing(true);return say('Couldn\'t reach the phone','Stay on the same Wi‑Fi as them and try again.')}
  card.className='card';
  if(r.status===401){pending=blob;choosing(true);pinEl.classList.remove('hide');pinEl.focus();return say('Wrong PIN','Check the PIN and try again.')}
  if(r.status===403)return gone();
  if(r.status===404){choosing(true);return say('We couldn\'t find you','Try again facing the camera in good light, or pick a clear photo of you.')}
  if(!r.ok){choosing(true);return say('Something went wrong','Try again in a moment.')}
  const j=await r.json();
  pin=p;gallery=j.sessionId;
  card.className='card done';
  say('Found you, '+j.name.split(' ')[0]+'!',j.count+(j.count===1?' photo':' photos')+' ready for you.');
  go.classList.remove('hide');
  setTimeout(open,1800);
}
function open(){if(gallery)location.href='/?s='+encodeURIComponent(gallery)}
go.onclick=open;
for(const id of ['cam','pick'])$(id).onchange=async e=>{
  const f=e.target.files[0];e.target.value='';if(!f)return;
  try{
    const s=await shrink(f);
    $('ph').classList.add('hide');const img=$('shot');img.src=s.url;img.classList.remove('hide');
    await send(s.blob);
  }catch(err){say('That photo didn\'t open','Try another one.')}
};
pinEl.onkeydown=e=>{if(e.key==='Enter'&&pending)send(pending)};
if(!link)gone();else info();
</script>
</body>
</html>
''';
