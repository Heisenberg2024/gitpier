# GitPier Native Experience Refinement Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan inline. Steps use checkboxes to track local verification.

**Goal:** Improve GitPie's everyday native workflows while retaining Git execution, authentication and recovery guarantees.

**Architecture:** Keep GitService and the per-worktree queue authoritative. Extend the existing operation record for presentation and recovery; use AppKit and SwiftUI for platform interactions and shared visual roles.

**Tech stack:** Swift, SwiftUI, AppKit, UserNotifications, Sparkle, XCTest and the disposable native fixtures.

**Spec:** Codex goal attachment, “GitPier v2.2.0 — macOS 27 原生体验与日常工作流优化”.

## Global constraints

- Work from current main; preserve version 2.1.0 (35), minimum macOS 14, both languages, preferences and existing distribution trust.
- Use local fixture repositories and isolated configuration. No staging, commit, push, tag, release or signing changes. Independent subagent reviews require explicit approval for the frozen scope and reviewer count.
- Complete each stage's scoped verification before the next. Track installed, simulated, local and real-system results separately.

## Review focus

- Background notification settings and Focus, saved Sparkle opt-out, and missing or symbolic-link Finder paths.
- Commit succeeded but Push failed, was cancelled or has an unknown result; retry is Push-only and observes the saved checkpoint.
- Native transfer events can arrive late, repeat or report 100% before Git exits; concurrent operations must stay distinct.
- Existing commit drafts, explicit Amend and formatted code/trailers must keep their meaning.
- Two identities on one host and native credential helpers must preserve routing, isolation and evidence limits.

## Stages

- [x] A — `AppStore`, `CompletionNotifications`, `FinderLocation`, `SettingsView`, `DashboardView`/row, `RootView`, `QuickOpenView`, bundle tooling. Four Core, 11 release tool and 11 upgrade fixture tests; packaged notification-request, Sparkle preference, Finder target and Settings probes; Dashboard native fixture with 20 layouts. Actual Finder presentation and system notification delivery/audio remain separate gates. Evidence: `.cache/v220/phase-a/`.
- [x] B — `OperationProgress`, `OperationsCenter`, `OperationCenter`, `OperationStatusPresentation`, `CommitWorkspace`, `AppStore`. The 17 focused Core tests passed; native formatter/duplicate/Commit & Push, `workflow210`, `commit-review` (111 recorded checks) and `push-recovery` passed. Full integration reruns the affected paths after later changes. Evidence: `.cache/v220/phase-b/`.
- [x] C — Audit `AuthenticationContext`, repository/clone bindings, background Fetch, Remote Check and Push recovery. 73 targeted Core cases including loopback HTTP(S)/SSH and native helpers; foreground native Repository Settings route and fail-closed Fetch passed. Evidence: `.cache/v220/phase-c/`. Independent source review and private service acceptance remain separate gates.
- [x] D — Shared navigation/controls/feedback roles, original overlay scrollbars, and compiler/runtime guards for 27-only chrome. 22 WindowServer captures, 20 Dashboard layout matrix, context assistant with trace, and native unified scrollbars passed in the Debug scopes. Final regression uses the frozen integration candidate. Evidence: `.cache/v220/phase-d/`.
- [x] E — 1,136 Core cases, 90 tool cases, full R2 Debug and Release UI/PTY (104 captures each), native R3 readback/recovery regression, R3 Universal and temporary DMG checks, and eight matched performance runs. The full R3 Rosetta rerun passed with 104 captures. A normal R3 launch passed Quick Open and History keyboard navigation. A signed loopback Sparkle replacement preserved an existing opt-out and the partially staged repository across restart and cold launch. The [delivery record](../../v2.2.0-native-experience.md) records the initial Rosetta failure and pending release-candidate gates.
