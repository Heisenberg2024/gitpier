# GitPier homepage animation

**Goal:** A native-looking, dark React product film for the homepage Hero, designed at 1100 × 600, lasting 12–15 seconds. No native application changes.

**Approach:** Adapt Stageshow's `hero-demo` (measured cursor targets, retained transitions, five beats) and `dark-hero` (neutral surface depth and restrained status color). Use GitPier's own icon and the actual Dashboard, branch health and branch comparison structure. A recording or screenshot cannot meet the requested reusable React implementation; a generic web dashboard would lose the product's identity. The selected approach is an authored React scene with fixture data.

**Architecture:** `GitPierScene.tsx` and `hero.css` contain only the illustration. `GitPierHero.tsx` is an embeddable React wrapper with pause/replay controls; an isolated iframe keeps the Stageshow clock scoped to this demo. `playback.ts` drives that clock with native elapsed frame time. `main.tsx` supplies preview, direct capture and reference routes. Stageshow kit and validation scripts are vendored with their license.

**Constraints:** English default, Simplified Chinese option; responsive compact layout at 358px; reduced motion shows the completed comparison; controls work with keyboard; no network requests for Git or live repository access. No Swift changes, native build, commit, push or publication. Main agent only; no subagents authorized.

**Story:**

1. Open on a populated Workspace dashboard with organized repositories.
2. Pointer opens `gitpier`; its commit workspace appears and automatic Fetch updates remote freshness, preserving local files and branch.
3. Pointer opens Branches, then selects `feature/sidebar` as a comparison target. `main` remains checked out.
4. Pointer presses Compare; a split diff and commit/file counts are the payoff, held for at least two seconds.
5. Pointer presses Workspace; comparison closes as a whole. Hidden repository-only freshness state resets, and the cursor returns to its initial rest position. Dashboard data does not rewind.

## Implementation and verification

- [x] Establish the standalone Vite/React package; copy and film the two gold examples before adapting.
- [x] Build desktop and compact stills using the actual app icon, neutral tokens, native kit chrome, Row and States; inspect opening and payoff.
- [x] Implement measured cursor choreography, named beats and a caused loop reset. Verify elapsed duration.
- [x] Add isolated pause/resume/replay, visibility handling and reduced motion; verify real browser interaction and live frame timing.
- [x] Run typecheck, production web build, Stageshow film gates (wide, 390px, states), close-up transition/seam films, layout and CSS namespace checks. Inspect every generated sheet.
- [x] Record evidence, findings and limitations in REHEARSAL.md; update PROJECT_MEMORY.md and inspect cumulative Git changes without staging.

**Review focus:** preserve native identity at small widths; never imply Fetch merges or checkout occurs; no text replacement pops; no data rewind at the seam; pause freezes both cursor and CSS; resuming hidden/offscreen playback does not skip beats. This reversible marketing artifact receives author visual review and automated checks; no independent reviewer is claimed.
