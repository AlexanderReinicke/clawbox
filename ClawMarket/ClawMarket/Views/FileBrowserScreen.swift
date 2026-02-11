import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserScreen: View {
    let manager: AgentManager
    var onBack: (() -> Void)?

    @State private var currentPath: String
    @State private var entries: [AgentFileEntry] = []
    @State private var isLoading = false
    @State private var listingErrorMessage: String?
    @State private var uploadStatusMessage: String?
    @State private var uploadErrorMessage: String?
    @State private var isDropTargeted = false
    @State private var isUploading = false

    @State private var selectedFilePath: String?
    @State private var selectedFileName: String?
    @State private var preview: AgentFilePreview?
    @State private var isPreviewLoading = false
    @State private var previewErrorMessage: String?

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
            } else if let listingErrorMessage, entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.orange)
                    Text(listingErrorMessage)
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
                contentSplitView
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if let banner = activeBanner {
                Text(banner.text)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(banner.color, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
        .task(id: currentPath) {
            await loadCurrentPath()
        }
    }

    private var contentSplitView: some View {
        HSplitView {
            leftPane
                .frame(minWidth: 280, idealWidth: 430)

            previewPane
                .frame(minWidth: 260, idealWidth: 330)
        }
    }

    private var leftPane: some View {
        ZStack {
            List(entries) { entry in
                Button {
                    handleEntryTap(entry)
                } label: {
                    fileRow(entry, isSelected: selectedFilePath == entry.path)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.blue.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
                    .padding(12)
                    .transition(.opacity)
            }

            if isUploading {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                ProgressView("Uploading to \(currentPath)")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDroppedItems)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selectedFilePath, let selectedFileName {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedFileName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(selectedFilePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        if let preview, preview.truncated {
                            Label("Preview truncated", systemImage: "scissors")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let preview, preview.binary {
                            Label("Binary data detected", systemImage: "waveform.path")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)

                Divider()

                if isPreviewLoading {
                    ProgressView("Loading file preview...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let previewErrorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.badge.exclamationmark")
                            .font(.system(size: 24))
                            .foregroundStyle(.orange)
                        Text(previewErrorMessage)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(preview?.text ?? "")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("Select a file to preview")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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

                Text("Drop files or folders from Finder to upload into this folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                            navigate(to: segment.path)
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

    private func fileRow(_ entry: AgentFileEntry, isSelected: Bool) -> some View {
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
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func handleEntryTap(_ entry: AgentFileEntry) {
        if entry.isDirectory {
            navigate(to: entry.path)
            return
        }

        selectedFilePath = entry.path
        selectedFileName = entry.name
        preview = nil
        previewErrorMessage = nil
        Task {
            await loadPreview(path: entry.path)
        }
    }

    private func navigateToParent() {
        guard currentPath != "/" else {
            return
        }
        let parent = (currentPath as NSString).deletingLastPathComponent
        navigate(to: parent.isEmpty ? "/" : parent)
    }

    private func navigate(to path: String) {
        currentPath = path
        clearPreviewSelection()
    }

    private func clearPreviewSelection() {
        selectedFilePath = nil
        selectedFileName = nil
        preview = nil
        previewErrorMessage = nil
    }

    private func loadCurrentPath() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let listing = try await manager.listDirectory(path: currentPath)
            currentPath = listing.path
            entries = listing.entries
            listingErrorMessage = nil

            if let selectedFilePath,
               !entries.contains(where: { $0.path == selectedFilePath }) {
                clearPreviewSelection()
            }
        } catch {
            listingErrorMessage = error.localizedDescription
        }
    }

    private func loadPreview(path: String) async {
        isPreviewLoading = true
        defer { isPreviewLoading = false }

        do {
            let preview = try await manager.readFilePreview(path: path)
            guard selectedFilePath == path else {
                return
            }
            self.preview = preview
            self.previewErrorMessage = nil
        } catch {
            guard selectedFilePath == path else {
                return
            }
            self.preview = nil
            self.previewErrorMessage = error.localizedDescription
        }
    }

    private var activeBanner: (text: String, color: Color)? {
        if let uploadErrorMessage {
            return (uploadErrorMessage, .red.opacity(0.9))
        }
        if let listingErrorMessage, !entries.isEmpty {
            return (listingErrorMessage, .red.opacity(0.9))
        }
        if let uploadStatusMessage {
            return (uploadStatusMessage, .green.opacity(0.9))
        }
        return nil
    }

    private func handleDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !accepted.isEmpty else {
            return false
        }
        Task {
            await importDroppedItems(from: accepted)
        }
        return true
    }

    private func importDroppedItems(from providers: [NSItemProvider]) async {
        isUploading = true
        uploadErrorMessage = nil
        uploadStatusMessage = nil

        let urls = await resolveDroppedURLs(from: providers)
        guard !urls.isEmpty else {
            isUploading = false
            uploadErrorMessage = "Drop did not include any readable local URLs."
            return
        }

        var uploadedFiles = 0
        var uploadedDirectories = 0
        var failures: [String] = []

        for url in urls {
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            do {
                let result = try await manager.uploadItem(from: url, toDirectory: currentPath)
                uploadedFiles += result.uploadedFiles
                uploadedDirectories += result.uploadedDirectories
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        await loadCurrentPath()
        isUploading = false

        if uploadedFiles > 0 || uploadedDirectories > 0 {
            uploadStatusMessage = uploadSummary(files: uploadedFiles, directories: uploadedDirectories)
        }
        if !failures.isEmpty {
            let first = failures[0]
            uploadErrorMessage = failures.count == 1
                ? "Upload failed: \(first)"
                : "Upload failed for \(failures.count) items. First error: \(first)"
        }
    }

    private func uploadSummary(files: Int, directories: Int) -> String {
        if files > 0 && directories > 0 {
            return "Uploaded \(files) file(s) and \(directories) folder(s) to \(currentPath)"
        }
        if directories > 0 {
            return "Uploaded \(directories) folder(s) to \(currentPath)"
        }
        return "Uploaded \(files) file(s) to \(currentPath)"
    }

    private func resolveDroppedURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadFileURL(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }
                if let nsURL = item as? NSURL {
                    continuation.resume(returning: nsURL as URL)
                    return
                }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                    return
                }
                if let value = item as? String, let url = URL(string: value), url.isFileURL {
                    continuation.resume(returning: url)
                    return
                }
                continuation.resume(returning: nil)
            }
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
