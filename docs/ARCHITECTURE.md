# Architecture

## Goal

ClawNode is a macOS SwiftUI app that controls Apple `container` runtime and provides in-app terminal/files/dashboard access for OpenClaw agents.

## Runtime Topology

- Host app: SwiftUI + SwiftTerm UI.
- Host control plane: `AgentManager` executes `/usr/local/bin/container` commands.
- Logical group: one app-level container group (`claw-group-main`) that tracks configured RAM + slot capacity.
- Compute plane: each agent slot maps to one real runtime container name (`claw-agent-1`, `claw-agent-2`, ...).
- Sub-agent plane: sub-agents are logical children persisted under a parent slot and executed within the parent container boundary.
- VM boundary: in Apple `container`, each container runs in its own lightweight VM.
- Guest shell plane: `container exec -i -t <selected-container> /bin/bash` rendered inside SwiftTerm.

## Core Components

- `ClawMarket/ClawMarket/DesignSystem.swift`
  - Single source of truth for UI design tokens.
  - Adaptive semantic colors for both light/dark appearance.
  - Shared spacing/radius/typography primitives for shell surfaces.
- `ClawMarket/ClawMarket/Models/AgentManager.swift`
  - Source of truth for runtime/image/selected-container state.
  - Shell command execution with timeout + structured errors.
  - Lifecycle operations (`build`, `create`, `start`, `stop`, `rm`).
  - Slot runtime discovery (`container ls` + `container ls -a`) for multi-agent UI.
- `ClawMarket/ClawMarket/Views/RootView.swift`
  - App orchestration and selected-agent routing.
  - Polling + host stats collection.
  - Persists per-agent configuration and sub-agent metadata.
- `ClawMarket/ClawMarket/Views/HomeView.swift`
  - Container-group dashboard.
  - Slot hierarchy UI (`Open Claw Agents`) with per-slot runtime state.
  - Nested sub-agent hierarchy and breadcrumb/tab routing.
- `ClawMarket/ClawMarket/Views/TerminalScreen.swift`
  - `NSViewRepresentable` bridge around `LocalProcessTerminalView`.
  - Starts terminal process attached to selected container shell.
- `ClawMarket/ClawMarket/Views/FileBrowserScreen.swift`
  - Container filesystem browser + drag/drop upload for selected container.
  - Supports scoped initial paths for sub-agent workspaces.

## Data and State

- Runtime/container state is computed from CLI output, not cached assumptions.
- `AgentState` tracks selected container state and controls action availability.
- Slot runtime state map tracks all configured slots (`running` / `stopped` / `missing`).
- Terminal sessions are ephemeral; container filesystem persistence is the durable layer.

## Safety + Constraints

- App Sandbox is disabled intentionally so app can execute system CLI.
- Hardened Runtime is enabled for notarized direct distribution path.
- Default memory baseline remains `4096M`.
- If constrained to `2048M`, keep `NODE_OPTIONS=--max-old-space-size=768` to reduce OOM risk.

## Packaging Implication

For distributed builds, runtime and image are bootstrapped at first launch by the app. Containers are created lazily when a user starts an agent slot.
