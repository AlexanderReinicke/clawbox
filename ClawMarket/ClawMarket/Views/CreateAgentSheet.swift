import SwiftUI

struct CreateAgentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let agentSlot: Int
    let minimumMemoryGB: Int
    let maximumMemoryGB: Int
    @Binding var memoryGB: Int
    let isCreating: Bool
    let onCreate: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.95, green: 0.98, blue: 1.0), Color(red: 0.91, green: 0.95, blue: 0.99)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Create Agent \(agentSlot)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("Default Template")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCreating)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Template")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Label("Default (Debian + OpenClaw)", systemImage: "shippingbox.fill")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

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
                        .disabled(memoryGB <= minimumMemoryGB || isCreating)

                        Text("\(memoryGB) GB")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .frame(minWidth: 88, alignment: .center)

                        Button {
                            memoryGB = min(maximumMemoryGB, memoryGB + 1)
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.bordered)
                        .disabled(memoryGB >= maximumMemoryGB || isCreating)

                        Spacer()

                        Text("Range \(minimumMemoryGB)-\(maximumMemoryGB) GB")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )

                Button {
                    onCreate()
                } label: {
                    HStack(spacing: 8) {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isCreating ? "Creating..." : "Create Agent")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating)
            }
            .padding(18)
        }
        .frame(minWidth: 460, minHeight: 300)
        .onAppear {
            memoryGB = min(max(memoryGB, minimumMemoryGB), maximumMemoryGB)
        }
    }
}

#Preview {
    CreateAgentSheet(
        agentSlot: 2,
        minimumMemoryGB: 2,
        maximumMemoryGB: 16,
        memoryGB: .constant(4),
        isCreating: false,
        onCreate: {}
    )
}
