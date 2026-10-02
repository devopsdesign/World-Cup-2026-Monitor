/* ============================================================
   GOLAZO — landing page behaviour (vanilla JS, no dependencies)
   Everything here is progressive enhancement: the page is fully
   readable and the FAQ/forms work without it.
   CUSTOMIZE: the i18n dictionary, sample stats, and submit().
   ============================================================ */
(() => {
  "use strict";
  document.documentElement.classList.add("js");
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- mobile nav ---------- */
  const burger = $("#hamburger"), links = $("#navLinks");
  burger.addEventListener("click", () => {
    const open = burger.getAttribute("aria-expanded") !== "true";
    burger.setAttribute("aria-expanded", String(open));
    burger.setAttribute("aria-label", open ? "Cerrar menú" : "Abrir menú");
    links.classList.toggle("is-open", open);
  });
  links.addEventListener("click", (e) => { if (e.target.closest("a")) { links.classList.remove("is-open"); burger.setAttribute("aria-expanded", "false"); } });

  /* ---------- scroll reveal ---------- */
  const reveals = $$(".reveal");
  if ("IntersectionObserver" in window && !reduceMotion) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((en) => { if (en.isIntersecting) { en.target.classList.add("is-visible"); io.unobserve(en.target); } });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.1 });
    reveals.forEach((el) => io.observe(el));
  } else {
    reveals.forEach((el) => el.classList.add("is-visible"));
  }

  /* ---------- trust-badge counters ---------- */
  const fmt = new Intl.NumberFormat("es");
  const animateCount = (el) => {
    const target = Number(el.dataset.count), suffix = el.dataset.suffix || "";
    if (reduceMotion) { el.textContent = fmt.format(target) + suffix; return; }
    const t0 = performance.now(), dur = 1400;
    const tick = (t) => {
      const p = Math.min(1, (t - t0) / dur), eased = 1 - Math.pow(1 - p, 3);
      el.textContent = fmt.format(Math.round(target * eased)) + suffix;
      if (p < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  };
  const counters = $$("[data-count]");
  if ("IntersectionObserver" in window) {
    const cio = new IntersectionObserver((es) => es.forEach((en) => { if (en.isIntersecting) { animateCount(en.target); cio.unobserve(en.target); } }), { threshold: 0.6 });
    counters.forEach((c) => cio.observe(c));
  } else counters.forEach(animateCount);

  /* ---------- tabs (modules) ---------- */
  const tabs = $$('[role="tab"]'), panels = $$('[role="tabpanel"]');
  const selectTab = (tab, focus = false) => {
    tabs.forEach((t) => { const on = t === tab; t.setAttribute("aria-selected", String(on)); t.tabIndex = on ? 0 : -1; });
    panels.forEach((p) => { const on = p.id === tab.getAttribute("aria-controls"); p.hidden = !on; if (on) p.classList.add("is-visible"); });
    if (focus) tab.focus();
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener("click", () => selectTab(tab));
    tab.addEventListener("keydown", (e) => {
      const dir = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
      if (!dir) return; e.preventDefault();
      selectTab(tabs[(i + dir + tabs.length) % tabs.length], true);
    });
  });
  // feature cards deep-link into a tab
  $$(".fcard[data-tab]").forEach((c) => c.addEventListener("click", () => { const t = $(`#tab-${c.dataset.tab}`); if (t) selectTab(t); }));

  /* ---------- sample stats (skeleton -> data) ---------- */
  // CUSTOMIZE: replace with fetch("/api/...") to your backend.
  const SAMPLE = {
    scorers: [["Valentina C.", 14], ["Mateo R.", 11], ["Kevin O.", 9], ["Sofía L.", 8]],
    clean:   [["Los Pibes", 7], ["Atlético Barrio", 5], ["La Banda FC", 4], ["Deportivo Norte", 3]],
    heat: [.1,.2,.3,.45,.45,.3,.2,.1, .2,.4,.6,.8,.8,.6,.4,.2, .25,.5,.85,1,1,.85,.5,.25, .2,.4,.6,.8,.8,.6,.4,.2, .1,.2,.3,.45,.45,.3,.2,.1],
  };
  const fillList = (ol, rows) => {
    ol.replaceChildren();
    rows.forEach(([name, n], i) => {
      const li = document.createElement("li"), b = document.createElement("b"), nm = document.createElement("em"), sp = document.createElement("span");
      b.textContent = i + 1; nm.textContent = name; nm.style.fontStyle = "normal"; sp.textContent = n;
      li.append(b, nm, sp); ol.appendChild(li);
    });
  };
  const loadStats = () => {
    $$(".scard").forEach((c) => c.classList.remove("skeleton"));
    fillList($('[data-fill="scorers"]'), SAMPLE.scorers);
    fillList($('[data-fill="clean"]'), SAMPLE.clean);
    const heat = $('[data-fill="heat"]'); heat.replaceChildren();
    SAMPLE.heat.forEach((a) => { const i = document.createElement("i"); i.style.setProperty("--a", a); heat.appendChild(i); });
  };
  setTimeout(loadStats, 900); // simulated network latency so the skeletons show

  /* ---------- testimonials carousel ---------- */
  const car = $("#carousel"), cards = $$(".tcard", car), dots = $(".carousel__dots", car);
  let idx = 0, timer;
  cards.forEach((_, i) => {
    const d = document.createElement("button"); d.type = "button"; d.setAttribute("role", "tab");
    d.setAttribute("aria-label", `Testimonio ${i + 1}`); d.addEventListener("click", () => go(i, true)); dots.appendChild(d);
  });
  const go = (n, manual) => {
    idx = (n + cards.length) % cards.length;
    cards.forEach((c, i) => { c.classList.toggle("is-active", i === idx); c.setAttribute("aria-hidden", String(i !== idx)); });
    $$("button", dots).forEach((d, i) => d.setAttribute("aria-selected", String(i === idx)));
    if (manual) restart();
  };
  const restart = () => { clearInterval(timer); if (!reduceMotion) timer = setInterval(() => go(idx + 1), 6000); };
  $$(".carousel__btn", car).forEach((b) => b.addEventListener("click", () => go(idx + Number(b.dataset.dir), true)));
  car.addEventListener("mouseenter", () => clearInterval(timer));
  car.addEventListener("mouseleave", restart);
  go(0); restart();

  /* ---------- registration wizard ---------- */
  const form = $("#wizard"), steps = $$(".wstep", form), progress = $$(".wizard__progress li", form), done = $(".wdone", form);
  let step = 0;
  const show = (n) => {
    step = n;
    steps.forEach((s, i) => { s.hidden = i !== n; });
    progress.forEach((p, i) => { p.classList.toggle("is-current", i === n); p.classList.toggle("is-done", i < n); });
    const first = steps[n].querySelector("input, select"); if (first) first.focus({ preventScroll: true });
  };
  const validate = (fs) => {
    const err = $(".err", fs); err.hidden = true;
    for (const f of $$("input, select", fs)) {
      if (!f.checkValidity()) {
        if (f.type === "radio") err.textContent = t("err.radio");
        else if (f.type === "checkbox") err.textContent = t("err.consent");
        else if (f.validity.valueMissing) err.textContent = t("err.required");
        else err.textContent = t("err.invalid");
        err.hidden = false; f.focus(); return false;
      }
    }
    return true;
  };
  form.addEventListener("click", (e) => {
    if (e.target.matches("[data-next]")) { if (validate(steps[step])) show(step + 1); }
    if (e.target.matches("[data-prev]")) show(step - 1);
  });
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    if (!validate(steps[step])) return;
    const data = Object.fromEntries(new FormData(form).entries());
    delete data.password; // never log/transmit in plain text from here — hand off to your backend over HTTPS
    submit(data);
  });
  // CUSTOMIZE: POST to your backend / CRM. The resolved promise shows the success panel.
  const submit = async (payload) => {
    console.info("[golazo] registration payload", payload);
    await new Promise((r) => setTimeout(r, 500));
    steps.forEach((s) => (s.hidden = true)); $(".wizard__progress", form).hidden = true; done.hidden = false;
    done.querySelector("h3").focus?.();
  };

  /* ---------- i18n (ES default / EN) ---------- */
  const I18N = {
    es: {}, // Spanish strings are the HTML's own text; captured below on first run
    en: {
      skip: "Skip to content",
      "nav.features": "Features", "nav.stats": "Stats engine", "nav.tournaments": "Tournaments", "nav.pricing": "Pricing", "nav.join": "Join Free",
      "hero.eyebrow": "Amateur football · local leagues · community",
      "hero.title": "Own the Pitch.\nConnect with Your Passion.",
      "hero.sub": "The definitive platform to manage matches, player stats and local leagues.",
      "hero.cta1": "Download the App", "hero.cta2": "Watch Demo",
      "trust.players": "active players", "trust.matches": "matches tracked", "trust.leagues": "partner leagues", "trust.rating": "on App Store & Google Play",
      "feat.title": "Everything that happens on the pitch, in your pocket",
      "feat.live": "Live Stats", "feat.live.d": "Goals, assists and minutes, instantly.",
      "feat.league": "League Organizer", "feat.league.d": "Fixtures, tables and automatic sanctions.",
      "feat.network": "Player Network", "feat.network.d": "Find a team or complete yours.",
      "feat.mvp": "Ratings & MVP", "feat.mvp.d": "Vote the best of every match.",
      "feat.venues": "Pitch Management", "feat.venues.d": "Book and schedule without clashes.",
      "feat.video": "Video Highlights", "feat.video.d": "Your best plays, ready to share.",
      "how.title": "From zero to your first tournament in four steps",
      "how.1": "Create your Profile", "how.1.d": "Position, strong foot, city. Done in 60 seconds.",
      "how.2": "Build your Team or League", "how.2.d": "Invite via WhatsApp. Golazo builds the fixture for you.",
      "how.3": "Log Plays and Goals", "how.3.d": "One tap per event. Works offline and syncs later.",
      "how.4": "Analyze your Performance", "how.4.d": "Heatmaps, streaks and season comparisons.",
      "mod.title": "A Golazo for every role",
      "mod.tab.players": "For Players", "mod.tab.coaches": "For Coaches", "mod.tab.organizers": "For League Organizers", "mod.tab.fans": "For Fans",
      "mock.goals": "goals this season",
      "mod.players.h": "Your amateur career, with pro numbers", "mod.players.p": "A profile with goals, assists, cards and MVPs. Share your card and get invites from teams near you.",
      "mod.players.m": "92% of captains save 3+ hours a week managing their team.",
      "mod.coaches.h": "Line-ups, loads and minutes — no spreadsheets", "mod.coaches.p": "Set your eleven in seconds, track minutes per player and spot who arrives tired at the weekend.",
      "mod.coaches.m": "Heatmaps and per-position comparisons for every match.",
      "mod.org.h": "Fixtures, tables and payments on autopilot", "mod.org.p": "Generate the calendar, collect fees, apply sanctions and publish results — all from your phone.",
      "mod.org.m": "Clash-free pitch booking and automatic reminders to captains.",
      "mod.fans.h": "Follow your league like it's the Champions League", "mod.fans.p": "Live scores, MVP voting, video highlights and the tournament chat in one place.",
      "mod.fans.m": "Goal notifications in under 3 seconds.",
      "mod.explore": "Explore →",
      "stats.title": "The stats engine, in action", "stats.sub": "Preview with sample data. Connect your league to see yours.",
      "stats.scorers": "Top scorers", "stats.clean": "Clean sheets", "stats.heat": "Heatmap",
      "gal.1": "Night match · Thursday League", "gal.2": "Training session", "gal.3": "Community football school", "gal.4": "MVP vote in the app", "gal.5": "The neighbourhood pitch, ready", "gal.6": "Highlight of the round",
      "amb.title": "The community already playing with Golazo", "amb.sample": "Sample profile",
      "amb.1.n": "Captain · North League", "amb.1.d": "Midfielder · 4 seasons · 2 league titles",
      "amb.2.n": "Head Coach · South Academy", "amb.2.d": "Runs 3 age groups · 60 players",
      "amb.3.n": "Organizer · Tuesday Tournament", "amb.3.d": "12 teams · 3 pitches · 180 players",
      "test.title": "What they say on the pitch",
      "test.1.q": "“It saved my life organizing the Tuesday tournament. Fixture, table and payments in one afternoon.”", "test.1.n": "Mariana R.", "test.1.r": "Organizer",
      "test.2.q": "“Finally my goals count somewhere. The heatmap showed me I play too much down the left.”", "test.2.n": "Diego A.", "test.2.r": "Captain",
      "test.3.q": "“I log cards and sanctions from my phone and captains stop arguing. Missing a dark mode on the watch.”", "test.3.n": "Luis P.", "test.3.r": "Referee",
      "reg.title": "Start free in 3 steps", "reg.sub": "No card. No ads. Your data is yours.",
      "reg.legal": "We process your data under GDPR/CCPA. We never sell your information.",
      "wiz.s1": "Role", "wiz.s2": "Platform", "wiz.s3": "Account",
      "wiz.1.l": "How do you play Golazo?", "wiz.role.player": "Player", "wiz.role.coach": "Coach", "wiz.role.org": "Organizer",
      "wiz.pos": "Favourite position / league type", "wiz.pos.ph": "Choose an option",
      "wiz.2.l": "Where do you want to use the app?", "wiz.phone": "Phone (WhatsApp)",
      "wiz.3.l": "Create your account", "wiz.name": "Name", "wiz.pass": "Password", "wiz.pass.h": "Minimum 8 characters.",
      "wiz.consent": "I accept the privacy policy and the fair-play rules.",
      "wiz.next": "Continue", "wiz.back": "Back", "wiz.create": "Create account",
      "wiz.done.h": "Golazo! Your account is ready.", "wiz.done.p": "We sent you the download link by SMS/WhatsApp. Meanwhile, join the community:", "wiz.done.cta": "Join the Golazo WhatsApp",
      "faq.title": "Frequently asked questions",
      "faq.1.q": "How much does Golazo cost?", "faq.1.a": "Players: free forever. Teams: Pro plan from USD 4.99/month with advanced stats. Leagues: Organizer plan per tournament, with built-in fee collection.",
      "faq.2.q": "Does it work offline at the pitch?", "faq.2.a": "Yes. Log goals, cards and substitutions without signal; everything syncs automatically when you're back online.",
      "faq.3.q": "How do stats sync?", "faq.3.a": "Each event is time-stamped on your device and sent encrypted to the cloud. If two people log the same match, Golazo reconciles the events and flags any conflict for the referee.",
      "faq.4.q": "What about my data?", "faq.4.a": "Your data is yours: export or delete it anytime. We comply with GDPR and CCPA, never sell information, and the infrastructure is encrypted at rest and in transit.",
      "faq.5.q": "Can I connect a watch or fitness tracker?", "faq.5.a": "Yes: Apple Watch, Wear OS and Garmin for distance and heart rate. Chest GPS units import via FIT/GPX files.",
      "foot.mission": "We make amateur football feel professional: data, organization and community for every pitch in the world.",
      "foot.links": "Links", "foot.how": "How it works", "foot.community": "Community", "foot.support": "Support", "foot.legal": "Legal",
      "foot.privacy": "Privacy", "foot.terms": "Terms", "foot.fairplay": "Fair play & anti-harassment", "foot.secure": "Encrypted cloud", "foot.status": "all systems operational",
      "mb.download": "Download App", "mb.support": "Support", fab: "Questions? Join the chat",
      "err.radio": "Pick one option to continue.", "err.consent": "You need to accept the policies.", "err.required": "This field is required.", "err.invalid": "Check this field — the format isn't valid.",
    },
  };
  // Spanish error strings (not in the HTML)
  Object.assign(I18N.es, { "err.radio": "Elige una opción para continuar.", "err.consent": "Debes aceptar las políticas.", "err.required": "Este campo es obligatorio.", "err.invalid": "Revisa este campo: el formato no es válido." });
  // Capture the Spanish copy from the DOM so toggling back is lossless.
  $$("[data-i18n]").forEach((el) => { const k = el.dataset.i18n; if (!(k in I18N.es)) I18N.es[k] = el.innerHTML.includes("<br") ? el.innerText : el.textContent; });
  // Nodes that legitimately contain inline links keep their markup: swap only text nodes.
  let lang = localStorage.getItem("golazo.lang") || (navigator.language.startsWith("en") ? "en" : "es");
  const t = (k) => (I18N[lang] && I18N[lang][k]) || I18N.es[k] || "";
  const apply = () => {
    document.documentElement.lang = lang;
    $$("[data-i18n]").forEach((el) => {
      const k = el.dataset.i18n, v = t(k); if (!v) return;
      if (el.querySelector("a")) { // keep links (legal line): replace leading text only
        const tn = el.firstChild; if (tn && tn.nodeType === 3) tn.textContent = v + " ";
      } else if (v.includes("\n")) {
        el.replaceChildren(); v.split("\n").forEach((line, i) => { if (i) el.appendChild(document.createElement("br")); el.appendChild(document.createTextNode(line)); });
      } else el.textContent = v;
    });
    $$("[data-lang]", $("#langToggle")).forEach((s) => s.classList.toggle("is-active", s.dataset.lang === lang));
  };
  $("#langToggle").addEventListener("click", () => { lang = lang === "es" ? "en" : "es"; localStorage.setItem("golazo.lang", lang); apply(); });
  if (lang !== "es") apply();
})();
