// ShareBro website: small, dependency-free behaviour.
(() => {
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];

  // Nav: solid once you scroll, and the mobile menu.
  const nav = $('.nav');
  const onScroll = () => nav && nav.classList.toggle('scrolled', window.scrollY > 10);
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });
  const menuBtn = $('.menu-btn'), links = $('.nav-links');
  if (menuBtn && links) {
    menuBtn.addEventListener('click', () => {
      const open = links.classList.toggle('open');
      menuBtn.setAttribute('aria-expanded', open);
    });
    $$('a', links).forEach((a) => a.addEventListener('click', () => { links.classList.remove('open'); menuBtn.setAttribute('aria-expanded', 'false'); }));
  }

  // Reveal sections as they scroll in.
  const reveals = $$('.reveal');
  if (reduce || !('IntersectionObserver' in window)) reveals.forEach((e) => e.classList.add('in'));
  else {
    const io = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    }), { rootMargin: '0px 0px -8% 0px', threshold: 0.12 });
    reveals.forEach((e) => io.observe(e));
  }

  // Count up the numbers in "the problem".
  const counters = $$('[data-count]');
  const countIO = 'IntersectionObserver' in window && new IntersectionObserver((entries) => entries.forEach((e) => {
    if (!e.isIntersecting) return;
    countIO.unobserve(e.target);
    const el = e.target, to = +el.dataset.count, suffix = el.dataset.suffix || '';
    if (reduce) { el.textContent = to.toLocaleString('en-US') + suffix; return; }
    const t0 = performance.now(), dur = 1400;
    const tick = (now) => {
      const k = Math.min(1, (now - t0) / dur), v = Math.round(to * (1 - Math.pow(1 - k, 4)));
      el.textContent = v.toLocaleString('en-US') + (k === 1 ? suffix : '');
      if (k < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }), { threshold: 0.6 });
  counters.forEach((c) => (countIO ? countIO.observe(c) : (c.textContent = (+c.dataset.count).toLocaleString('en-US') + (c.dataset.suffix || ''))));

  // Hero phone: cross-fade through real screens.
  const cycle = $('.cycle');
  if (cycle && !reduce) {
    const imgs = $$('img', cycle);
    let i = 0;
    setInterval(() => {
      if (document.hidden) return;
      imgs[i].classList.remove('on');
      i = (i + 1) % imgs.length;
      imgs[i].classList.add('on');
    }, 2800);
  }

  // Hero phone tilts gently toward the pointer.
  const stage = $('.stage'), main = $('.stage .main');
  if (stage && main && !reduce && window.matchMedia('(pointer: fine)').matches) {
    stage.addEventListener('pointermove', (e) => {
      const r = stage.getBoundingClientRect();
      const x = (e.clientX - r.left) / r.width - 0.5, y = (e.clientY - r.top) / r.height - 0.5;
      main.style.transform = `rotateY(${x * 14}deg) rotateX(${-y * 10}deg)`;
    });
    stage.addEventListener('pointerleave', () => { main.style.transform = ''; });
  }

  // Screen recordings play only while on screen (saves battery and data).
  const vids = $$('video[data-auto]');
  if ('IntersectionObserver' in window) {
    const vio = new IntersectionObserver((entries) => entries.forEach((e) => {
      const v = e.target;
      if (e.isIntersecting && !reduce) {
        if (v.preload === 'none') v.preload = 'auto';
        v.play().catch(() => {});
      } else v.pause();
    }), { threshold: 0.35 });
    vids.forEach((v) => vio.observe(v));
  }

  // Latest release: version, size and direct APK links from GitHub.
  // The page works without this; it just keeps the buttons current.
  const REPO = 'Yeamin-Talukder/ShareBro';
  fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((rel) => {
      const version = (rel.tag_name || '').replace(/^v/, '');
      const assets = rel.assets || [];
      const find = (abi) => assets.find((a) => a.name.endsWith(`${abi}.apk`));
      const mb = (a) => `${Math.round(a.size / 1048576)} MB`;
      $$('[data-version]').forEach((e) => (e.textContent = `v${version}`));
      const arm = find('arm64-v8a');
      if (arm) {
        $$('[data-apk]').forEach((a) => (a.href = arm.browser_download_url));
        $$('[data-apk-size]').forEach((e) => (e.textContent = mb(arm)));
      }
      ['arm64-v8a', 'armeabi-v7a', 'x86_64'].forEach((abi) => {
        const a = find(abi), row = $(`[data-abi="${abi}"]`);
        if (a && row) { row.href = a.browser_download_url; const s = $('span', row); if (s) s.textContent = mb(a); }
      });
    })
    .catch(() => {});

  // Year in the footer.
  $$('[data-year]').forEach((e) => (e.textContent = new Date().getFullYear()));
})();
