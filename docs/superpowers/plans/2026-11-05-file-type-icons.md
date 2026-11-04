# File Type Icons Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans in this session. No subagents, staging, commits, pushes or publication are authorized.

**Goal:** Make file types recognizable from their icons, following the supplied JetBrains examples.

**Architecture:** Keep filename classification, bundled vector loading and image caching in one application component. AppKit cells and SwiftUI file views share it; Git operations and repository state stay with their existing owners.

**Tech Stack:** Swift, SwiftUI, AppKit; vendored MIT Material Icon Theme SVG assets at a fixed upstream revision. No new package or runtime network dependency.

**Spec:** User's two attached screenshots and request in this chat. The choices below are implementation decisions.

## Global Constraints

- Preserve existing uncommitted work and Index state; work in the current checkout so its UI changes remain integrated.
- Preserve filename status colors, conflict/submodule indicators, checkboxes, selection, context menus, row heights and shared scrollbars.
- Resolve by filename only, including deleted and remote files. Do not inspect contents or depend on installed editors.
- Cover common source, scripts, documents, media and configuration files; unknown files retain a generic document icon.
- Honor Colored file icons in every consumer; retain shape/detail in monochrome and legibility in light/dark themes.
- Retain source URLs, hashes, revision and full upstream license. Keep both READMEs in sync.

## Review Focus

- Exact filenames and compound suffixes take precedence over generic extensions.
- Case-insensitive extensions, dotfiles, Unicode/spaces, deleted paths and unknown/extensionless names resolve safely.
- Reused native cells clear old tint, status and type images when changing rows or appearance.
- Cached images stay bounded by the bundled icon set and retain transparency and contrast in monochrome.
- Resources load from the packaged application as well as the SwiftPM development bundle.

## Task 1: Shared icons and file consumers

- [x] Add a native acceptance scope that fails when Swift, Python, TypeScript, Markdown and Docker rows share one icon; run through `Scripts/ui-acceptance.sh`.
- [x] Add `Sources/GitPier/FileTypeIcon.swift`: deterministic filename resolver, bounded shared image cache, AppKit image API and SwiftUI `FileTypeIcon(path:size:)`.
- [x] Vendor vector assets plus revision/hash manifest under `Sources/GitPier/Resources/FileIcons`; retain their license under `Resources/Licenses` and update `THIRD_PARTY_NOTICES.md`.
- [x] Integrate native changes rows, Diff tabs/header, History, Stash, branch comparison, conflicts, patch review, LFS, remote review and workspace file search.
- [x] Expand native acceptance for naming precedence, resource rendering, cache reuse, row reuse, themes, monochrome, selection/checks and flat/tree modes.

## Task 2: Verification and delivery

- [x] Run the focused native scope and existing file-scroll acceptance with a temporary fixture; inspect actual light/dark screenshots.
- [x] Build through `Scripts/build-app.sh` to an isolated output; verify packaged resources and focused scope from that executable.
- [x] Update both READMEs and PROJECT_MEMORY.md with scope, results and evidence; check cumulative unstaged/staged/untracked changes.
- [x] Provide a Chinese cumulative Conventional Commit message without staging or committing.

## Execution notes

- Native execution follows the user's autonomous local-edit instructions. No independent agent review is authorized or claimed.
- Core behavior is unchanged; focused application verification is appropriate instead of repeating unrelated Git/authentication tests.
- RED: `.cache/file-type-icons/red.log` reports one image for five file types. GREEN: Debug 376 checks/eight screenshots, plus the existing 226/1,000-file scrolling and native-control scope. One compile correction unwrapped the failable `CIImage(bitmapImageRep:)` initializer; no runtime assertion was removed or relaxed.
- Packaged arm64 Release 2.1.0 (35) passed the same 376 checks/eight screenshots; strict signing, bundle verifier, all 73 SVG hashes and packaged license passed. Source inputs remained stable. The disposable application copy/preferences were removed; normal instance and `dist` preserved. Evidence: `.cache/file-type-icons/verification-summary.json`. First RED to final pass 606.98 seconds; build 134.74 seconds, overlapping the native file-scroll run. 0 subagents; response/token breakdown unavailable.

## Follow-up: ignore files

The user requests the same neutral prohibition icon for every ignore format, tries a solid glyph, then restores the previous outline style. Resolve case-insensitive names ending in `ignore`, common Git global-ignore aliases and `.git/info/exclude` before other filename associations; do not match words in ordinary source/document names. The current choice is the shared native `nosign` outline template, retaining the adaptive secondary color in both colored and monochrome modes. No new asset or package is needed.

- [x] Extend the existing native scope with 22 ignore filenames across both themes and color settings, plus six non-ignore boundary cases. RED fails on `.gitignore` against its previous Git logo.
- [x] Update the shared resolver/renderer and retain the bundled SVG checks for the 71 asset types.
- [x] Reproduce the later outline-to-solid mismatch, replace the glyph with `slash.circle.fill`, and pass Debug 470 checks/eight captures.
- [x] Verify the native scope and refreshed isolated Release package; inspect the real ignore rows and update evidence/project memory.

Intermediate solid glyph (superseded by the outline restoration below): Debug and packaged arm64 Release each passed 470 checks/eight captures; signing/bundle verification, all 73 asset hashes/license and 310 stable source inputs passed. Temporary copy/preferences cleaned up; test package refreshed at the existing `.cache/file-type-icons/release/GitPier.app` path. Build 104.38 seconds; ignore RED through solid-package acceptance 458.97 seconds. No Core/scrollbar code changed and those suites were not repeated. Historical evidence: `.cache/file-type-icons/ignore/solid/verification-summary.json`.

## Current choice: restore the previous outline

- [x] Restore `nosign` and the outline expectation; all 310 source/resource/script hashes match the earlier passing outline Debug build, reusing its 470 checks/eight captures.
- [x] Rebuild the arm64 Release test package through `Scripts/build-app.sh`; the isolated packaged scope freshly passes 470 checks/eight captures, signing/bundle verification, all 73 asset hashes/license and stable source inputs.
- [x] Preserve the normal instance and `dist`, remove temporary app/preferences, and update bilingual docs/project memory.

Evidence: `.cache/file-type-icons/ignore/outline/verification-summary.json`. Restored inputs to final pass 121.04 seconds; build 102.21 seconds. No extra Core/file-scroll runs or subagents; response/token breakdown unavailable.
