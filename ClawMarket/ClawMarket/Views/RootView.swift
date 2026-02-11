import SwiftUI

struct RootView: View {
    @AppStorage("clawmarket.hasSeenWelcome") private var hasSeenWelcome = false
    @State private var manager = AgentManager()
    @State private var runtimeInstallStatus: RuntimeInstallStatus = .idle
    @State private var setupProgressState: SetupProgressState?
    @State private var isLaunchingTemplate = false
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
                    HomeView()
                case let .error(message):
                    ErrorView(message: message) {
                        runtimeInstallStatus = .idle
                        Task { await manager.sync() }
                    }
                }
            }
        }
        .task {
            await manager.sync()
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
}

#Preview {
    RootView()
}
