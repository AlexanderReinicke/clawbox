# Architecture

## Goal

ClawMarket is a macOS SwiftUI app that controls Apple `container` runtime and provides an embedded terminal into a persistent Linux container.

## Runtime Topology

- Host app: SwiftUI + SwiftTerm UI.
- Host control plane: `AgentManager` executes `/usr/local/bin/container` commands.
- Guest compute plane: Linux container (`claw-agent-1`) based on `clawmarket/default:latest`.
- Guest shell plane: `container exec -i -t claw-agent-1 /bin/bash` rendered inside SwiftTerm.

## Core Components

- `ClawMarket/ClawMarket/Models/AgentManager.swift`
  - Source of truth for runtime/container/image state.
  - Shell command execution with timeout + structured errors.
  - Lifecycle operations (`build`, `create`, `start`, `stop`, `rm`).
- `ClawMarket/ClawMarket/Views/TerminalScreen.swift`
  - `NSViewRepresentable` bridge around `LocalProcessTerminalView`.
  - Starts terminal process attached to container shell.
  - Handles reconnect + termination notifications.
- `ClawMarket/ClawMarket/Views/RootView.swift`
  - Phase debug console currently used to validate manager + terminal.

## Data and State

- Runtime and container state is computed from CLI output, not cached assumptions.
- `AgentState` drives view switching and action availability.
- Terminal sessions are ephemeral; container filesystem persistence is the durable layer.

## Safety + Constraints

- App Sandbox is disabled intentionally so app can execute system CLI.
- Hardened Runtime is enabled to support notarized direct distribution path.
- Default container memory baseline is `2048M` with `NODE_OPTIONS=--max-old-space-size=768`.

## Planned Evolution

- Replace debug root view with full onboarding flow in phases 3-6.
- Add structured logging and error recovery UX.
- Produce signed `.dmg` packaging in phase 7.
