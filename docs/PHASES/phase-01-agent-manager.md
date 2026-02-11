# Phase 1 - Agent Manager

## Scope

Implemented control-plane engine for container lifecycle management.

## What was implemented

- `AgentState` state machine.
- Runtime detection + startup.
- Image existence/build operations.
- Container existence/running checks.
- Container create/start/stop/delete operations.
- Async shell execution helper with:
  - timeout handling,
  - stderr-aware failures,
  - non-blocking execution.
- Phase debug surface in `RootView` to invoke operations.

## Why this design

- Keep all runtime orchestration in one model (`AgentManager`) to avoid state drift.
- Build from CLI output so app can recover after external state changes.
- Use explicit errors to produce actionable UI messaging in later phases.

## Validation

- `xcodebuild` compile success with signing disabled.
- Runtime/image/container actions callable from debug controls.

## Files

- `ClawMarket/ClawMarket/Models/AgentManager.swift`
- `ClawMarket/ClawMarket/Views/RootView.swift`
