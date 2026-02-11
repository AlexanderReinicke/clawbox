import SwiftUI

enum RuntimeInstallStatus: Equatable {
    case idle
    case working(String)
    case failed(String)
}

struct RuntimeInstallView: View {
    let status: RuntimeInstallStatus
    let onInstallNow: () -> Void
    let onInstallManually: () -> Void
    let onCheckAgain: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.96, green: 0.97, blue: 0.99), Color(red: 0.90, green: 0.94, blue: 0.98)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color(red: 0.11, green: 0.36, blue: 0.63))

                VStack(spacing: 10) {
                    Text("Install Apple Container Runtime")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("ClawNode needs Apple's container runtime to run agents on your Mac.")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 680)
                }

                statusView
                    .frame(maxWidth: 680)

                HStack(spacing: 12) {
                    Button("Install Now", action: onInstallNow)
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                    Button("I've Installed It, Check Again", action: onCheckAgain)
                        .buttonStyle(.bordered)
                        .disabled(isWorking)
                    Button("Install Manually", action: onInstallManually)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(red: 0.12, green: 0.33, blue: 0.60))
                        .underline()
                }
            }
            .padding(28)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            Text("Install will download the signed package, request admin approval, and start the runtime service.")
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        case let .working(message):
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Installation failed", systemImage: "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
            )
        }
    }

    private var isWorking: Bool {
        if case .working = status {
            return true
        }
        return false
    }
}

#Preview {
    RuntimeInstallView(
        status: .idle,
        onInstallNow: {},
        onInstallManually: {},
        onCheckAgain: {}
    )
}
