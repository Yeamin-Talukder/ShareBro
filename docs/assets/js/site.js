// ShareBro website: small, dependency-free behaviour.
(() => {
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];

  // Nav: solid once you scroll, and the mobile menu.
  const nav = $('.nav'), bar = $('.progress');
  const onScroll = () => {
    if (nav) nav.classList.toggle('scrolled', window.scrollY > 10);
    if (bar) {
      const max = document.documentElement.scrollHeight - window.innerHeight;
      bar.style.transform = `scaleX(${max > 0 ? Math.min(1, window.scrollY / max) : 0})`;
    }
  };
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
      main.style.transform = `translateX(-50%) rotateY(${x * 14}deg) rotateX(${-y * 10}deg)`;
    });
    stage.addEventListener('pointerleave', () => { main.style.transform = ''; });
  }

  // Download button: the arrow opens the list of APK versions.
  $$('.dl-split').forEach((split) => {
    const toggle = $('.dl-toggle', split), items = $$('.dl-menu a', split);
    const set = (open, focusFirst) => {
      split.classList.toggle('open', open);
      toggle.setAttribute('aria-expanded', open);
      if (open && focusFirst) items[0].focus();
    };
    toggle.addEventListener('click', (e) => { e.stopPropagation(); set(!split.classList.contains('open'), e.detail === 0); });
    document.addEventListener('click', (e) => { if (!split.contains(e.target)) set(false); });
    split.addEventListener('keydown', (e) => {
      if (!split.classList.contains('open')) {
        if (e.key === 'ArrowDown' && document.activeElement === toggle) { e.preventDefault(); set(true, true); }
        return;
      }
      const i = items.indexOf(document.activeElement);
      if (e.key === 'Escape') { set(false); toggle.focus(); }
      else if (e.key === 'ArrowDown') { e.preventDefault(); items[(i + 1) % items.length].focus(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
    });
    items.forEach((a) => a.addEventListener('click', () => set(false)));
  });

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

  // FAQ: answers glide open and shut, one at a time.
  const faqs = $$('.faq details');
  faqs.forEach((d) => {
    const ans = $('.ans', d);
    const inner = document.createElement('div');
    inner.className = 'ans-in';
    while (ans.firstChild) inner.appendChild(ans.firstChild);
    ans.appendChild(inner);
  });
  const ease = 'cubic-bezier(.2,.8,.2,1)';
  // Run `done` when the animation ends, or after its duration if the
  // browser never reports the end (e.g. a throttled background tab).
  const after = (anim, ms, done) => {
    let fired = false;
    const once = () => { if (!fired) { fired = true; done(); } };
    anim.onfinish = once;
    setTimeout(() => { anim.cancel(); once(); }, ms + 80);
  };
  const openFaq = (d) => {
    faqs.forEach((o) => o !== d && o.open && closeFaq(o));
    d.open = true;
    if (reduce || !d.animate) return;
    const ans = $('.ans', d);
    d.dataset.busy = '1';
    const a = ans.animate([{ height: '0px', opacity: 0 }, { height: `${ans.scrollHeight}px`, opacity: 1 }], { duration: 420, easing: ease });
    after(a, 420, () => delete d.dataset.busy);
    $('.ans-in', d).animate([{ transform: 'translateY(-10px)' }, { transform: 'none' }], { duration: 520, easing: ease });
  };
  const closeFaq = (d) => {
    if (reduce || !d.animate) { d.open = false; return; }
    const ans = $('.ans', d);
    d.dataset.busy = '1';
    d.classList.add('closing');
    const a = ans.animate([{ height: `${ans.offsetHeight}px`, opacity: 1 }, { height: '0px', opacity: 0 }], { duration: 300, easing: 'cubic-bezier(.4,0,.2,1)', fill: 'forwards' });
    after(a, 300, () => { d.open = false; d.classList.remove('closing'); a.cancel(); delete d.dataset.busy; });
  };
  faqs.forEach((d) => $('summary', d).addEventListener('click', (e) => {
    e.preventDefault();
    if (d.dataset.busy) return;
    if (d.open) closeFaq(d); else openFaq(d);
  }));

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
        const a = find(abi);
        if (a) $$(`[data-abi="${abi}"]`).forEach((row) => { row.href = a.browser_download_url; const s = $('span', row); if (s) s.textContent = mb(a); });
      });
    })
    .catch(() => {});

  // Year in the footer.
  $$('[data-year]').forEach((e) => (e.textContent = new Date().getFullYear()));
})();
