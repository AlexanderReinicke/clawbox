import SwiftUI

enum SetupProgressState: Equatable {
    case working(String)
    case failed(String)
}

struct SetupProgressView: View {
    let state: SetupProgressState
    var onRetry: (() -> Void)? = nil

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.12), Color(red: 0.02, green: 0.03, blue: 0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                switch state {
                case let .working(message):
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text(message)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("This can take a minute on first setup.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))

                case let .failed(message):
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.red)
                    Text("Setup failed")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: 760, alignment: .leading)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if let onRetry {
                        Button("Retry", action: onRetry)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(28)
        }
    }
}

#Preview {
    SetupProgressView(state: .working("Building environment..."))
}
