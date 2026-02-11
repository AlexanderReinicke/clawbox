# Phase 6 - Error Handling + Polish

## Scope

Hardened the app against operational failures and improved recovery UX.

## What was implemented

- Added file-backed command logging with rotation:
  - path: `~/Library/Logs/ClawMarket/agent.log`
  - rotation at ~1 MB (`agent.log.1`).
- Added factory reset support in `AgentManager`:
  - delete container,
  - delete image,
  - return to setup-required state.
- Improved runtime sync behavior:
  - preserves explicit error states when runtime exists but service start/status fails.
- Upgraded `ErrorView`:
  - retry action,
  - reset environment action,
  - copy error action.
- Added lifecycle polish:
  - resyncs when app becomes active.
- Applied basic app chrome polish:
  - window title set to `ClawMarket`,
  - minimum window size 600x400.

## Why this design

- Logging is necessary for supportability and reproducible debugging.
- Reset is the fastest path out of corrupted or partially configured states.
- Re-sync on activation reduces stale UI after sleep/wake and context switches.

## Validation

- `xcodebuild` compile success with signing disabled.
- Error/reset/copy paths compile and are wired through root flow.

## Files

- `ClawMarket/ClawMarket/Models/AgentManager.swift`
- `ClawMarket/ClawMarket/Views/ErrorView.swift`
- `ClawMarket/ClawMarket/Views/RootView.swift`
- `ClawMarket/ClawMarket/ClawMarketApp.swift`
