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
    const close = () => { links.classList.remove('open'); menuBtn.setAttribute('aria-expanded', 'false'); };
    menuBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      const open = links.classList.toggle('open');
      menuBtn.setAttribute('aria-expanded', open);
    });
    $$('a', links).forEach((a) => a.addEventListener('click', close));
    document.addEventListener('click', (e) => { if (links.classList.contains('open') && !links.contains(e.target)) close(); });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && links.classList.contains('open')) { close(); menuBtn.focus(); }
    });
  }

  // Nav: mark the section you're reading.
  const navLinks = $$('.nav-links > a[href^="#"]');
  if (navLinks.length && 'IntersectionObserver' in window) {
    const byId = new Map(navLinks.map((a) => [a.getAttribute('href').slice(1), a]));
    const spy = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (!e.isIntersecting) return;
      navLinks.forEach((a) => a.removeAttribute('aria-current'));
      const a = byId.get(e.target.id);
      if (a) a.setAttribute('aria-current', 'true');
    }), { rootMargin: '-45% 0px -50% 0px' });
    $$('main section[id]').forEach((s) => spy.observe(s));
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

  // Count up to a number once it's on screen.
  const countTo = (el, to) => {
    const show = (v) => (el.textContent = v.toLocaleString('en-US'));
    if (reduce || !('IntersectionObserver' in window)) return show(to);
    show(0);
    const io = new IntersectionObserver((entries) => {
      if (!entries[0].isIntersecting) return;
      io.disconnect();
      const t0 = performance.now(), dur = 1200;
      const tick = (now) => {
        const k = Math.min(1, (now - t0) / dur);
        show(Math.round(to * (1 - Math.pow(1 - k, 4))));
        if (k < 1) requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
      setTimeout(() => show(to), dur + 150); // land on the real number even if frames are throttled
    }, { threshold: 0.5 });
    io.observe(el);
  };

  // ---------- live numbers from the public GitHub API ----------
  // Unauthenticated requests get 60 an hour per visitor IP, so answers are
  // kept in localStorage for a while and reused, an old answer is shown when
  // GitHub can't be reached, and nothing is asked again until a rate limit
  // resets. The page works without any of this: it stays as written, and a
  // number that never arrived is hidden rather than shown wrong.
  const REPO = 'Yeamin-Talukder/ShareBro';
  const API = `https://api.github.com/repos/${REPO}`;
  const FRESH_MS = 30 * 60 * 1000; // reuse an answer for 30 minutes
  const store = {
    get(k) { try { return JSON.parse(localStorage.getItem(k)); } catch (_) { return null; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) { /* private mode, full */ } },
  };
  const LIMIT_KEY = 'sb:gh-limited-until';

  // Resolves with { data, stale } from the network or the cache; rejects only
  // when there is neither. `pick` shrinks the response to what we keep.
  const cachedJSON = (key, url, pick) => {
    const hit = store.get(key);
    const now = Date.now();
    if (hit && now - hit.t < FRESH_MS) return Promise.resolve({ data: hit.d, stale: false });
    const fallback = (why) => (hit ? { data: hit.d, stale: true } : Promise.reject(why));
    if ((store.get(LIMIT_KEY) || 0) > now) return Promise.resolve().then(() => fallback('rate-limited'));
    const ctrl = 'AbortController' in window ? new AbortController() : null;
    const timer = ctrl && setTimeout(() => ctrl.abort(), 8000);
    return fetch(url, { headers: { Accept: 'application/vnd.github+json' }, signal: ctrl && ctrl.signal })
      .then((r) => {
        if (r.ok) return r.json();
        // 403/429 with no requests left: wait for the reset before asking again.
        const left = r.headers.get('x-ratelimit-remaining');
        if (r.status === 429 || (r.status === 403 && left === '0')) {
          const reset = +r.headers.get('x-ratelimit-reset') * 1000 || now + 15 * 60 * 1000;
          store.set(LIMIT_KEY, reset);
        }
        return Promise.reject(r.status);
      })
      .then((json) => {
        const d = pick(json);
        store.set(key, { t: Date.now(), d });
        return { data: d, stale: false };
      })
      .catch(fallback)
      .finally(() => timer && clearTimeout(timer));
  };

  // 999 → "999", 1234 → "1.2k", 12345 → "12k", 1250000 → "1.3M".
  const compact = (n) => {
    if (!Number.isFinite(n) || n < 0) return '';
    if (n < 1000) return String(n);
    const [div, unit] = n < 1e6 ? [1e3, 'k'] : [1e6, 'M'];
    const v = n / div;
    return (v < 10 ? Math.floor(v * 10) / 10 : Math.floor(v)).toString().replace(/\.0$/, '') + unit;
  };
  const plural = (n, one, many) => `${n.toLocaleString('en-US')} ${n === 1 ? one : many}`;

  // Stars and forks: every [data-gh="stars|forks"] gets the short number;
  // its nearest [data-gh-wrap] gets a full-number label and leaves the
  // loading state. If there's no number at all, the badge is hidden and the
  // button still links to GitHub.
  const ghSlots = $$('[data-gh]');
  if (ghSlots.length) {
    cachedJSON('sb:gh-repo', API, (j) => ({ stars: j.stargazers_count, forks: j.forks_count }))
      .then(({ data }) => {
        ghSlots.forEach((el) => {
          const kind = el.dataset.gh, n = data[kind];
          const wrap = el.closest('[data-gh-wrap]') || el;
          wrap.classList.remove('is-loading');
          wrap.removeAttribute('aria-busy');
          if (!Number.isFinite(n)) { wrap.hidden = true; return; }
          el.textContent = compact(n);
          const label = kind === 'stars' ? plural(n, 'star', 'stars') : plural(n, 'fork', 'forks');
          el.setAttribute('title', label);
          const sr = $('.sr-only', wrap);
          if (sr) sr.textContent = `, ${label}`;
          const unit = $('[data-gh-unit]', wrap);
          if (unit) unit.textContent = n === 1 ? unit.dataset.one : unit.dataset.many;
        });
      })
      .catch(() => ghSlots.forEach((el) => {
        const wrap = el.closest('[data-gh-wrap]') || el;
        wrap.classList.remove('is-loading');
        wrap.removeAttribute('aria-busy');
        wrap.hidden = true;
      }));
  }

  // Releases: the latest one's version, sizes and APK links, and how many
  // times the app has been downloaded (APK files only, every release).
  const pickReleases = (list) => {
    const published = list.filter((r) => !r.draft && !r.prerelease);
    const rel = published[0];
    const apks = (rel && rel.assets ? rel.assets : []).filter((a) => a.name.endsWith('.apk'))
      .map((a) => ({ name: a.name, url: a.browser_download_url, size: a.size }));
    return {
      downloads: published.reduce((sum, r) => sum + (r.assets || [])
        .filter((a) => a.name.endsWith('.apk'))
        .reduce((s, a) => s + a.download_count, 0), 0),
      releases: published.length,
      version: rel ? (rel.tag_name || '').replace(/^v/, '') : '',
      apks,
    };
  };
  cachedJSON('sb:gh-releases', `${API}/releases?per_page=100`, pickReleases)
    .then(({ data }) => {
      if (data.downloads > 0) {
        $$('[data-downloads]').forEach((el) => countTo(el, data.downloads));
        $$('[data-releases]').forEach((el) => (el.textContent = data.releases));
        $$('[data-dl-count]').forEach((el) => (el.hidden = false));
      }
      if (!data.version) return;
      const find = (abi) => data.apks.find((a) => a.name.endsWith(`${abi}.apk`));
      const mb = (a) => `${Math.round(a.size / 1048576)} MB`;
      $$('[data-version]').forEach((e) => (e.textContent = `v${data.version}`));
      const arm = find('arm64-v8a');
      if (arm) {
        $$('[data-apk]').forEach((a) => (a.href = arm.url));
        $$('[data-apk-size]').forEach((e) => (e.textContent = mb(arm)));
      }
      ['arm64-v8a', 'armeabi-v7a', 'x86_64'].forEach((abi) => {
        const a = find(abi);
        if (a) $$(`[data-abi="${abi}"]`).forEach((row) => { row.href = a.url; const s = $('span', row); if (s) s.textContent = mb(a); });
      });
    })
    .catch(() => {});

  // Year in the footer.
  $$('[data-year]').forEach((e) => (e.textContent = new Date().getFullYear()));
})();
