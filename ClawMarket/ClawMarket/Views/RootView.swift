import SwiftUI

struct RootView: View {
    @State private var manager = AgentManager()
    @State private var showingTerminal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ClawMarket Engine Check")
                .font(.title2.weight(.semibold))

            Label(stateTitle, systemImage: stateIcon)
                .foregroundStyle(stateColor)

            Text("Container: \(manager.containerName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Button("Sync") {
                    Task { await manager.sync() }
                }
                Button("Build Image") {
                    Task {
                        do {
                            try await manager.buildImage()
                            await manager.sync()
                        } catch {
                            manager.lastErrorMessage = error.localizedDescription
                        }
                    }
                }
                Button("Create + Start") {
                    Task {
                        do {
                            try await manager.createContainer()
                            try await manager.startContainer()
                            await manager.sync()
                        } catch {
                            manager.lastErrorMessage = error.localizedDescription
                        }
                    }
                }
                Button("Stop") {
                    Task {
                        do {
                            try await manager.stopContainer()
                            await manager.sync()
                        } catch {
                            manager.lastErrorMessage = error.localizedDescription
                        }
                    }
                }
                Button("Delete") {
                    Task {
                        do {
                            try await manager.deleteContainer()
                            await manager.sync()
                        } catch {
                            manager.lastErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)

            Button("Open Terminal") {
                showingTerminal = true
            }
            .buttonStyle(.bordered)
            .disabled(manager.state != .running)

            if let error = manager.lastErrorMessage {
                GroupBox("Last Error") {
                    ScrollView {
                        Text(error)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }

            GroupBox("Last Command Output") {
                ScrollView {
                    Text(manager.lastCommandOutput.isEmpty ? "No command output yet." : manager.lastCommandOutput)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }

            Spacer()
        }
        .padding(24)
        .task {
            await manager.sync()
        }
        .sheet(isPresented: $showingTerminal) {
            TerminalScreen(containerName: manager.containerName)
                .frame(minWidth: 900, minHeight: 600)
        }
    }

    private var stateTitle: String {
        switch manager.state {
        case .checking: return "Checking runtime"
        case .noRuntime: return "Container runtime missing"
        case .needsImage: return "Image not built"
        case .needsContainer: return "Container not created"
        case .stopped: return "Container stopped"
        case .starting: return "Container starting"
        case .running: return "Container running"
        case .error: return "Error"
        }
    }

    private var stateIcon: String {
        switch manager.state {
        case .running: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .starting, .checking: return "clock.fill"
        default: return "circle"
        }
    }

    private var stateColor: Color {
        switch manager.state {
        case .running: return .green
        case .error: return .red
        case .starting, .checking: return .orange
        default: return .secondary
        }
    }
}

#Preview {
    RootView()
}
