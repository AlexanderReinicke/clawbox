import SwiftUI

struct ErrorView: View {
    var message: String = "Unknown error"
    var onRetry: (() -> Void)? = nil

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
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ErrorView(message: "Example failure")
}
