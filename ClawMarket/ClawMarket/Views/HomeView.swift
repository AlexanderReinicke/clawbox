import SwiftUI

struct HomeView: View {
    let state: AgentState
    let accessFolderDisplayPath: String?
    let onStart: () -> Void
    let onStop: () -> Void
    let onOpenTerminal: () -> Void
    let onOpenFiles: () -> Void
    let onOpenDashboard: () -> Void
    let onSelectAccessFolder: () -> Void
    let onRecreateAgent: () -> Void
    let onRefresh: () -> Void

    @State private var showStopConfirmation = false
    @State private var showRecreateConfirmation = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.97, green: 0.98, blue: 0.99), Color(red: 0.94, green: 0.96, blue: 0.99)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("ClawMarket")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                    Spacer()
                    Button {
                        onRefresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                Text("Your Agent")
                    .font(.system(size: 20, weight: .bold, design: .rounded))

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 11, height: 11)
                        Text("Default Agent")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                    }

                    Text("Status: \(statusText)")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button("Open Terminal", action: onOpenTerminal)
                            .buttonStyle(.borderedProminent)
                            .disabled(state != .running)

                        Button("Open Files", action: onOpenFiles)
                            .buttonStyle(.bordered)
                            .disabled(state != .running)

                        Button("Open Dashboard", action: onOpenDashboard)
                            .buttonStyle(.bordered)
                            .disabled(state != .running)

                        if state == .running {
                            Button("Stop") {
                                showStopConfirmation = true
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("Start", action: onStart)
                                .buttonStyle(.bordered)
                                .disabled(state == .starting)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Select Access Folder", action: onSelectAccessFolder)
                            .buttonStyle(.bordered)
                            .disabled(state == .starting)

                        Button("Recreate Agent") {
                            showRecreateConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(state == .starting)
                    }

                    if let accessFolderDisplayPath {
                        Text("Access folder: \(accessFolderDisplayPath)")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else {
                        Text("Access folder: not selected")
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Text("Folder access uses a bind mount. This can only be added when the agent container is created, so changing it requires Recreate Agent.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(maxWidth: 760, alignment: .leading)
                .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.07), radius: 12, y: 5)

                Spacer()
            }
            .padding(28)
        }
        .alert("Stop agent?", isPresented: $showStopConfirmation) {
            Button("Stop", role: .destructive) { onStop() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your agent will stop. Files and installed packages remain saved.")
        }
        .alert("Recreate agent?", isPresented: $showRecreateConfirmation) {
            Button("Recreate", role: .destructive) { onRecreateAgent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete the current agent container and create a fresh one. Folder access mount is applied at creation time only.")
        }
    }

    private var statusText: String {
        switch state {
        case .running:
            return "Running"
        case .starting:
            return "Starting..."
        case .stopped:
            return "Stopped"
        default:
            return "Unknown"
        }
    }

    private var statusColor: Color {
        switch state {
        case .running:
            return .green
        case .starting:
            return .yellow
        case .stopped:
            return .gray
        default:
            return .gray
        }
    }
}

#Preview {
    HomeView(
        state: .running,
        accessFolderDisplayPath: "/Users/example/Documents/OpenClaw",
        onStart: {},
        onStop: {},
        onOpenTerminal: {},
        onOpenFiles: {},
        onOpenDashboard: {},
        onSelectAccessFolder: {},
        onRecreateAgent: {},
        onRefresh: {}
    )
}
