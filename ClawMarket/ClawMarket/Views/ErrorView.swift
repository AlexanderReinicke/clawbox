import SwiftUI
import AppKit

struct ErrorView: View {
    var message: String = "Unknown error"
    var onRetry: (() -> Void)? = nil
    var onReset: (() -> Void)? = nil
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: 680, alignment: .leading)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
            if let onReset {
                Button("Reset Environment", role: .destructive, action: onReset)
                    .buttonStyle(.bordered)
            }
            Button(copied ? "Copied" : "Copy Error") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(message, forType: .string)
                copied = true
            }
            .buttonStyle(.bordered)
            .onAppear { copied = false }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ErrorView(message: "Example failure")
}
