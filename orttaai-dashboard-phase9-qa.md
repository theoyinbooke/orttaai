# Orttaai Dashboard Phase 9 QA Log

**Date**: February 23, 2026
**Scope**: Default Home reopen rollout

## Implemented

1. Updated `homeWorkspaceAutoOpenEnabled` default to `true` in `AppSettings`.
2. Home now defaults to standard menu title (`Home`) unless toggle is explicitly set to `false`.
3. Existing preview fallback path remains available via local toggle (`Home (Preview)`).

## Automated Validation

1. Command: `xcodebuild -project Orttaai.xcodeproj -scheme Orttaai -configuration Debug -destination 'platform=macOS' test`
2. Result: `TEST SUCCEEDED`

## Manual Validation Pending

- [ ] Verify clean install defaults to Home auto-open on app reopen
- [ ] Verify setting `homeWorkspaceAutoOpenEnabled = false` restores preview behavior
