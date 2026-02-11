# Phase 5 - Home Screen + Agent Controls

## Scope

Implemented the primary operational home screen with container controls.

## What was implemented

- Built full `HomeView` with:
  - agent status indicator,
  - explicit running/stopped/starting states,
  - Start/Stop actions,
  - Stop confirmation dialog,
  - Open Terminal action,
  - manual Refresh action.
- Wired Home actions in `RootView` to `AgentManager` start/stop/sync methods.
- Added terminal presentation from home via sheet:
  - opens `TerminalScreen(containerName: ...)`.
- Added periodic state polling every 5 seconds while agent is active/stopped.

## Why this design

- Home screen is the operational center and should support one-click common actions.
- Frequent polling keeps UI accurate after sleep/wake or external runtime changes.
- Stop confirmation reduces accidental interruption while preserving persistence guarantees.

## Validation

- `xcodebuild` compile success with signing disabled.
- Home path compiles end-to-end with controls and terminal handoff.

## Files

- `ClawMarket/ClawMarket/Views/HomeView.swift`
- `ClawMarket/ClawMarket/Views/RootView.swift`
