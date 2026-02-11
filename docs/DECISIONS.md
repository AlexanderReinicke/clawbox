# Decisions (ADR-lite)

## D-001: Use Debian Node base instead of Alpine

- Status: accepted
- Context: `openclaw` install/runtime failed or was unstable on Alpine due to native dependency + glibc/toolchain expectations.
- Decision: use `node:22-bookworm-slim` and pin `openclaw@2026.2.9`.
- Consequence: larger base image than Alpine, but stable install/runtime.

## D-002: Default container memory baseline is 4 GB

- Status: accepted
- Context: low-memory containers can OOM during `openclaw` startup.
- Decision: set `-m 4096M` for baseline; keep `-m 2048M` as fallback only when host constraints require it.
- Consequence: higher default memory footprint but significantly better startup stability and fewer runtime crashes.

## D-003: Build app control plane around shelling out to `container` CLI

- Status: accepted
- Context: Apple `container` CLI already encapsulates image/container lifecycle behavior we need.
- Decision: use `Process`-based shell execution with timeout/error capture.
- Consequence: robust CLI parsing and process lifecycle handling are critical.

## D-004: Use SwiftTerm for embedded terminal

- Status: accepted
- Context: product requires interactive in-app shell with copy/paste and resize behavior.
- Decision: integrate `SwiftTerm` (`LocalProcessTerminalView`) and attach to `container exec`.
- Consequence: AppKit bridge required (`NSViewRepresentable`) for SwiftUI integration.

## D-005: Automate runtime installation from the app

- Status: accepted
- Context: users may not have Apple `container` runtime installed.
- Decision: add an in-app installer flow (download pkg + admin install + runtime start) with manual fallback.
- Consequence: first-run UX is simpler, but requires robust error handling around privileged operations.

## D-006: Install OpenClaw before switching to non-root user in Dockerfile

- Status: accepted
- Context: installing `openclaw` after `USER agent` causes permission errors writing `/usr/local/lib/node_modules`.
- Decision: run `npm install -g openclaw@2026.2.9` as root, then switch to `agent`.
- Consequence: image build remains reproducible and `openclaw` is available in `/usr/local/bin` for the runtime user.

## D-007: Normalize dashboard access to localhost and enforce gateway auth compatibility

- Status: accepted
- Context: opening Control UI on `http://<container-ip>:18789` caused recurrent browser disconnects:
  - `disconnected (1008): control ui requires HTTPS or localhost (secure context)`
  - `disconnected (1008): device identity required`
- Decision:
  - Create containers with localhost-published dashboard ports per slot (for example `claw-agent-1` => `127.0.0.1:18789`, `claw-agent-2` => `127.0.0.1:18790`).
  - Prefer `http://127.0.0.1:<slot-port>` for dashboard launch based on selected agent slot.
  - During dashboard startup, auto-apply:
    - `gateway.controlUi.allowInsecureAuth=true`
    - `gateway.controlUi.dangerouslyDisableDeviceAuth=true`
  - Use `pgrep -x openclaw-gateway` for reliable gateway process detection.
- Consequence:
  - Dashboard launch is stable and no longer depends on direct container-IP browsing.
  - Local/dev security posture is relaxed for UX stability and should be revisited before production hardening.

## D-008: Represent multi-agent capacity as a logical group, with one real container per agent slot

- Status: accepted
- Context: Apple `container` provides lightweight VM isolation per container. It does not provide a model where multiple runtime containers share one Linux VM boundary in the same way Docker Desktop commonly presents.
- Decision:
  - Keep one app-level "container group" for UX and capacity planning.
  - Map each agent slot to one real container name (`claw-agent-N`).
  - Route terminal/files/dashboard/delete actions to the currently selected slot/container.
- Consequence:
  - Multi-agent behavior is technically accurate to Apple runtime semantics.
  - Resource usage scales per running slot/container and must be surfaced clearly in UI.

## D-009: Adopt IDE-style orchestration shell as primary app surface

- Status: accepted
- Context: The existing card-based interface made project/agent context ambiguous and did not scale for deeper workflows (files, shell, dashboards, config).
- Decision: move to a persistent shell model with:
  - title bar
  - breadcrumb bar
  - tab bar
  - hierarchy sidebar
  - content pane
  - status bar
- Consequence:
  - navigation context is always visible
  - shell/files/dashboard/config flows are unified in one surface
  - implementation complexity increases, but extensibility for future phases is materially better.

## D-010: Implement in-app file editing with save + restart against container filesystem

- Status: accepted
- Context: preview-only files were insufficient for operational workflows; users need direct edits inside agent runtime context.
- Decision:
  - add `AgentManager.writeFile(path:text:)`
  - add `AgentManager.restartContainer()`
  - upgrade file browser to editable text workflow with modified state, save, and save+restart.
- Consequence:
  - ClawNode now supports direct runtime-side file edits without leaving the app.
  - richer editor features (multi-tab/diff/minimap) remain future enhancements.

## D-011: Model sub-agents as logical entities within a parent agent container

- Status: accepted
- Context: users need a visible hierarchy and per-sub-agent workflows, but Apple `container` maps each real container to its own lightweight VM boundary and does not provide "sub-container in same VM" semantics for this use case.
- Decision:
  - persist sub-agents as metadata under a parent agent slot
  - render them as nested entities in sidebar/breadcrumb/content views
  - route shell/files/dashboard actions through the parent container context
  - treat sub-agent workspace as scoped paths (for example `/home/agent/subagents/<id>`)
- Consequence:
  - UX gains multi-entity orchestration without multiplying VM instances
  - sub-agents are currently orchestration-layer entities, not isolated runtime containers
  - future runtime-isolated sub-agent execution requires a different runtime architecture.

## D-012: Support direct in-app file mutations via explicit runtime APIs

- Status: accepted
- Context: file viewing/editing alone was insufficient for operational workflows; users also need lightweight file system management (create, rename, delete) without leaving the app.
- Decision:
  - add explicit `AgentManager` APIs for file mutations:
    - `createFile`
    - `createDirectory`
    - `renameItem`
    - `deleteItem`
  - surface these actions in `FileBrowserScreen` via header actions and row context menus.
  - keep validation and feedback in UI (name validation + success/error toasts).
- Consequence:
  - the in-app Files tab now covers the primary day-to-day file operations end-to-end.
  - operation safety is improved by confirmation on delete and deterministic API boundaries in the manager.

## D-013: Add sidebar hierarchy search as default scaling affordance

- Status: accepted
- Context: once agent/sub-agent counts grow, scanning the full sidebar tree slows down routine navigation.
- Decision:
  - add a persistent sidebar search field in the orchestration shell
  - filter parent agents by name/container ID and nested sub-agents by name/ID
  - keep the interaction lightweight (clear button + inline empty state), without changing selected context automatically.
- Consequence:
  - navigation remains usable for larger setups without introducing new modal flows.
  - hierarchy visibility is user-controlled and reversible with one click.

## D-014: Keep multi-file editor state in app memory with explicit tab model

- Status: accepted
- Context: single-file editing forced context switching and made iterative config work slower.
- Decision:
  - add an explicit `openTabs` model in `FileBrowserScreen`
  - track active tab path separately from directory browsing state
  - preserve unsaved in-memory edits while switching tabs
  - synchronize tab paths when files are renamed/deleted in-app
- Consequence:
  - file editing workflow now supports parallel edits without reopening files repeatedly.
  - tab lifecycle (close/discard prompts/history) remains intentionally lightweight for now.
