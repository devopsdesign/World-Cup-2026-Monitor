# Golazo — landing page prototype

A standalone, static marketing landing page for **Golazo**, a soccer app for
players, coaches and local-league organizers. It lives in this repo as a
front-end deliverable only — it is **not** wired into the deployed World Cup
2026 Monitor app, its Docker image, or the K3s manifests. Nothing here
changes the AWS footprint (still Free Tier / $0 when destroyed).

```
src/golazo/
├── index.html      semantic HTML5, Schema.org SoftwareApplication, strict CSP meta
├── css/style.css   mobile-first, dark-mode-first, WCAG-AA palette
├── js/app.js       nav, reveal animations, tabs, carousel, 3-step wizard, ES/EN toggle
└── img/            6 WebP photos (488 KB) + CREDITS.md (licences)
```

## Preview locally

```bash
cd src/golazo
python3 -m http.server 8080      # then open http://localhost:8080/
```

Opening `index.html` directly from the filesystem also works, except the
Google Fonts request (blocked by the file: origin in some browsers).

## What's implemented (maps to the brief)

| # | Section | Notes |
|---|---|---|
| 1 | Hero | Photo background with slow Ken Burns (disabled under `prefers-reduced-motion`), two CTAs, animated trust counters |
| 2 | Features strip | 6 icon cards; each deep-links to a module tab |
| 3 | How it works | 4-step timeline |
| 4 | App modules | Tabs by user type (keyboard-navigable), CSS-drawn phone mockups + photos, benefit microcopy |
| 5 | Stats + gallery | Skeleton loaders → sample data (scorers, clean sheets, heatmap); masonry gallery |
| 6 | Ambassadors | 3 **sample** profile cards (see ethics note below) |
| 7 | Testimonials | Auto-advancing carousel, pause on hover, dots + arrows, **sample** quotes |
| 8 | Onboarding | 3-step wizard with inline validation + success panel; store badge buttons |
| 9 | FAQ | Native `<details>` accordion — works without JS |
| 10 | Footer | Mission, links, support hours, social, legal, version/status chip |
| — | Mobile | Hamburger nav, sticky bottom bar (Download / Support), 44 px tap targets |
| — | Extras | Floating WhatsApp button, ES/EN toggle (persists in `localStorage`), fade-in on scroll |

## Customize before publishing

Search the source for `CUSTOMIZE`. The main points:

- **Logo** — inline SVG in the nav and footer (`.logo`).
- **Colours / type** — tokens at the top of `css/style.css`.
- **Copy** — Spanish is in the HTML; English is the `I18N.en` dictionary in `js/app.js`. Keys are `data-i18n` attributes.
- **Store links / WhatsApp invite** — `href="#"` and `REPLACE_ME` placeholders.
- **Registration backend** — `submit()` in `js/app.js` currently logs the payload and shows the success panel; POST it to your API/CRM over HTTPS. The password field is never sent from this prototype.
- **Live stats** — `SAMPLE` in `js/app.js`; replace with a `fetch()` to your API.
- **Schema.org** — update `aggregateRating` with real store numbers (or remove it).

## Honesty notes

- The **ambassador cards and testimonials are sample copy**. The people in
  the photos are not Golazo users — replace both before going live
  (`img/CREDITS.md` lists each photo's author and licence).
- The trust-badge numbers and the stats panel are illustrative placeholders.
- The Schema.org rating is a placeholder; publishing fabricated review
  markup can get a site penalized.

## Accessibility & performance

Skip link, landmark roles, `aria-*` on tabs/carousel/wizard, visible focus
rings, 44 px targets, `prefers-reduced-motion` honoured, WCAG-AA contrast on
the dark palette, lazy-loaded WebP with explicit dimensions, fonts via
`preconnect` + `display=swap`, hero image `preload`ed.
