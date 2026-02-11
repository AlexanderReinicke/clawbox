# Phase 2 - Terminal Integration

## Scope

Integrated SwiftTerm terminal into app and attached it to container shell sessions.

## What was implemented

- `TerminalScreen` as UI shell with reconnect UX.
- `TerminalProcessView` (`NSViewRepresentable`) around `LocalProcessTerminalView`.
- Process execution target:
  - `/usr/local/bin/container exec -i -t claw-agent-1 /bin/bash`
- Terminal styling for readability and a focused ops-oriented look.
- Termination callback and reconnect token flow.
- Root debug view button to open terminal when container is running.

## Why this design

- `LocalProcessTerminalView` gives proper PTY behavior for interactive shells.
- Reconnect token pattern allows deterministic terminal process recreation.
- Overlay on disconnect gives a clear recovery action instead of silent failure.

## Validation

- `xcodebuild` compile success with SwiftTerm integration.
- Terminal view launches in app with attached container exec process.

## Files

- `ClawMarket/ClawMarket/Views/TerminalScreen.swift`
- `ClawMarket/ClawMarket/Views/RootView.swift`
