# Orttaai Dashboard Implementation Plan (Individual-First)

**Version**: 1.0  
**Date**: February 23, 2026  
**Status**: In progress (Phases 1-10 engineering/rollout complete; manual QA + screenshots pending)  
**Owner**: Product + Engineering

---

## 1) Purpose

Build a new **Orttaai Home Dashboard** that is useful for a single user (not teams), feels premium/sleek, and remains lightweight.

The dashboard should answer:

1. How much did I dictate today/this week?
2. Is speed/latency improving?
3. What should I adjust next (model, hotkey, audio)?

---

## 2) Product Principles

1. **Individual-first**: No team/org/invite/collaboration features.
2. **Utility-first**: Every module must support user action or understanding.
3. **Privacy-first**: All metrics computed locally from existing local DB.
4. **Lightweight**: Minimal runtime overhead, no heavy rendering libraries.
5. **Design consistency**: Follow `orttaai-design-system.md` tokens and motion rules.

---

## 3) Scope

### In Scope (V1)

1. New Home dashboard window (menu bar accessible).
2. Header greeting + compact stat chips.
3. Hero banner with custom vector artwork style (design source can be SVG; app renders native vector assets).
4. Personal productivity modules:
   - Today Snapshot
   - 7-day trend
   - Top Apps Used
   - Performance Health
   - Quick Actions
   - Recent Dictations
5. Real-time updates from local database changes.

### Out of Scope (V1)

1. Team workspaces
2. Invites/collaboration cards
3. Shared dictionaries/snippets across users
4. Cloud sync/account sign-in
5. Remote analytics/telemetry

---

## 4) Dashboard Information Architecture

### Primary Navigation

Add **Home** to menu bar menu above History:

1. Home
2. History
3. Run Setup...
4. Settings...

### Window Behavior

1. New dedicated NSWindow: `Orttaai Home`.
2. Opens from menu action and app reopen when setup is complete.
3. If setup is incomplete, setup flow remains highest priority.

### Layout (Single Column, Sleek)

1. Header Row
   - Welcome title
   - 3 compact chips (days active, words, avg WPM)
2. Hero Banner Card
   - Left: headline + subcopy + CTA
   - Right: vector illustration
3. Metrics Grid (2 columns)
   - Today Snapshot
   - Performance Health
4. Trend Section
   - 7-day chart (words/day + avg WPM line)
5. Bottom Grid (2 columns)
   - Top Apps Used
   - Quick Actions
6. Recent Dictations (latest 5)

---

## 5) Feature Definitions

### 5.1 Header + Chips

1. Greeting:
   - "Welcome back"
2. Chip A: `Active Days (7d)`
3. Chip B: `Words (7d)`
4. Chip C: `Avg WPM (7d)`

### 5.2 Hero Banner

1. Purpose: contextual guidance, not marketing noise.
2. Dynamic message examples:
   - "Tune your setup for faster dictation."
   - "Your model is ready. Try a quick test."
3. CTA destination:
   - `Open Settings > Model` or `Run Setup...` based on state.

### 5.3 Today Snapshot Card

1. Words today
2. Sessions today
3. Active dictation minutes today
4. Avg WPM today

### 5.4 7-Day Trend Card

1. Bar or area for words/day
2. Optional line overlay for avg WPM/day
3. Empty state messaging if no data

### 5.5 Top Apps Card

1. Rank up to top 5 `targetAppName` by dictation count (7d).
2. Show % share and count.
3. Fallback label: `Unknown App` if nil.

### 5.6 Performance Health Card

1. Avg processing time (7d)
2. Current model id
3. Health badge:
   - Fast / Normal / Slow
4. One contextual recommendation:
   - Example: "Latency high; try smaller model."

### 5.7 Quick Actions Card

1. Open Settings (General)
2. Open Model Settings
3. Run Setup
4. Open Full History

### 5.8 Recent Dictations

1. Show last 5 entries with timestamp + text preview + app.
2. "View all history" action.

---

## 6) Data Model and Metrics

### 6.1 Existing Data Used

From `transcription` table:

1. `createdAt`
2. `text`
3. `targetAppName`
4. `recordingDurationMs`
5. `processingDurationMs`
6. `modelId`

No schema migration required for V1 core metrics.

### 6.2 Metric Formulas

1. `wordCount(text)`: whitespace-token count, trimmed, excluding empties.
2. `sessions`: count of transcriptions.
3. `activeMinutes`: sum(`recordingDurationMs`) / 60000.
4. `avgWPM`: totalWords / max(totalRecordingMinutes, epsilon).
5. `avgProcessingMs`: mean(`processingDurationMs`).
6. `activeDays(7d)`: distinct local dates with >=1 transcription.

### 6.3 Time Windows

1. Today: local calendar day.
2. 7-day: today + previous 6 days.

### 6.4 Local-Only Analytics Rule

1. No outbound network calls for dashboard metrics.
2. No user identifiers.
3. No opt-in analytics prompts for this feature.

---

## 7) Technical Architecture

### New Files (Planned)

1. `Orttaai/UI/Home/HomeView.swift`
2. `Orttaai/UI/Home/HomeViewModel.swift`
3. `Orttaai/UI/Home/HomeHeaderView.swift`
4. `Orttaai/UI/Home/StatChipView.swift`
5. `Orttaai/UI/Home/HomeBannerView.swift`
6. `Orttaai/UI/Home/TodaySnapshotCard.swift`
7. `Orttaai/UI/Home/TrendCardView.swift`
8. `Orttaai/UI/Home/TopAppsCard.swift`
9. `Orttaai/UI/Home/PerformanceHealthCard.swift`
10. `Orttaai/UI/Home/QuickActionsCard.swift`
11. `Orttaai/UI/Home/RecentDictationsCard.swift`
12. `Orttaai/Core/Analytics/DashboardStatsService.swift`
13. `Orttaai/Core/Analytics/DashboardModels.swift`
14. `OrttaaiTests/Core/DashboardStatsServiceTests.swift`

### Modified Files (Planned)

1. `Orttaai/UI/Windows/WindowManager.swift`
2. `Orttaai/UI/MenuBar/StatusBarMenu.swift`
3. `Orttaai/App/AppDelegate.swift`
4. `Orttaai/Design/Spacing.swift`
5. `Orttaai/Data/DatabaseManager.swift` (add dashboard-friendly query helpers)

---

## 8) Visual/Asset Strategy for Banner (SVG Request)

1. Design source can be SVG (`Resources/Artwork/HomeBanner/*.svg`).
2. Runtime app assets should be native vector assets in `Assets.xcassets` (PDF vector recommended for macOS rendering stability).
3. Keep at most 1 illustration variant for V1 to reduce complexity.
4. Optional subtle motion only if:
   - Motion supports meaning
   - `Reduce Motion` is respected

---

## 9) Phased Implementation Plan (Trackable)

### Phase 0: Alignment and Wireframe (0.5 day)

- [ ] DASH-0.1 Finalize module list for V1 (no team modules).
- [ ] DASH-0.2 Confirm text/copy for all cards.
- [ ] DASH-0.3 Confirm banner art direction and export format.
- [ ] DASH-0.4 Lock window size and responsive min behavior.

**Exit Criteria**

1. Final approved wireframe and content map.

### Phase 1: Window + Navigation Plumbing (0.5 day)

- [x] DASH-1.1 Add `homeWindow` to `WindowManager`.
- [x] DASH-1.2 Implement `showHomeWindow()` and lifecycle methods.
- [x] DASH-1.3 Add Home menu item in `StatusBarMenu`.
- [x] DASH-1.4 Wire Home action in `AppDelegate`.
- [x] DASH-1.5 Update reopen behavior to route to Home when setup is complete.

**Exit Criteria**

1. Home window opens reliably from menu and reopen.
2. Existing setup/settings/history flows remain unaffected.

### Phase 2: Data Aggregation Layer (1 day)

- [x] DASH-2.1 Create `DashboardModels.swift` domain models.
- [x] DASH-2.2 Implement `DashboardStatsService` metric computation.
- [x] DASH-2.3 Add query helpers in `DatabaseManager` for date-window fetches.
- [x] DASH-2.4 Implement local date bucketing for 7-day trend.
- [x] DASH-2.5 Build recommendation rules for Performance Health card.
- [x] DASH-2.6 Add unit tests for edge cases and formula correctness.

**Exit Criteria**

1. Metrics are deterministic and tested.
2. Zero dependency on external services.

### Phase 3: Home UI Scaffolding (1 day)

- [x] DASH-3.1 Implement `HomeView` shell with scroll container and section spacing.
- [x] DASH-3.2 Build header + chips components.
- [x] DASH-3.3 Build hero banner card and CTA handling.
- [x] DASH-3.4 Build Today Snapshot card.
- [x] DASH-3.5 Build Top Apps and Quick Actions cards.
- [x] DASH-3.6 Build Recent Dictations list card.

**Exit Criteria**

1. Full static UI with real data wiring placeholders.
2. Visual consistency with design tokens.

### Phase 4: Trend + Live Refresh + Interaction (0.75 day)

- [x] DASH-4.1 Implement 7-day trend chart using Swift Charts.
- [x] DASH-4.2 Add real-time DB observation updates.
- [x] DASH-4.3 Add empty states for all modules.
- [x] DASH-4.4 Hook quick actions to existing windows/routes.

**Exit Criteria**

1. Dashboard updates without restart after new transcriptions.
2. User can navigate to key actions in one click.

### Phase 5: Polish and Quality (0.75 day)

- [x] DASH-5.1 Add loading/skeleton states with restrained motion.
- [x] DASH-5.2 Add accessibility labels, keyboard nav, reduced-motion handling.
- [x] DASH-5.3 Validate spacing/contrast typography against design system.
- [ ] DASH-5.4 Run manual QA on empty/new/power-user data profiles.
- [ ] DASH-5.5 Add/update docs and screenshots (docs done, screenshots pending).

**Exit Criteria**

1. Dashboard feels production-ready.
2. No regressions in setup/history/settings.

---

### Phase 6: Unified Home Workspace (0.75 day)

- [x] DASH-6.1 Add left sidebar navigation shell in Home window.
- [x] DASH-6.2 Route Home/History/Settings menu actions into Home sections.
- [x] DASH-6.3 Host Settings + Model + History views inside Home workspace.
- [x] DASH-6.4 Replace recent list with compact table-style rows.
- [x] DASH-6.5 Add row action buttons (copy/delete) and full transcript modal.
- [x] DASH-6.6 Add responsive behavior for smaller widths (collapsed sidebar + compact modules).

**Exit Criteria**

1. Primary navigation no longer requires multiple pop-up windows.
2. Recent dictations are compact, action-oriented, and scannable.

---

### Phase 7: Hardening and Cleanup (0.5 day)

- [x] DASH-7.1 Remove residual multi-window routing paths (Home remains primary workspace).
- [x] DASH-7.2 Expand unit test coverage for recent table data shaping (limit, preview sanitization, app fallback).
- [x] DASH-7.3 Add database-level delete tests to protect compact-row actions.
- [x] DASH-7.4 Update tracker/QA docs for unified Home architecture.

**Exit Criteria**

1. No active code paths require legacy Settings/History popup windows.
2. Recent dictation row behavior is covered by deterministic unit tests.

---

### Phase 8: Rollout Controls (0.5 day)

- [x] DASH-8.1 Add local rollout toggle in app settings for Home auto-open behavior.
- [x] DASH-8.2 Gate app-reopen default routing behind rollout toggle.
- [x] DASH-8.3 Mark Home menu as preview while soft-launch toggle is off.
- [x] DASH-8.4 Update rollout docs/checklists for staged launch.

**Exit Criteria**

1. Home workspace can be exposed without forcing default reopen behavior.
2. Rollout state is explicit and reversible through local settings.

---

### Phase 9: Default Home Reopen (0.25 day)

- [x] DASH-9.1 Set `homeWorkspaceAutoOpenEnabled` default to `true`.
- [x] DASH-9.2 Keep preview behavior available when toggle is explicitly set to `false`.
- [x] DASH-9.3 Update rollout docs/checklist to reflect Home default reopen.

**Exit Criteria**

1. Home is the default destination when reopening app windows after setup.
2. Soft-launch behavior can still be restored locally without code changes.

---

### Phase 10: Stakeholder Sign-off (0.25 day)

- [x] DASH-10.1 Consolidate rollout state and verification logs.
- [x] DASH-10.2 Capture final stakeholder acceptance for Home dashboard rollout.
- [x] DASH-10.3 Mark rollout checklist as complete.

**Exit Criteria**

1. `DASH-ROLL-4` is complete in the master checklist.
2. A dated sign-off artifact exists in the project folder.

---

## 10) Suggested V1.1 / V2 Features (Still Individual-First)

### V1.1 (Shortly After V1)

1. Daily personal word goal + streak.
2. Model advisor card with one-click suggestion.
3. "Latency trend" mini-chart.

### V2

1. Dictation quality insights (short clips, retries, processing spikes).
2. Weekly digest screen (local summary).
3. Per-app drilldown page from Top Apps card.

---

## 11) Acceptance Criteria

1. User sees relevant personal usage data within 1 second of opening Home.
2. Dashboard contains no team/collaboration features.
3. All metrics derive from local DB only.
4. Home can be opened from menu and app reopen flow.
5. Home sections include Overview, History, Settings, and Model.
6. Empty-state experience is clear for first-time users.
7. Existing setup flow remains unchanged and functional.

---

## 12) Testing Plan

### Unit Tests

- [ ] Stats formulas:
  - [ ] word counting edge cases
  - [ ] WPM division safety
  - [ ] date bucketing correctness
  - [ ] active-day computation
- [ ] recommendation logic:
  - [ ] fast/normal/slow thresholds
  - [ ] advice text selection

### Integration Tests

- [ ] Home window can open/close repeatedly.
- [ ] Menu actions route correctly.
- [ ] Live updates after dictation completion.

### Manual QA Matrix

- [ ] No transcription history
- [ ] Light history (1-10 records)
- [ ] Heavy history (500 records)
- [ ] Mixed app names and nil app names
- [ ] Large/short recordings

---

## 13) Risks and Mitigations

1. **Risk**: Dashboard drifts into "analytics app" complexity.  
   **Mitigation**: Lock V1 to six modules and one CTA per module.

2. **Risk**: Rendering/perf overhead with charts and frequent updates.  
   **Mitigation**: Batch updates; avoid expensive recomputation on every frame.

3. **Risk**: Visual inconsistency with existing dark utility style.  
   **Mitigation**: Enforce token-only colors/spacing/typography.

4. **Risk**: Incorrect metrics due to tokenization/date logic.  
   **Mitigation**: Unit tests with fixture datasets and timezone coverage.

---

## 14) Delivery and Rollout

1. Build behind a local feature toggle during development (`homeWorkspaceAutoOpenEnabled`).
2. Soft-launch in app with Home menu item first (Home labeled preview while toggle is off).
3. Home is now default on reopen (`homeWorkspaceAutoOpenEnabled = true` by default).
4. Stakeholder rollout sign-off: complete (February 23, 2026).
5. Keep setup modal single-purpose and lightweight.

---

## 15) Definition of Done

All of the below must be true:

1. All Phase 1-10 engineering checkboxes complete.
2. Unit tests for dashboard metrics and recommendations pass.
3. Manual QA matrix complete with no P1/P2 defects.
4. Documentation updated with dashboard behavior.
5. Stakeholder sign-off on visual polish and usefulness.

---

## 16) Implementation Notes for Next Execution Cycle

When implementation starts, begin in this order:

1. Phase 1 (window/nav)
2. Phase 2 (data service + tests)
3. Phase 3 and 4 (UI + interactions)
4. Phase 5 (polish + QA)
5. Phase 6 (unified navigation + compact data table)

This sequence keeps risk low by validating navigation and data correctness before visual polish.
