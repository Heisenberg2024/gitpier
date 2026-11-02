# Rehearsal: GitPier homepage product film

Gold: `reference/hero-demo` supplies the retained scene, measured cursor targets, press feedback and caused return; `reference/dark-hero` supplies neutral surface depth and restrained status color. Both were copied and filmed before adaptation. GitPier replaces the example products, browser frame, placeholder dashboard, terminal and annotations with its approved icon, native sidebar, repository table, branch health and split diff. No generic KPI cards or decorative satellites are added.

Design: 1100 × 600 desktop; 358 × 358 compact close-up into a landscape window. The page is the ground. The desktop window bleeds below the stage; the compact window bleeds to the right and below. Action targets and the result remain whole.

Beats: Workspace → open `gitpier` → automatic Fetch / updated remote status → Branches → select `feature/sidebar` → Compare → hold the diff → Workspace → next loop. Fetch never merges. Selecting a comparison target never checks out a branch. `main` stays current; dashboard data remains identical across loops. Measured loop duration: **14,066.67ms** for each of two consecutive loops. The completed comparison is the reduced-motion poster.

## Evidence

Local artifacts are ignored under `.cache/rehearsal-final/`; the frozen production bundle is fingerprinted in `build-inputs.json`.

| Check | Evidence | Result |
|---|---|---|
| Desktop loop, including next start | `verified-wide-loop.png` / `.json` / `.log` | Complete 60fps geometry coverage; rehearsal passed |
| 390px viewport, readable compact composition | `verified-compact-loop.*` | Complete coverage; rehearsal passed |
| Opening, every named beat and settled state, both widths | `verified-wide-states.*`, `verified-compact-states.*` | Complete coverage; rehearsal passed |
| Return, reset, seam and following start at exact 66.667ms intervals | `verified-seam.*`, `stepped-seam.*` | Complete coverage; rehearsal passed |
| Compare press and result transition at exact 66.667ms intervals | `compare-press.*`, `stepped-press.*` | Complete coverage; rehearsal passed |
| Reduced-motion poster, English desktop / Chinese compact | `poster-wide.*`, `poster-zh-compact.*` | Still coverage complete; rehearsal passed |
| Host controls at 1200px and 390px; direct scene layout | `layout-host-wide.*`, `layout-host-390.*`, `layout-scene-390.*` | No layout findings; embedded content checked by direct film |
| Pause, keyboard resume, replay, two full loops, resize, reduced motion, offscreen return, Chinese | `acceptance.json` / `.log` | Eight behavioral checks passed |
| Actual live display timing | `acceptance.json` | 40 distinct travel poses; median 16.7ms / max 16.8ms over the 1.8s sample; animation-to-wall-clock ratio ≈ 1.0001 |
| Real production bundle served at `/product-film/` | `subpath.json` / `.log` | Iframe, icon, authored CSS and vendor CSS loaded without errors |
| CSS namespace composition | `class-clash.log` | No overlapping class namespaces |
| Vendor provenance and script syntax | `provenance.json` | 50 vendor/reference/license files unchanged; icon matches approved master; JSON and MJS parse |
| TypeScript and web production build | `../build.log` | Passed; native application not built |

`verification/transitions.mjs` additionally holds the public Stageshow clock between individual screenshots: 52 seam frames and 19 press frames are exactly four 60Hz ticks apart (66.667ms), rather than assuming a screenshot completes within its requested interval. The supplied recorder’s CDP slow-motion mode timed out on this harness; that attempt is not counted as passed.

The capture route uses a deterministic 60fps clock to inspect every authored geometry frame. The preview iframe uses actual native frame elapsed time; the separate live measurement above is not inferred from deterministic recording. Google Chrome **156.0.8078.74**, local macOS, was used. Final films contain no jump/drift or loop-seam findings. Complete coverage and a passed rehearsal gate are distinct from the remaining visual candidates below.

For production filming in this Node 24 harness, use `FILM_CHILD=1 node scripts/film.mjs ...` to invoke the supplied recorder directly without its development-reload wrapper. Some completed wide recorder processes retained a pipe handle after writing their complete reports and gate output; these were reclaimed after preserving the results. Narrow direct runs exited successfully. Gate evidence comes from complete reports and the `rehearsal passed` output; terminating a retained process is not counted as a successful process exit. The supplied validation scripts remain byte-identical. Earlier live screenshots had sampling gaps and were treated as inconclusive, then replaced with the frozen final capture set. No detector, assertion or gate was weakened.

## Visual review and findings

The opening, payoff, full loops, marked states, press transition and seam were inspected beside the gold stills. The repository table and the code comparison dominate at their respective beats. Compact reflows to three repository rows, two local branches and an after-side diff excerpt at full reading size. It keeps the macOS window landscape rather than turning it into a tall phone-like app.

| Finding | Frame and disposition |
|---|---|
| Portrait-shaped compact window | First `opening-compact.png`; replaced with the square close-up and re-filmed. |
| Text landing on a transform | First live loop; retained transform layers on page surfaces; absent from the final findings. |
| Unselected branch glyph inherited a black ink | Full-loop review, Branches beat; assigned the native muted icon ink and re-filmed. |
| Cursor could cover status / button text | Full-loop review; selection now targets empty row space and button presses land inside their right padding; final press and seam re-filmed. |
| Bundled kit CSS misidentified as authored overrides | Original production capture; separate, unmodified vendor CSS under `kit/` and authored CSS under `assets/` preserve their ownership. Zero kit-override findings in final captures; `/product-film/` routing also verified. |
| `near-tangent` | Native adjacent file/diff panes and their 1px dividers, visible in the poster and working-tree frames. They intentionally share a boundary. No control is clipped. |
| `lopsided` | Workspace is a full-width native sidebar selection row, matching GitPier; its spare trailing space is intentional. It is not a compact button. |
| `half-pixel glyph` candidates | Intrinsic text-width groups beside even-sized icons. Reviewed in settled states and the 60ms press/seam frames; no observed landing pop remains. Parent transform layers persist. |
| Near-aligned-label `clipped` candidates | Repository identity uses a box icon and text column; tabs and file bars use smaller glyph lanes. The different indents belong to distinct native controls. Their words and targets remain inside the crop. |

No never-intentional gate findings remain. This is the author's visual review, **not an independent reviewer sign-off**; no subagents were authorized or used.

## Limits

- Fixtures illustrate the workflow; no live Git, network Fetch, credentials or user repositories were accessed.
- Chrome desktop and emulated 390px viewport were checked. Safari, Firefox, physical mobile devices and full VoiceOver acceptance were not checked.
- The visibility handler is implemented. This headless Chrome kept both test tabs visible, so actual hidden-tab behavior is recorded as **not exercised**; offscreen stop/resume was exercised and passed.
- No deployment to a real homepage, public hosting, video/GIF export, native Swift build or native application acceptance was performed. The deliverable is the React animation, reusable wrapper and local preview.
