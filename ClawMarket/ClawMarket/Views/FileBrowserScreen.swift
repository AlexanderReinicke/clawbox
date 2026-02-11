import SwiftUI

struct FileBrowserScreen: View {
    let manager: AgentManager
    var onBack: (() -> Void)?

    @State private var currentPath: String
    @State private var entries: [AgentFileEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(manager: AgentManager, onBack: (() -> Void)? = nil) {
        self.manager = manager
        self.onBack = onBack
        _currentPath = State(initialValue: manager.defaultBrowsePath)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading && entries.isEmpty {
                ProgressView("Loading \(currentPath)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await loadCurrentPath() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    if entry.isDirectory {
                        Button {
                            currentPath = entry.path
                        } label: {
                            fileRow(entry)
                        }
                        .buttonStyle(.plain)
                    } else {
                        fileRow(entry)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(NSColor.windowBackgroundColor))
        .task(id: currentPath) {
            await loadCurrentPath()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let onBack {
                    Button {
                        onBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }

                Text("Agent Files")
                    .font(.headline)

                Spacer()

                Button {
                    navigateToParent()
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .disabled(currentPath == "/")

                Button {
                    Task { await loadCurrentPath() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pathSegments, id: \.path) { segment in
                        Button(segment.label) {
                            currentPath = segment.path
                        }
                        .buttonStyle(.borderless)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(segment.path == currentPath ? .primary : .secondary)
                    }
                }
            }

            Text(currentPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func fileRow(_ entry: AgentFileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: entry.kind))
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Text(entry.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !entry.isDirectory {
                Text(Self.byteCountFormatter.string(fromByteCount: entry.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(Self.modifiedFormatter.string(from: Date(timeIntervalSince1970: entry.modified)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func navigateToParent() {
        guard currentPath != "/" else {
            return
        }
        let nsPath = currentPath as NSString
        let parent = nsPath.deletingLastPathComponent
        currentPath = parent.isEmpty ? "/" : parent
    }

    private func loadCurrentPath() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let listing = try await manager.listDirectory(path: currentPath)
            currentPath = listing.path
            entries = listing.entries
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var pathSegments: [(label: String, path: String)] {
        if currentPath == "/" {
            return [("/", "/")]
        }

        let parts = currentPath.split(separator: "/").map(String.init)
        var output: [(label: String, path: String)] = [("/", "/")]
        var running = ""
        for part in parts {
            running += "/" + part
            output.append((part, running))
        }
        return output
    }

    private func iconName(for type: AgentFileType) -> String {
        switch type {
        case .directory:
            return "folder.fill"
        case .file:
            return "doc.text"
        case .symlink:
            return "arrow.triangle.2.circlepath"
        case .other:
            return "questionmark.folder"
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let modifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

#Preview {
    FileBrowserScreen(manager: AgentManager(autoSync: false))
}
