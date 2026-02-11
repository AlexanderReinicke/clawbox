import SwiftUI

struct WelcomeView: View {
    let onGetStarted: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.11, blue: 0.16),
                    Color(red: 0.03, green: 0.05, blue: 0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 26) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 74, height: 74)
                    .overlay(
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    )

                VStack(spacing: 10) {
                    Text("Run your agent locally and securely")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                    Text("Fully isolated from your system data.")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.8))
                }

                Button(action: onGetStarted) {
                    Text("Get Started")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.28, green: 0.86, blue: 0.63), in: Capsule())
                        .foregroundStyle(Color.black.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(30)
            .frame(maxWidth: 760)
        }
    }
}

#Preview {
    WelcomeView(onGetStarted: {})
}
