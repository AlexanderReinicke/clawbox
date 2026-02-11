# Phase 8: Orchestration Shell (Spec v2 Foundation)

## Status

- Implemented (foundation pass)

## Goal

Deliver the first concrete implementation pass of the ClawNode orchestration shell UX defined in spec v2:
- dark, edge-to-edge shell layout
- persistent navigation context
- project/agent hierarchy with tabbed working surface
- embedded terminal and file editing workflows in-app

## Implemented in this phase

### 1. Shell layout and visual language

- Replaced the previous light card layout with a dark shell-style UI in `HomeView`.
- Added persistent structure:
  - title bar (node identity + global actions)
  - breadcrumb bar
  - tab bar
  - split workspace (sidebar + content)
  - status bar
- Added design-token style color constants in `HomeView` for consistent dark-mode styling.

### 2. Hierarchy and navigation model

- Added project/agent hierarchy surface in sidebar:
  - project row (`Project X`)
  - nested agents list
- Added dual tab models:
  - project tabs: Home, Dashboard, Settings, Logs
  - agent tabs: Home, Shell, Files, Dashboard, Config, Logs
- Added breadcrumb path updates driven by current selection and tab.
- Added sidebar search/filter for agent hierarchy:
  - filters by agent display name
  - filters by container name
  - filters by nested sub-agent name/ID

### 2.7 Sub-agent hierarchy (logical model, UI-integrated)

- Added a persisted sub-agent model keyed by parent agent slot.
- Sub-agents are rendered as nested rows under each parent agent in the sidebar.
- Added sub-agent create/rename/delete actions in the shell UI.
- Extended selection and breadcrumb context to support:
  - `Project -> Agent -> Sub-agent -> Tab`
- Added sub-agent aware content views across tabs:
  - Home, Shell, Files, Dashboard, Config, Logs.
- Clarified runtime semantics in implementation:
  - sub-agents are logical orchestration entities that run inside the parent agent container/runtime boundary.
  - they are not separate Apple `container` VM instances.

### 2.5 Project Home + Project Dashboard (aggregate view)

- Implemented a real Project Home surface with:
  - health summary card
  - agent grid cards with quick actions
  - lightweight topology summary
  - recent activity section
- Implemented an aggregate Project Dashboard with:
  - node resource overview bars (CPU, memory, load)
  - agent status distribution visualization
  - RAM allocation per-agent breakdown (prefers live usage when available)
  - access-folder coverage widget
  - quick navigation/actions into agent dashboards

### 2.6 Live per-agent runtime snapshots

- Added runtime snapshot collection in `AgentManager` using:
  - `container ls --all --format json`
  - `container stats --no-stream --format json`
- Surfaced per-agent runtime metrics in UI:
  - CPU percent (delta-based)
  - live memory usage/limit
  - process count
  - network RX/TX
  - uptime
  - container IP and dashboard host port

### 3. In-app terminal workflow

- Kept terminal embedded in the app via `TerminalScreen` under the Agent `Shell` tab.
- No external Terminal dependency for default shell workflow.

### 4. File editor foundation (in-app editing)

- Upgraded `FileBrowserScreen` from preview-only to editable workflow:
  - editable text pane (`TextEditor`)
  - modified detection
  - `Save`
  - `Save & Restart`
  - read-only behavior for binary previews
  - file path context callback to parent shell for breadcrumb usage
- Preserved drag-and-drop upload behavior.
- Added `initialPath` support for `FileBrowserScreen` so sub-agent files open directly at the sub-agent workspace root.

### 4.1 File manager operations (in-app)

- Added in-app file system mutation actions in `FileBrowserScreen`:
  - `New File`
  - `New Folder`
  - `Rename`
  - `Delete`
- Added contextual actions via row context menu for files and folders.
- Added validation for entered names before file/folder creation and renaming.
- Added success/failure toast feedback for file mutations.

### 5. Runtime support for file editing

Added new `AgentManager` capabilities:
- `writeFile(path:text:)`
- `restartContainer()`
- `createFile(path:text:)`
- `createDirectory(path:)`
- `renameItem(from:to:)`
- `deleteItem(path:)`
- New error variant: `invalidFileWrite`
- New error variant: `invalidFileMutation`

This provides backend support for in-app editing and restart workflow.

### 6. Notification behavior

- Converted power status from a persistent full-width banner to a dismissible auto-expiring toast in `RootView`.

## Intentionally deferred (next passes)

- Runtime-isolated sub-agent process orchestration beyond metadata/workspace layering
- project-level topology graph
- dashboard widget customization/grid system
- command palette and full keyboard map
- Monaco-grade editor features (multi-tab, diff, minimap, etc.)
- deep-link URL routing state model

## Verification

Build validation command:

```bash
xcodebuild -project ClawMarket/ClawMarket.xcodeproj -scheme ClawMarket -configuration Debug -destination 'platform=macOS' build
```

Result:
- `BUILD SUCCEEDED` on macOS arm64 target.

## Files touched for this phase

- `ClawMarket/ClawMarket/Views/HomeView.swift`
- `ClawMarket/ClawMarket/Views/FileBrowserScreen.swift`
- `ClawMarket/ClawMarket/Models/AgentManager.swift`
- `ClawMarket/ClawMarket/Views/RootView.swift`
- `docs/PHASES/phase-08-orchestration-shell.md`
