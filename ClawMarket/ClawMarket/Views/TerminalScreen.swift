import SwiftUI
import SwiftTerm
import AppKit

struct TerminalScreen: View {
    let containerName: String
    var onBack: (() -> Void)?

    @State private var reconnectToken = UUID()
    @State private var disconnectedReason: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                TerminalProcessView(
                    containerName: containerName,
                    reconnectToken: reconnectToken
                ) { exitCode in
                    disconnectedReason = "Terminal session ended (exit code: \(exitCode.map(String.init) ?? "n/a"))."
                }

                if let disconnectedReason {
                    disconnectedOverlay(message: disconnectedReason)
                }
            }
        }
        .background(Color.black)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Terminal")
                    .font(.headline.weight(.semibold))
                Text(containerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                disconnectedReason = nil
                reconnectToken = UUID()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func disconnectedOverlay(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Terminal Disconnected")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Reconnect") {
                disconnectedReason = nil
                reconnectToken = UUID()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(radius: 16)
    }
}

private struct TerminalProcessView: NSViewRepresentable {
    let containerName: String
    let reconnectToken: UUID
    let onProcessTerminated: (Int32?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProcessTerminated: onProcessTerminated)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminalView = LocalProcessTerminalView(frame: .zero)
        terminalView.processDelegate = context.coordinator
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeBackgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        terminalView.caretColor = .systemGreen
        terminalView.optionAsMetaKey = true
        context.coordinator.attach(view: terminalView)
        context.coordinator.connect(containerName: containerName, reconnectToken: reconnectToken)
        return terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.attach(view: nsView)
        context.coordinator.connect(containerName: containerName, reconnectToken: reconnectToken)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        private weak var view: LocalProcessTerminalView?
        private var currentReconnectToken: UUID?
        private var currentContainerName: String = ""
        private let onProcessTerminated: (Int32?) -> Void

        init(onProcessTerminated: @escaping (Int32?) -> Void) {
            self.onProcessTerminated = onProcessTerminated
        }

        func attach(view: LocalProcessTerminalView) {
            self.view = view
            view.processDelegate = self
        }

        func connect(containerName: String, reconnectToken: UUID) {
            guard
                currentReconnectToken != reconnectToken ||
                currentContainerName != containerName ||
                view?.process.running == false
            else {
                return
            }

            currentReconnectToken = reconnectToken
            currentContainerName = containerName

            if view?.process.running == true {
                view?.terminate()
            }

            view?.startProcess(
                executable: "/usr/local/bin/container",
                args: ["exec", "-i", "-t", containerName, "/bin/bash"]
            )
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onProcessTerminated(exitCode)
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}

#Preview {
    TerminalScreen(containerName: "claw-agent-1")
}
