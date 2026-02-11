import SwiftUI

struct AgentSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let agentSlot: Int
    let containerName: String
    let runtimeState: AgentSlotRuntimeState
    let hostMemoryTotalGB: Double?
    let minimumMemoryGB: Int
    let maximumMemoryGB: Int
    @Binding var memoryGB: Int
    let accessFolderPath: String?
    let onSelectAccessFolder: () -> Void
    let onClearAccessFolder: () -> Void
    let onRecreateAgent: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.95, green: 0.97, blue: 1.0), Color(red: 0.91, green: 0.95, blue: 0.99)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agent \(agentSlot) Settings")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(containerName)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusChip
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.9))

                ScrollView {
                    VStack(spacing: 12) {
                        resourcesCard
                        folderCard
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            clampMemory()
        }
        .onChange(of: maximumMemoryGB) { _, _ in
            clampMemory()
        }
    }

    private var statusChip: some View {
        Text(runtimeLabel)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(runtimeColor.opacity(0.14), in: Capsule())
            .foregroundStyle(runtimeColor)
    }

    private var resourcesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Resources")
                .font(.system(size: 14, weight: .bold, design: .rounded))

            statusRow(
                icon: "memorychip.fill",
                title: "Host Memory",
                value: hostMemoryTotalGB.map { String(format: "%.1f GB", $0) } ?? "Detecting..."
            )

            statusRow(
                icon: "internaldrive.fill",
                title: "Configured Agent RAM",
                value: "\(memoryGB) GB"
            )

            Divider()

            Text("Agent RAM")
                .font(.system(size: 13, weight: .semibold, design: .rounded))

            HStack(spacing: 10) {
                Button {
                    memoryGB = max(minimumMemoryGB, memoryGB - 1)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .disabled(memoryGB <= minimumMemoryGB)

                Text("\(memoryGB) GB")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .frame(minWidth: 80, alignment: .center)

                Button {
                    memoryGB = min(maximumMemoryGB, memoryGB + 1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .disabled(memoryGB >= maximumMemoryGB)

                Spacer()
                Text("Range \(minimumMemoryGB)-\(maximumMemoryGB) GB")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Text("RAM changes apply when the agent instance is recreated.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Button("Recreate Agent Now") {
                onRecreateAgent()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Access Folder")
                .font(.system(size: 14, weight: .bold, design: .rounded))

            if let accessFolderPath {
                Text(accessFolderPath)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("No folder selected for this agent.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Select Access Folder") {
                    onSelectAccessFolder()
                }
                .buttonStyle(.bordered)

                Button("Clear") {
                    onClearAccessFolder()
                }
                .buttonStyle(.bordered)
                .disabled(accessFolderPath == nil)
            }

            Text("Folder mounts are applied on creation. Recreate the agent after changing folder selection.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func statusRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(Color(red: 0.15, green: 0.38, blue: 0.72))
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
        }
    }

    private var runtimeLabel: String {
        switch runtimeState {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .missing: return "Not Created"
        }
    }

    private var runtimeColor: Color {
        switch runtimeState {
        case .running:
            return Color(red: 0.12, green: 0.54, blue: 0.27)
        case .stopped:
            return Color(red: 0.39, green: 0.44, blue: 0.52)
        case .missing:
            return Color(red: 0.22, green: 0.36, blue: 0.66)
        }
    }

    private func clampMemory() {
        memoryGB = min(max(memoryGB, minimumMemoryGB), maximumMemoryGB)
    }
}

#Preview {
    AgentSettingsSheet(
        agentSlot: 1,
        containerName: "claw-agent-1",
        runtimeState: .running,
        hostMemoryTotalGB: 16,
        minimumMemoryGB: 2,
        maximumMemoryGB: 16,
        memoryGB: .constant(4),
        accessFolderPath: "/Users/example/Documents/OpenClaw",
        onSelectAccessFolder: {},
        onClearAccessFolder: {},
        onRecreateAgent: {}
    )
}
