# Orttaai Dashboard Phase 8 QA Log

**Date**: February 23, 2026
**Scope**: Rollout controls (soft-launch behavior + default routing gate)

## Implemented

1. Added `homeWorkspaceAutoOpenEnabled` to `AppSettings` as local rollout control.
2. App reopen behavior now checks the rollout toggle:
   - `true`: reopening with no visible windows opens Home Overview.
   - `false` (soft-launch): Home does not auto-open on reopen.
3. Home menu entry now shows `Home (Preview)` while soft-launch toggle is off.
4. Explicit Home/History/Settings menu actions still open the Home workspace sections for direct access.

## Automated Validation

1. Command: `xcodebuild -project Orttaai.xcodeproj -scheme Orttaai -configuration Debug -destination 'platform=macOS' test`
2. Result: `TEST SUCCEEDED`

## Manual Validation Pending

- [ ] Verify menu title changes between `Home` and `Home (Preview)` when toggling `homeWorkspaceAutoOpenEnabled`
- [ ] Verify app reopen behavior when toggle is `false` (no auto-open)
- [ ] Verify app reopen behavior when toggle is `true` (Home opens)
