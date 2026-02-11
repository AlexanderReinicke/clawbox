# Phase 3 - Welcome + Runtime Install

## Scope

Built first-run onboarding and runtime installation flow.

## What was implemented

- Replaced debug-root as primary app router with state-driven flow:
  - Welcome
  - Runtime install
  - Placeholder handoff to template/home/error phases
- Implemented `WelcomeView` with focused first-run CTA.
- Implemented `RuntimeInstallView` with:
  - install progress states,
  - automatic installer action,
  - manual install fallback,
  - runtime re-check action.
- Added runtime installer orchestration to `AgentManager`:
  - downloads signed package from Apple container release URL,
  - runs privileged installer via `osascript` + admin prompt,
  - starts and verifies runtime service.
- Upgraded `ErrorView` to show concrete error content and retry.

## Why this design

- Onboarding is explicit to reduce confusion for first-time users.
- Automatic installer path minimizes CLI/manual steps for non-technical users.
- Manual fallback and re-check avoid dead-end UX when auto-install fails.
- Root routing by `AgentState` keeps flow deterministic and recoverable.

## Validation

- `xcodebuild` compile success with signing disabled.
- Runtime install view wiring compiles with progress, failure, and retry paths.

## Files

- `ClawMarket/ClawMarket/Models/AgentManager.swift`
- `ClawMarket/ClawMarket/Views/RootView.swift`
- `ClawMarket/ClawMarket/Views/WelcomeView.swift`
- `ClawMarket/ClawMarket/Views/RuntimeInstallView.swift`
- `ClawMarket/ClawMarket/Views/ErrorView.swift`
