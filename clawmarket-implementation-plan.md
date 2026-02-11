# ClawMarket macOS App — Implementation Plan (Final)

## What We're Building

A macOS SwiftUI app that lets users launch a persistent, isolated Linux container on their Mac. The container is a clean Alpine Linux with essential CLI tools (bash, curl, git, node, python). Users interact via an embedded terminal. They can install whatever they want inside (e.g. `npm install -g openclaw`) and it all persists across stop/start/app close.

**Final result:** User downloads app → setup flow → gets an isolated Linux terminal → installs whatever they want → closes app → reopens → everything is still there.

### Key Risks / Constraints (from Phase 0 validation)
- **Base image/runtime compatibility:** `openclaw` is not reliable on Alpine for our use case; default image should be Debian-based (`node:22-bookworm-slim`) with `openclaw` pinned (currently `openclaw@2026.2.9`).
- **Container memory requirements:** low-memory containers can crash `openclaw` with Node OOM; default agent container to `-m 4096M`, set `NODE_OPTIONS=--max-old-space-size=768`, and use `-m 2048M` only as constrained fallback.
- **Runtime installation permissions:** initial `container` CLI install and first kernel setup require admin privileges and explicit first-run setup UX.
- **Gateway auth + browser security context:** Control UI over non-`localhost` HTTP can fail with secure-context/device-auth errors; app must handle token/auth flow and recommended connection mode explicitly.
- **Distribution model constraint:** architecture fits notarized direct distribution (outside App Store); Mac App Store sandboxing is a likely blocker for shelling out to `container`.

---

## Phase 0: Project Setup (Ivan — manual, before dev starts)

**Goal:** Xcode project exists with dependencies, container CLI verified working on dev machine.

### 0.1 — Machine requirements
- Mac with Apple Silicon (M1/M2/M3/M4)
- macOS 26 (Tahoe)
- Xcode 26

### 0.2 — Install and verify Apple's `container` CLI
```bash
# Download from: https://github.com/apple/container/releases
curl -LO https://github.com/apple/container/releases/download/0.8.0/container-0.8.0-installer-signed.pkg
sudo installer -pkg container-0.8.0-installer-signed.pkg -target /

# Start the system service (first run also installs a Linux kernel — say Y)
container system start

# Verify
container --version
container system status
```

### 0.3 — Verify the container lifecycle we'll be automating
```bash
# Test create → start → exec → install stuff → stop → start → verify persistence

container create --name lifecycle-test alpine:latest
container start lifecycle-test
container exec -i -t lifecycle-test /bin/sh

# Inside:
#   apk add curl nodejs npm
#   npm install -g openclaw
#   echo "persistence test" > /root/test.txt
#   exit

container stop lifecycle-test
container start lifecycle-test
container exec -i -t lifecycle-test /bin/sh

# Inside — verify:
#   cat /root/test.txt          → "persistence test"
#   which openclaw              → should exist
#   exit

# If create/start doesn't persist, test alternative:
# container run -d --name lifecycle-test alpine:latest sleep infinity
# Then stop/start and verify. Document which approach works.

container stop lifecycle-test
container rm lifecycle-test
```

**⚠️ Document results.** If `container create` + `start` doesn't persist filesystem changes, we need `container run` with `sleep infinity` instead. This changes the agent manager code slightly.

### 0.4 — Test `container build` with a Dockerfile
```bash
mkdir /tmp/clawtest && cat > /tmp/clawtest/Dockerfile << 'EOF'
FROM alpine:latest
RUN apk add --no-cache bash curl wget git openssh-client jq python3 py3-pip nodejs npm nano vim htop ripgrep fd
RUN adduser -D -s /bin/bash agent
USER agent
WORKDIR /home/agent
RUN echo 'PS1="agent@claw:\w\$ "' >> /home/agent/.bashrc
CMD ["sleep", "infinity"]
EOF

container build -t clawmarket/default:latest /tmp/clawtest
container image ls  # verify clawmarket/default appears

# Test it
container run -d --name build-test clawmarket/default:latest
container exec -i -t build-test /bin/bash
# Should drop into bash as agent@claw:~$
# exit
container stop build-test
container rm build-test
```

### 0.5 — Create Xcode project
1. Xcode → File → New → Project → macOS → App
2. Interface: **SwiftUI**
3. Language: **Swift**
4. Product Name: **ClawMarket**
5. Organization Identifier: `com.clawmarket`
6. Deployment Target: **macOS 26.0**

### 0.6 — Add SwiftTerm dependency
1. Xcode → File → Add Package Dependencies
2. URL: `https://github.com/migueldeicaza/SwiftTerm`
3. Dependency Rule: Up to Next Major Version

### 0.7 — Configure signing & capabilities
1. Target → Signing & Capabilities
2. **App Sandbox: OFF** (we need to shell out to `/usr/local/bin/container`)
3. **Hardened Runtime: ON** (needed for notarization later)
4. Add entitlement: `com.apple.security.network.client = YES`

### 0.8 — Add Dockerfile to project
1. Create a file called `Dockerfile` (no extension) in the project directory
2. Paste the Dockerfile content from 0.4
3. In Xcode: select the file → Target Membership → check ClawMarket
4. In Build Phases → Copy Bundle Resources → verify `Dockerfile` is listed
5. This ensures it ships at `ClawMarket.app/Contents/Resources/Dockerfile`

### 0.9 — Set up file structure
```
ClawMarket/
├── ClawMarketApp.swift
├── Models/
│   └── AgentManager.swift
├── Views/
│   ├── RootView.swift
│   ├── WelcomeView.swift
│   ├── RuntimeInstallView.swift
│   ├── TemplateSelectionView.swift
│   ├── SetupProgressView.swift
│   ├── HomeView.swift
│   ├── TerminalScreen.swift
│   └── ErrorView.swift
├── Resources/
│   └── Dockerfile
└── Assets.xcassets/
```
Create empty Swift files for each. They'll be filled in across phases.

**Deliverable:** A project that builds and shows a blank SwiftUI window. All files exist (empty or with placeholder views). SwiftTerm compiles.

---

## Phase 1: Agent Manager — Container Lifecycle via CLI

**Goal:** A Swift class that can check for the container CLI, build an image, create/start/stop/delete a container, and report status. No UI yet — just the engine, verified with print statements or unit tests.

### 1.1 — Shell helper
Create a private async function in `AgentManager.swift` that runs `/usr/local/bin/container` with arguments and returns stdout. Must handle:
- Non-zero exit codes → throw error with stderr content
- Timeout (if the process hangs)
- Running on a background thread (not blocking UI)

```swift
// Signature:
@discardableResult
private func shell(_ args: String...) async throws -> String
```

### 1.2 — Runtime detection
```swift
func checkRuntime() async -> Bool
```
- Check if `/usr/local/bin/container` exists via `FileManager`
- If it exists, run `container system status` to check if apiserver is running
- If apiserver is not running, attempt `container system start`
- Return true if CLI exists AND apiserver is running

### 1.3 — Image management
```swift
func imageExists() async -> Bool
func buildImage() async throws
```
- `imageExists()`: run `container image ls`, check if output contains `clawmarket/default`
- `buildImage()`: 
  - Copy `Dockerfile` from app bundle (`Bundle.main`) to a temp directory
  - Run `container build -t clawmarket/default:latest <tempdir>`
  - Clean up temp directory

### 1.4 — Container lifecycle
```swift
func containerExists() async -> Bool
func containerIsRunning() async -> Bool
func createContainer() async throws
func startContainer() async throws
func stopContainer() async throws
func deleteContainer() async throws
```
- Container name is hardcoded: `"claw-agent-1"`
- `containerExists()`: run `container ls -a`, check if `claw-agent-1` appears
- `containerIsRunning()`: run `container ls`, check if `claw-agent-1` appears (without `-a` only shows running)
- `createContainer()`: `container create --name claw-agent-1 clawmarket/default:latest`
- `startContainer()`: `container start claw-agent-1`
- `stopContainer()`: `container stop claw-agent-1`
- `deleteContainer()`: stop if running, then `container rm claw-agent-1`

### 1.5 — State machine
```swift
@Published var state: AgentState

enum AgentState {
    case checking         // initial launch, checking runtime
    case noRuntime        // container CLI not installed
    case needsImage       // CLI ready, image not built yet
    case needsContainer   // image ready, container not created
    case stopped          // container exists, not running
    case starting         // container booting
    case running          // container running, ready for exec
    case error(String)    // something went wrong
}
```
- On init, call a `sync()` method that walks through checks and sets the right state
- `sync()` logic: check runtime → check image → check container exists → check container running → set state

### 1.6 — Verification
Write a simple test view or use `print()` in `onAppear` to verify:
- App launches → `AgentManager.sync()` runs → state is `noRuntime` or `needsImage` or `running` etc.
- Call `buildImage()` → verify image appears in `container image ls`
- Call `createContainer()` → `startContainer()` → verify `containerIsRunning()` returns true
- Call `stopContainer()` → `startContainer()` → exec in via terminal manually and verify files persisted

**Deliverable:** `AgentManager.swift` is complete and tested. All container operations work. State machine correctly reflects reality. No UI yet beyond a debug view.

---

## Phase 2: Terminal View — SwiftTerm Integration

**Goal:** An embedded terminal in the app that attaches to a running container's shell via `container exec -it`.

### 2.1 — Basic SwiftTerm wrapper
Create `TerminalScreen.swift` as an `NSViewRepresentable` wrapping `LocalProcessTerminalView` from SwiftTerm.

```swift
struct TerminalScreen: NSViewRepresentable {
    let containerName: String
    
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: .zero)
        tv.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.startProcess(
            executable: "/usr/local/bin/container",
            args: ["exec", "-i", "-t", containerName, "/bin/bash"]
        )
        return tv
    }
    
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
```

### 2.2 — Test standalone
Create a temporary test view that:
1. Starts the container (if not running) via `AgentManager`
2. Shows `TerminalScreen(containerName: "claw-agent-1")`
3. Verify: can type commands, see output, install packages, create files

### 2.3 — Handle terminal lifecycle
- Terminal process dies when container stops → show "Agent stopped" overlay
- When container starts again → re-create terminal process
- When user navigates away from terminal → process should stay attached (container keeps running)
- When user comes back → reconnect (new exec session — previous shell history visible in new bash session)

### 2.4 — Terminal polish (minimal)
- Set reasonable default size (80x24 minimum)
- Dark background, light text (standard terminal colors)
- Allow window resize → terminal resizes
- Copy/paste support (Cmd+C when text selected = copy, Cmd+V = paste)

**Deliverable:** Working terminal that drops you into bash inside the container. You can type, run commands, install packages, and it all works. Terminal reconnects when navigating back.

---

## Phase 3: Welcome + Runtime Install Screens

**Goal:** First two screens of the app flow — welcome and container CLI installation.

### 3.1 — WelcomeView
Simple centered screen:
- App icon/logo placeholder (text is fine for now)
- Headline: "Run your agent locally and securely"
- Subtitle: "Fully isolated from your system data."
- "Get Started" button
- Button triggers navigation to next screen (either RuntimeInstall or TemplateSelection depending on state)

### 3.2 — RuntimeInstallView
Shown only if `container` CLI is not found at `/usr/local/bin/container`.

- Message: "ClawMarket needs Apple's container runtime to run agents on your Mac."
- "Install Now" button
- On click:
  1. Show progress indicator ("Downloading...")
  2. Download `.pkg` from GitHub releases using `URLSession` or `curl` via `Process`
  3. Run installation using `osascript -e 'do shell script "installer -pkg /tmp/container-installer.pkg -target /" with administrator privileges'` — this shows the macOS password dialog
  4. Run `container system start` (this auto-installs the Linux kernel on first run)
  5. On success → navigate to TemplateSelection
  6. On failure → show error with "Try Again" and "Install Manually" (link to GitHub releases page)

### 3.3 — Fallback manual install
If automated install fails (sandboxing issues, permission denied, etc.):
- Show instructions: "Download and install from [link]"
- Show "I've installed it, check again" button
- Button re-runs `checkRuntime()` and proceeds if found

### 3.4 — Navigation wiring
In `RootView.swift`, use the `AgentManager.state` to determine which view to show:
- `.checking` → spinner
- `.noRuntime` → RuntimeInstallView
- `.needsImage` or `.needsContainer` → TemplateSelectionView
- `.stopped` / `.running` → HomeView
- `.error` → ErrorView

First-time users see: Welcome → (Install) → Template → Setup → Home
Returning users see: Home (directly)

**Deliverable:** New users get guided through installation. Returning users skip straight to home. Runtime detection works reliably.

---

## Phase 4: Template Selection + Setup Progress

**Goal:** User picks a template (only "Default" for now), app builds image and creates container.

### 4.1 — TemplateSelectionView
- Heading: "Choose a template for your agent"
- Single card:
  - Title: "Default"
  - Description: "Alpine Linux with bash, curl, git, python3, node, and common CLI tools. A clean slate — install anything you need."
  - "Launch" button
- Footer: "More templates coming soon..."
- "Launch" triggers image build + container creation

### 4.2 — SetupProgressView
Shown during image build + container creation. Displays:
- Progress message (changes as steps complete):
  - "Building environment..." (during `container build`)
  - "Creating your agent..." (during `container create`)
  - "Starting up..." (during `container start`)
- A progress indicator (indeterminate spinner — we can't easily get % from `container build`)
- No cancel button for MVP (simplicity)

### 4.3 — Setup orchestration
When user clicks "Launch" on the template:
1. Navigate to SetupProgressView
2. `AgentManager.buildImage()` — takes ~30-60 sec
3. `AgentManager.createContainer()`
4. `AgentManager.startContainer()`
5. Update state to `.running`
6. Navigate to HomeView

Error handling:
- If `buildImage()` fails → show error, offer "Retry"
- If `createContainer()` fails → check if container already exists (maybe from previous attempt), try starting it
- If `startContainer()` fails → show error with container logs if available

### 4.4 — Skip setup on return
If image already exists AND container already exists → skip straight to HomeView. The setup screens only appear for first-time users or after a factory reset (delete agent).

**Deliverable:** First-time user clicks "Launch" → sees progress → lands on Home with a running agent. Takes ~1-2 min total for first setup. Subsequent launches are instant.

---

## Phase 5: Home Screen + Agent Controls

**Goal:** Main screen showing the agent's status with Start/Stop controls and a button to open the terminal.

### 5.1 — HomeView layout
```
┌─────────────────────────────────────────┐
│  ClawMarket                             │
│─────────────────────────────────────────│
│                                         │
│  Your Agent                             │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │  🟢 Default Agent                │  │
│  │  Status: Running                  │  │
│  │                                   │  │
│  │  [ Open Terminal ]  [ Stop ]      │  │
│  └───────────────────────────────────┘  │
│                                         │
└─────────────────────────────────────────┘
```

### 5.2 — Status indicator
- 🟢 Green dot + "Running" when container is running
- ⚫ Gray dot + "Stopped" when container exists but stopped
- 🟡 Yellow dot + "Starting..." during transitions
- Status polls every 5 seconds via `AgentManager.sync()` or uses a timer

### 5.3 — Start/Stop buttons
- When running: show "Stop" button → calls `AgentManager.stopContainer()`
- When stopped: show "Start" button → calls `AgentManager.startContainer()`
- During transitions: button disabled, shows spinner
- Stop should show a brief confirmation: "Your agent will stop. All your files and installed packages are saved."

### 5.4 — Open Terminal button
- Only enabled when agent is running
- Navigates to TerminalScreen (Phase 2)
- Terminal screen has a "← Back" button to return to Home
- Container keeps running when you leave the terminal

### 5.5 — State sync on app launch
When the app opens:
1. `AgentManager.sync()` checks container runtime state
2. If agent is already running (from background) → show Home with green dot immediately
3. If agent is stopped → show Home with gray dot and "Start" button
4. If no agent exists → show TemplateSelection
5. If no runtime → show RuntimeInstall

### 5.6 — Edge cases
- User starts agent → closes app → reopens → agent still running → show green
- User starts agent → Mac sleeps → wakes → agent may have stopped → sync and show actual state
- `container system start` may need to be re-run after reboot → detect and auto-run on app launch

**Deliverable:** Home screen correctly shows agent state. Start/Stop works. Terminal opens. State persists across app close/reopen.

---

## Phase 6: Error Handling + Polish

**Goal:** Handle every failure gracefully. App doesn't crash or hang on errors.

### 6.1 — Error states to handle

| Error | When | User sees |
|---|---|---|
| Container CLI not at expected path | Launch | RuntimeInstallView |
| `container system start` fails | Launch / after reboot | "Container service couldn't start. Try restarting your Mac." + manual instructions |
| `container build` fails | First setup | "Failed to build environment. Check your internet connection." + Retry button |
| `container start` fails | Start button / launch | "Agent couldn't start." + Show error detail + Retry |
| `container exec` fails (terminal) | Opening terminal | "Couldn't connect to agent. Is it running?" + button to go back to Home |
| Container crashes during use | While running | Detect via status poll → update to stopped → show "Agent stopped unexpectedly. Start again?" |
| Disk full | During build/run | Show error from CLI output |
| Network unavailable | During image build (pulling base alpine) | "No internet connection. Container build needs to download Alpine Linux base (~5MB)." |

### 6.2 — ErrorView
- Shows error message (from the `AgentManager.state.error` case)
- "Retry" button → re-runs `sync()` and tries the failed operation again
- "Reset" button → deletes container + image, starts over from TemplateSelection
- "Copy Error" button → copies error text to clipboard for support

### 6.3 — Logging
- `AgentManager` should log all CLI commands and their output to a log file
- Location: `~/Library/Logs/ClawMarket/agent.log`
- Useful for debugging user issues
- Keep last 1MB, rotate

### 6.4 — App lifecycle
- `onAppear` in RootView → `AgentManager.sync()` (handles reopening app)
- `NSApplication.willTerminate` → do NOT stop the container (let it keep running)
- `NSApplication.didBecomeActive` → re-sync state (user switched back to app)

### 6.5 — Visual polish (minimal)
- Consistent spacing and padding
- System fonts (SF Pro)
- System colors (works with dark mode automatically)
- App icon: placeholder is fine, just not the default Xcode icon
- Window title: "ClawMarket"
- Minimum window size: 600x400
- No menu bar tray icon for MVP

**Deliverable:** App handles all error cases without crashing. Clear error messages. Retry works. Logging works.

---

## Phase 7: Packaging + Distribution

**Goal:** A `.dmg` file that a non-developer can download, install, and use.

### 7.1 — Archive the app
- Xcode → Product → Archive
- Distribute App → Developer ID (for outside Mac App Store)
- Sign with Developer ID certificate
- If no Apple Developer account: export unsigned, users right-click → Open to bypass Gatekeeper

### 7.2 — Create .dmg
- Use `create-dmg` tool or `hdiutil`
- DMG contains: ClawMarket.app + drag-to-Applications shortcut
- Reasonable DMG size: ~10-20MB (app is thin, container image gets built on user's machine)

### 7.3 — Test on clean machine
- Fresh macOS 26 install (or a user who's never used containers)
- No Xcode, no dev tools, no container CLI
- Walk through entire flow: open app → install runtime → build → terminal → stop → start → verify persistence
- Test: close app, reopen → agent still running
- Test: restart Mac → reopen app → agent stopped but startable, files persist

### 7.4 — README for distribution
- System requirements: macOS 26, Apple Silicon
- Download link
- What the app does (1 paragraph)
- Known issues / limitations

**Deliverable:** A `.dmg` that someone can download and go from zero to working isolated Linux terminal in under 5 minutes.

---

## Summary: What each phase produces

| Phase | Deliverable | Works standalone? |
|---|---|---|
| 0 | Xcode project builds, container CLI verified | N/A (setup) |
| 1 | AgentManager class — all container ops work | Yes (via debug view / prints) |
| 2 | Terminal view — can type in container shell | Yes (hardcoded to start container + show terminal) |
| 3 | Welcome + Install screens | Yes (app guides through setup) |
| 4 | Template + Setup progress screens | Yes (app builds image and creates container) |
| 5 | Home screen with status + controls | Yes (full app flow works end-to-end) |
| 6 | Error handling + polish | Yes (app is robust) |
| 7 | .dmg package | Yes (distributable) |

**Each phase builds on the previous one. After Phase 5, the app is functionally complete. Phases 6-7 are hardening and distribution.**

**Estimated total: 2-3 weeks for a single developer.**

---

## Dockerfile (bundled in app — reference)

```dockerfile
FROM alpine:latest

RUN apk add --no-cache \
    bash \
    curl \
    wget \
    git \
    openssh-client \
    jq \
    python3 \
    py3-pip \
    nodejs \
    npm \
    nano \
    vim \
    htop \
    ripgrep \
    fd

RUN adduser -D -s /bin/bash agent
USER agent
WORKDIR /home/agent
RUN echo 'PS1="agent@claw:\w\$ "' >> /home/agent/.bashrc

CMD ["sleep", "infinity"]
```

## Key CLI Commands Reference

| Action | Command |
|---|---|
| Check CLI exists | `test -f /usr/local/bin/container` |
| Start system service | `container system start` |
| Check system running | `container system status` |
| Build image | `container build -t clawmarket/default:latest <dir>` |
| List images | `container image ls` |
| Create container | `container create --name claw-agent-1 clawmarket/default:latest` |
| Start container | `container start claw-agent-1` |
| Stop container | `container stop claw-agent-1` |
| Delete container | `container rm claw-agent-1` |
| List all containers | `container ls -a` |
| List running only | `container ls` |
| Exec shell | `container exec -i -t claw-agent-1 /bin/bash` |
| Delete image | `container image rm clawmarket/default:latest` |
