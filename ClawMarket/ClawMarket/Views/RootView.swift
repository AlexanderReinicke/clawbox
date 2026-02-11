import SwiftUI
import AppKit

struct RootView: View {
    @AppStorage("clawmarket.hasSeenWelcome") private var hasSeenWelcome = false
    @State private var manager = AgentManager()
    @State private var runtimeInstallStatus: RuntimeInstallStatus = .idle
    @State private var setupProgressState: SetupProgressState?
    @State private var isLaunchingTemplate = false
    @State private var terminalWindowController: NSWindowController?
    @State private var filesWindowController: NSWindowController?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if !hasSeenWelcome {
                WelcomeView {
                    hasSeenWelcome = true
                    Task { await manager.sync() }
                }
            } else if manager.state == .noRuntime {
                RuntimeInstallView(
                    status: runtimeInstallStatus,
                    onInstallNow: installRuntime,
                    onInstallManually: openManualInstallPage,
                    onCheckAgain: checkRuntimeAgain
                )
            } else if let setupProgressState {
                SetupProgressView(state: setupProgressState, onRetry: runTemplateSetup)
            } else {
                switch manager.state {
                case .checking:
                    checkingView
                case .noRuntime:
                    RuntimeInstallView(
                        status: runtimeInstallStatus,
                        onInstallNow: installRuntime,
                        onInstallManually: openManualInstallPage,
                        onCheckAgain: checkRuntimeAgain
                    )
                case .needsImage, .needsContainer:
                    TemplateSelectionView(
                        onLaunch: runTemplateSetup,
                        isLaunching: isLaunchingTemplate
                    )
                case .stopped, .starting, .running:
                    HomeView(
                        state: manager.state,
                        onStart: startAgent,
                        onStop: stopAgent,
                        onOpenTerminal: openTerminalWindow,
                        onOpenFiles: openFilesWindow,
                        onOpenDashboard: openDashboard,
                        onRefresh: { Task { await manager.sync() } }
                    )
                case let .error(message):
                    ErrorView(
                        message: message,
                        onRetry: {
                            runtimeInstallStatus = .idle
                            Task { await manager.sync() }
                        },
                        onReset: resetEnvironment
                    )
                }
            }
        }
        .task {
            await manager.sync()
        }
        .task(id: pollingKey) {
            guard shouldPollAgentState else { return }
            while !Task.isCancelled && shouldPollAgentState {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled {
                    await manager.sync()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await manager.sync() }
        }
        .animation(.easeInOut(duration: 0.2), value: hasSeenWelcome)
        .animation(.easeInOut(duration: 0.2), value: manager.state)
    }

    private var checkingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Checking container runtime...")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.95, green: 0.97, blue: 0.99))
    }

    private func installRuntime() {
        Task {
            runtimeInstallStatus = .working("Preparing runtime installation...")
            do {
                try await manager.installRuntime { status in
                    runtimeInstallStatus = .working(status)
                }
                runtimeInstallStatus = .working("Verifying runtime...")
                await manager.sync()
                runtimeInstallStatus = .idle
            } catch {
                runtimeInstallStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func checkRuntimeAgain() {
        Task {
            runtimeInstallStatus = .working("Checking runtime availability...")
            await manager.sync()
            if manager.state == .noRuntime {
                runtimeInstallStatus = .failed("Runtime still not detected at /usr/local/bin/container.")
            } else {
                runtimeInstallStatus = .idle
            }
        }
    }

    private func openManualInstallPage() {
        openURL(URL(string: "https://github.com/apple/container/releases")!)
    }

    private func runTemplateSetup() {
        guard !isLaunchingTemplate else {
            return
        }

        isLaunchingTemplate = true
        setupProgressState = .working("Building environment...")

        Task {
            do {
                if manager.state == .needsImage {
                    try await manager.buildImage()
                }

                setupProgressState = .working("Creating your agent...")
                try await manager.createContainer()

                setupProgressState = .working("Starting up...")
                try await manager.startContainer()

                await manager.sync()
                setupProgressState = nil
                isLaunchingTemplate = false
            } catch {
                setupProgressState = .failed(error.localizedDescription)
                isLaunchingTemplate = false
            }
        }
    }

    private func startAgent() {
        Task {
            do {
                try await manager.startContainer()
                await manager.sync()
            } catch {
                manager.state = .error(error.localizedDescription)
            }
        }
    }

    private func stopAgent() {
        Task {
            do {
                try await manager.stopContainer()
                await manager.sync()
            } catch {
                manager.state = .error(error.localizedDescription)
            }
        }
    }

    private var shouldPollAgentState: Bool {
        if case .running = manager.state { return true }
        if case .starting = manager.state { return true }
        if case .stopped = manager.state { return true }
        return false
    }

    private var pollingKey: String {
        switch manager.state {
        case .running:
            return "poll-running"
        case .starting:
            return "poll-starting"
        case .stopped:
            return "poll-stopped"
        default:
            return "poll-off"
        }
    }

    private func resetEnvironment() {
        Task {
            do {
                try await manager.factoryReset()
                runtimeInstallStatus = .idle
                setupProgressState = nil
                isLaunchingTemplate = false
                await manager.sync()
            } catch {
                manager.state = .error("Reset failed: \(error.localizedDescription)")
            }
        }
    }

    private func openTerminalWindow() {
        if let existing = terminalWindowController?.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = TerminalScreen(containerName: manager.containerName)
            .frame(minWidth: 720, minHeight: 460)

        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Agent Terminal"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1060, height: 720))
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        terminalWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openFilesWindow() {
        if let existing = filesWindowController?.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = FileBrowserScreen(manager: manager)
            .frame(minWidth: 760, minHeight: 520)

        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Agent Files"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1160, height: 760))
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        filesWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openDashboard() {
        Task {
            do {
                let url = try await manager.dashboardURL()
                await MainActor.run {
                    openURL(url)
                }
            } catch {
                await MainActor.run {
                    manager.state = .error(error.localizedDescription)
                }
            }
        }
    }
}

#Preview {
    RootView()
}
