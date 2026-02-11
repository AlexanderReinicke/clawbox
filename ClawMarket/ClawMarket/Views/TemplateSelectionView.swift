import SwiftUI

struct TemplateSelectionView: View {
    let onLaunch: () -> Void
    var isLaunching: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.98, green: 0.98, blue: 0.99), Color(red: 0.93, green: 0.95, blue: 0.99)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Text("Choose a template for your agent")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                VStack(alignment: .leading, spacing: 14) {
                    Label("Default", systemImage: "shippingbox.fill")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Debian-based Linux with bash, git, python3, node, build tools, and OpenClaw preinstalled. A clean slate for command-line agents.")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    Button {
                        onLaunch()
                    } label: {
                        HStack(spacing: 10) {
                            if isLaunching {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isLaunching ? "Launching..." : "Launch")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLaunching)
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
                .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 14, y: 6)

                Text("More templates coming soon...")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(30)
        }
    }
}

#Preview {
    TemplateSelectionView(onLaunch: {})
}
