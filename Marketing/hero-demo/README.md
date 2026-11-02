# GitPier product film

[简体中文](README.zh-CN.md)

A dark, native macOS product illustration for the GitPier homepage Hero. React and plain CSS, authored with Stageshow. The desktop design is **1100 × 600**; narrow containers use a **358 × 358 close-up**, with readable controls instead of a scaled-down desktop. One loop lasts about **14 seconds**.

The film opens a repository from the Workspace dashboard, shows automatic Fetch and refreshed remote status, selects a branch for comparison, presents a split diff, and returns through Workspace. `main` stays checked out. All Git data is fictional and local; the film runs no Git commands and accesses no real repositories.

## Preview

Requires Node.js 20.19 or later and npm.

```sh
cd Marketing/hero-demo
npm ci
npm run dev
```

Open [the local preview](http://127.0.0.1:5177/). It includes Pause/Play, Replay, desktop/compact selection, and English/Simplified Chinese. The scene stops offscreen and while the document is hidden. Reduced motion displays the completed comparison.

- Direct capture: [English](http://127.0.0.1:5177/?capture=gitpier), [简体中文](http://127.0.0.1:5177/?capture=gitpier&lang=zh).
- Embed document: [scene](http://127.0.0.1:5177/?scene=1&lang=en).
- Gold references: [hero-demo](http://127.0.0.1:5177/?capture=hero-gold), [dark-hero](http://127.0.0.1:5177/?capture=dark-gold).

## Integrate

```sh
npm run build
npm run preview
```

`dist/` is a static bundle and supports subdirectory hosting. Serve its contents at a same-origin URL such as `/product-film/`. Copy `src/GitPierHero.tsx`, `src/player.css`, and `src/copy.ts` into the host React project; its small message-channel constant may be moved from `playback.ts` to a shared module when integrating. Alternatively import the wrapper from this source package, with a bundler configured for TSX and CSS.

```tsx
import { GitPierHero } from './Marketing/hero-demo/src/GitPierHero'

<GitPierHero src="/product-film/" locale="en" />
```

Props: `src`, `locale` (`en` / `zh`), `autoPlay` (default `true`), `controls` (default `true`), `compact` (default `false`), and `className`. The wrapper sizes from its container. Keep playback controls when using autoplay. The scene document isolates the deterministic clock from the host; pause freezes timers, the pointer, CSS transitions and the spinner together. No clock implementation changes were made to Stageshow.

`src/GitPierScene.tsx` is the illustration itself; `src/story.ts` contains the measured cursor targets and named beats. The direct capture route uses the same scene as the iframe.

## Verify

Google Chrome is required for Stageshow filming; `CHROME_PATH` may select a compatible Chromium binary. Validation artifacts are local and ignored in `.cache/`.

```sh
npm run typecheck
npm run build
npm run verify
npm run verify:subpath
node verification/transitions.mjs
node scripts/class-clash.mjs src
node scripts/layout.mjs http://127.0.0.1:5177/ --select .gp-preview --width 390 --strict --report .cache/layout-390.json
FILM_CHILD=1 node scripts/film.mjs 'http://127.0.0.1:5177/?capture=gitpier' --width 1132 --every 1000 --count 17 --gate --out .cache/loop-wide.png --report .cache/loop-wide.json
FILM_CHILD=1 node scripts/film.mjs 'http://127.0.0.1:5177/?capture=gitpier' --width 390 --every 1000 --count 17 --gate --out .cache/loop-compact.png --report .cache/loop-compact.json
FILM_CHILD=1 node scripts/film.mjs 'http://127.0.0.1:5177/?capture=gitpier' --states --states-for 16000 --gate --out .cache/states-wide.png --report .cache/states-wide.json
FILM_CHILD=1 node scripts/film.mjs 'http://127.0.0.1:5177/?capture=gitpier' --at return-to-workspace --every 60 --count 42 --gate --out .cache/seam.png --report .cache/seam.json
```

Freeze source files while filming. For final rehearsal, use the production preview server at port 5178 to avoid development reloads. Direct capture uses a deterministic 60fps clock; the embedded preview uses live display elapsed time, checked separately by `verify`. Vendor CSS is emitted under `kit/` to preserve stylesheet ownership for Stageshow's checker; authored CSS remains in `assets/`. A green gate is followed by visual review; see [REHEARSAL.md](REHEARSAL.md) for evidence and limits. These commands validate the marketing package, not the native Swift application.

See [NOTICE.md](NOTICE.md) for provenance. No fonts, remote images, analytics or network APIs are needed at runtime.
