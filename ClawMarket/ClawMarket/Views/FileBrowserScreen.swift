import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserScreen: View {
    private struct BannerMessage {
        let text: String
        let color: Color
    }

    let manager: AgentManager
    var onBack: (() -> Void)?
    var onLocationChanged: ((String, String?) -> Void)?

    @State private var currentPath: String
    @State private var entries: [AgentFileEntry] = []
    @State private var isLoading = false
    @State private var listingErrorMessage: String?
    @State private var activeBanner: BannerMessage?
    @State private var bannerDismissTask: Task<Void, Never>?
    @State private var isDropTargeted = false
    @State private var isUploading = false
    @State private var isMutating = false

    @State private var selectedFilePath: String?
    @State private var selectedFileName: String?
    @State private var preview: AgentFilePreview?
    @State private var isPreviewLoading = false
    @State private var previewErrorMessage: String?

    @State private var editorText = ""
    @State private var savedEditorText = ""
    @State private var isSaving = false

    @State private var isCreateFileSheetPresented = false
    @State private var isCreateFolderSheetPresented = false
    @State private var createFileNameDraft = ""
    @State private var createFolderNameDraft = ""
    @State private var renameTarget: AgentFileEntry?
    @State private var renameNameDraft = ""
    @State private var deleteTarget: AgentFileEntry?

    init(
        manager: AgentManager,
        initialPath: String? = nil,
        onBack: (() -> Void)? = nil,
        onLocationChanged: ((String, String?) -> Void)? = nil
    ) {
        self.manager = manager
        self.onBack = onBack
        self.onLocationChanged = onLocationChanged
        _currentPath = State(initialValue: initialPath ?? manager.defaultBrowsePath)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading && entries.isEmpty {
                ProgressView("Loading \(currentPath)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let listingErrorMessage, entries.isEmpty {
                errorState(message: listingErrorMessage)
            } else {
                contentSplitView
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(red: 0.06, green: 0.08, blue: 0.12))
        .overlay(alignment: .bottom) {
            if let banner = activeBanner {
                HStack(spacing: 8) {
                    Image(systemName: banner.color == .red ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text(banner.text)
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(banner.color.opacity(0.95), in: Capsule())
                .padding(.bottom, 10)
            }
        }
        .task(id: currentPath) {
            await loadCurrentPath()
        }
        .onAppear {
            emitLocationChange()
        }
        .onChange(of: currentPath) { _, _ in
            emitLocationChange()
        }
        .onChange(of: selectedFilePath) { _, _ in
            emitLocationChange()
        }
        .onDisappear {
            dismissBanner()
        }
        .sheet(isPresented: $isCreateFileSheetPresented) {
            namePromptSheet(
                title: "Create File",
                message: "Create a new file in \(currentPath)",
                fieldLabel: "File name",
                fieldText: $createFileNameDraft,
                actionTitle: "Create",
                action: {
                    Task { await createFile() }
                }
            )
        }
        .sheet(isPresented: $isCreateFolderSheetPresented) {
            namePromptSheet(
                title: "Create Folder",
                message: "Create a new folder in \(currentPath)",
                fieldLabel: "Folder name",
                fieldText: $createFolderNameDraft,
                actionTitle: "Create",
                action: {
                    Task { await createFolder() }
                }
            )
        }
        .sheet(item: $renameTarget) { target in
            namePromptSheet(
                title: "Rename",
                message: "Rename \(target.name)",
                fieldLabel: "New name",
                fieldText: $renameNameDraft,
                actionTitle: "Rename",
                action: {
                    Task { await rename(target: target) }
                }
            )
            .onAppear {
                renameNameDraft = target.name
            }
        }
        .alert(
            deleteTarget?.isDirectory == true ? "Delete folder?" : "Delete file?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { presented in
                    if !presented {
                        deleteTarget = nil
                    }
                }
            ),
            presenting: deleteTarget
        ) { target in
            Button("Delete", role: .destructive) {
                Task { await delete(target: target) }
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: { target in
            Text("Delete \(target.name)? This action cannot be undone.")
        }
    }

    private var contentSplitView: some View {
        HSplitView {
            leftPane
                .frame(minWidth: 320, idealWidth: 420)

            editorPane
                .frame(minWidth: 380, idealWidth: 540)
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
                .contextMenu {
                    if entry.isDirectory {
                        Button("Open Folder") {
                            navigate(to: entry.path)
                        }
                    } else {
                        Button("Open File") {
                            handleEntryTap(entry)
                        }
                    }

                    Button("Rename…") {
                        renameNameDraft = entry.name
                        renameTarget = entry
                    }

                    Divider()

                    Button("Delete…", role: .destructive) {
                        deleteTarget = entry
                    }
                }
            }
            .listStyle(.inset)

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.blue.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
                    .padding(12)
                    .transition(.opacity)
            }

            if isUploading {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                ProgressView("Uploading to \(currentPath)")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDroppedItems)
    }

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            editorHeader
            Divider()

            if selectedFilePath == nil {
                emptyEditorState
            } else if isPreviewLoading {
                ProgressView("Loading file...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let previewErrorMessage {
                errorState(message: previewErrorMessage)
            } else {
                TextEditor(text: $editorText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(red: 0.05, green: 0.07, blue: 0.10))
                    .foregroundStyle(Color(red: 0.90, green: 0.93, blue: 0.96))
                    .disabled(isReadOnly)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }

            Divider()
            editorFooter
        }
        .background(Color(red: 0.08, green: 0.10, blue: 0.14))
    }

    private var editorHeader: some View {
        HStack(spacing: 10) {
            if let selectedFileName {
                Text(selectedFileName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Text("Editor")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }

            if isModified {
                Text("● Modified")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.82, green: 0.63, blue: 0.17))
            }

            if isReadOnly {
                Text("Read-only")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await saveCurrentFile(restartAfterSave: false) }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)

            Button {
                Task { await saveCurrentFile(restartAfterSave: true) }
            } label: {
                Label("Save & Restart", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .disabled(!canSave)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(red: 0.11, green: 0.13, blue: 0.19))
    }

    private var emptyEditorState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Select a file to edit")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.07, blue: 0.10))
    }

    private var editorFooter: some View {
        HStack(spacing: 10) {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
            }

            Text(statusSummary)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.61, green: 0.67, blue: 0.73))

            Spacer()

            if let selectedFilePath {
                Text(selectedFilePath)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(red: 0.49, green: 0.54, blue: 0.61))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.06, green: 0.08, blue: 0.12))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let onBack {
                    Button {
                        onBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                }

                Text("Agent Files")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Drag and drop files or folders from Finder into the list")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.58, green: 0.62, blue: 0.69))

                Button {
                    createFileNameDraft = ""
                    isCreateFileSheetPresented = true
                } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(isUploading || isMutating)

                Button {
                    createFolderNameDraft = ""
                    isCreateFolderSheetPresented = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(isUploading || isMutating)

                Spacer()

                Button {
                    navigateToParent()
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(currentPath == "/")

                Button {
                    Task { await loadCurrentPath() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isUploading || isMutating)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pathSegments, id: \.path) { segment in
                        Button(segment.label) {
                            navigate(to: segment.path)
                        }
                        .buttonStyle(.borderless)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(segment.path == currentPath ? .white : Color(red: 0.58, green: 0.62, blue: 0.69))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.09, green: 0.11, blue: 0.16))
    }

    private func fileRow(_ entry: AgentFileEntry, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: entry.kind))
                .foregroundStyle(iconColor(for: entry))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Text(relativeTimestamp(for: entry.modified))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !entry.isDirectory {
                Text(Self.byteCountFormatter.string(fromByteCount: entry.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await loadCurrentPath() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.07, blue: 0.10))
    }

    private var isReadOnly: Bool {
        preview?.binary == true
    }

    private var isModified: Bool {
        selectedFilePath != nil && !isReadOnly && editorText != savedEditorText
    }

    private var canSave: Bool {
        selectedFilePath != nil && !isReadOnly && isModified && !isSaving && !isMutating
    }

    private var statusSummary: String {
        if let preview, preview.binary {
            return "Binary file (read-only preview)"
        }
        if isSaving {
            return "Saving..."
        }
        if isModified {
            return "Modified"
        }
        if selectedFilePath != nil {
            return "Saved"
        }
        return "No file selected"
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
        editorText = ""
        savedEditorText = ""
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
        editorText = ""
        savedEditorText = ""
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
            if !entries.isEmpty {
                presentBanner("Refresh failed: \(error.localizedDescription)", isError: true)
            }
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
            self.editorText = preview.text
            self.savedEditorText = preview.text
            self.previewErrorMessage = nil
        } catch {
            guard selectedFilePath == path else {
                return
            }
            self.preview = nil
            self.editorText = ""
            self.savedEditorText = ""
            self.previewErrorMessage = error.localizedDescription
        }
    }

    private func saveCurrentFile(restartAfterSave: Bool) async {
        guard let selectedFilePath else {
            return
        }
        guard canSave else {
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            try await manager.writeFile(path: selectedFilePath, text: editorText)
            savedEditorText = editorText
            presentBanner("Saved \(selectedFilePath)", isError: false)

            if restartAfterSave {
                try await manager.restartContainer()
                presentBanner("Saved and restarted agent", isError: false)
            }
        } catch {
            presentBanner("Save failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func createFile() async {
        guard let name = validatedEntryName(createFileNameDraft) else {
            presentBanner("Invalid file name.", isError: true)
            return
        }
        let destinationPath = (currentPath as NSString).appendingPathComponent(name)

        isMutating = true
        defer { isMutating = false }

        do {
            try await manager.createFile(path: destinationPath)
            await loadCurrentPath()
            isCreateFileSheetPresented = false
            selectedFilePath = destinationPath
            selectedFileName = name
            await loadPreview(path: destinationPath)
            presentBanner("Created file \(name)", isError: false)
        } catch {
            presentBanner("Create file failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func createFolder() async {
        guard let name = validatedEntryName(createFolderNameDraft) else {
            presentBanner("Invalid folder name.", isError: true)
            return
        }
        let destinationPath = (currentPath as NSString).appendingPathComponent(name)

        isMutating = true
        defer { isMutating = false }

        do {
            try await manager.createDirectory(path: destinationPath)
            await loadCurrentPath()
            isCreateFolderSheetPresented = false
            presentBanner("Created folder \(name)", isError: false)
        } catch {
            presentBanner("Create folder failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func rename(target: AgentFileEntry) async {
        guard let newName = validatedEntryName(renameNameDraft) else {
            presentBanner("Invalid target name.", isError: true)
            return
        }

        let parentPath = (target.path as NSString).deletingLastPathComponent
        let destinationPath = (parentPath as NSString).appendingPathComponent(newName)
        if destinationPath == target.path {
            renameTarget = nil
            return
        }

        isMutating = true
        defer { isMutating = false }

        do {
            try await manager.renameItem(from: target.path, to: destinationPath)
            renameTarget = nil

            if selectedFilePath == target.path {
                selectedFilePath = destinationPath
                selectedFileName = newName
                await loadPreview(path: destinationPath)
            }

            await loadCurrentPath()
            presentBanner("Renamed \(target.name) to \(newName)", isError: false)
        } catch {
            presentBanner("Rename failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func delete(target: AgentFileEntry) async {
        isMutating = true
        defer { isMutating = false }

        do {
            try await manager.deleteItem(path: target.path)
            deleteTarget = nil

            if let selectedFilePath {
                if selectedFilePath == target.path || selectedFilePath.hasPrefix(target.path + "/") {
                    clearPreviewSelection()
                }
            }

            await loadCurrentPath()
            presentBanner("Deleted \(target.name)", isError: false)
        } catch {
            presentBanner("Delete failed: \(error.localizedDescription)", isError: true)
        }
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
        dismissBanner()

        let urls = await resolveDroppedURLs(from: providers)
        guard !urls.isEmpty else {
            isUploading = false
            presentBanner("Drop did not include any readable local URLs.", isError: true)
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

        if !failures.isEmpty {
            let first = failures[0]
            if uploadedFiles > 0 || uploadedDirectories > 0 {
                presentBanner(
                    "Uploaded with issues. \(uploadSummary(files: uploadedFiles, directories: uploadedDirectories)). First error: \(first)",
                    isError: true
                )
            } else {
                presentBanner(
                    failures.count == 1
                        ? "Upload failed: \(first)"
                        : "Upload failed for \(failures.count) items. First error: \(first)",
                    isError: true
                )
            }
        } else if uploadedFiles > 0 || uploadedDirectories > 0 {
            presentBanner(uploadSummary(files: uploadedFiles, directories: uploadedDirectories), isError: false)
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

    private func iconColor(for entry: AgentFileEntry) -> Color {
        if entry.isDirectory {
            return .blue
        }
        let lower = entry.name.lowercased()
        if lower.hasSuffix(".sh") || lower.hasSuffix(".py") || lower.hasSuffix(".js") || lower.hasSuffix(".ts") {
            return Color(red: 0.35, green: 0.78, blue: 0.41)
        }
        if lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") || lower.hasSuffix(".json") || lower.hasSuffix(".toml") || lower.hasSuffix(".env") {
            return Color(red: 0.92, green: 0.72, blue: 0.24)
        }
        return .secondary
    }

    private func validatedEntryName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard trimmed != "." && trimmed != ".." else {
            return nil
        }
        guard !trimmed.contains("/") else {
            return nil
        }
        return trimmed
    }

    private func relativeTimestamp(for unix: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: unix)
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        let delta = Date().timeIntervalSince(date)
        if delta < 24 * 60 * 60 {
            return relative.localizedString(for: date, relativeTo: Date())
        }
        return Self.modifiedFormatter.string(from: date)
    }

    private func namePromptSheet(
        title: String,
        message: String,
        fieldLabel: String,
        fieldText: Binding<String>,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            TextField(fieldLabel, text: fieldText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    action()
                }

            HStack {
                Spacer()
                Button("Cancel") {
                    isCreateFileSheetPresented = false
                    isCreateFolderSheetPresented = false
                    renameTarget = nil
                }
                .keyboardShortcut(.cancelAction)

                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isMutating)
            }
        }
        .padding(18)
        .frame(minWidth: 420)
    }

    private func presentBanner(_ text: String, isError: Bool) {
        bannerDismissTask?.cancel()
        activeBanner = BannerMessage(
            text: text,
            color: isError ? .red : .green
        )

        bannerDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(isError ? 8 : 5))
            } catch {
                return
            }
            activeBanner = nil
            bannerDismissTask = nil
        }
    }

    private func dismissBanner() {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        activeBanner = nil
    }

    private func emitLocationChange() {
        onLocationChanged?(currentPath, selectedFilePath)
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let modifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

#Preview {
    FileBrowserScreen(manager: AgentManager(autoSync: false))
}
