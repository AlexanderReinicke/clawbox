# Phase 4 - Template Selection + Setup Progress

## Scope

Implemented first-time environment provisioning flow.

## What was implemented

- Built `TemplateSelectionView` with a single "Default" template card and launch action.
- Built `SetupProgressView` with:
  - active step messaging,
  - spinner for long operations,
  - failure state with retry action.
- Added setup orchestration in `RootView`:
  - `buildImage()` (when image missing),
  - `createContainer()`,
  - `startContainer()`,
  - `sync()` after completion.
- Added launch-state guards to prevent duplicate setup runs.

## Why this design

- Explicit setup stages reduce user uncertainty during long image build.
- Retry at setup layer keeps failures recoverable without restarting app.
- Conditional image build avoids expensive rebuilds on returning users.

## Validation

- `xcodebuild` compile success with signing disabled.
- Flow compiles end-to-end from template selection to setup completion path.
- Container-level smoke validation:
  - rebuilt `clawmarket/default:latest`,
  - created and started `claw-agent-1`,
  - verified `openclaw --version` works as `agent`.

## Files

- `ClawMarket/ClawMarket/Views/TemplateSelectionView.swift`
- `ClawMarket/ClawMarket/Views/SetupProgressView.swift`
- `ClawMarket/ClawMarket/Views/RootView.swift`
