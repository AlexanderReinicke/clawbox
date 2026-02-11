import Foundation
import Observation

enum AgentState: Equatable {
    case checking
    case noRuntime
    case needsImage
    case needsContainer
    case stopped
    case starting
    case running
    case error(String)
}

enum AgentManagerError: LocalizedError {
    case runtimeMissing
    case downloadFailed(String)
    case invalidHTTPStatus(Int)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case commandTimeout(command: String, seconds: TimeInterval)
    case missingDockerfile
    case imageBuildFailed(String)
    case invalidDirectoryListing(String)
    case invalidUploadSource(String)
    case invalidFilePreview(String)
    case dashboardAddressUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            return "Apple container runtime is not installed at /usr/local/bin/container."
        case let .downloadFailed(message):
            return "Runtime download failed: \(message)"
        case let .invalidHTTPStatus(code):
            return "Runtime download returned HTTP \(code)."
        case let .commandFailed(command, exitCode, stderr):
            let detail = stderr.isEmpty ? "Unknown error." : stderr
            return "Command failed (\(exitCode)): \(command)\n\(detail)"
        case let .commandTimeout(command, seconds):
            return "Command timed out after \(Int(seconds))s: \(command)"
        case .missingDockerfile:
            return "Could not find Dockerfile in app bundle."
        case let .imageBuildFailed(message):
            return "Failed to build default image.\n\(message)"
        case let .invalidDirectoryListing(message):
            return "Failed to read agent filesystem.\n\(message)"
        case let .invalidUploadSource(message):
            return "File upload failed.\n\(message)"
        case let .invalidFilePreview(message):
            return "File preview failed.\n\(message)"
        case let .dashboardAddressUnavailable(message):
            return "Dashboard is unavailable.\n\(message)"
        }
    }
}

enum AgentFileType: String, Codable {
    case directory
    case file
    case symlink
    case other
}

struct AgentFileEntry: Identifiable, Hashable, Codable {
    let name: String
    let path: String
    let kind: AgentFileType
    let size: Int64
    let modified: TimeInterval

    var id: String { path }
    var isDirectory: Bool { kind == .directory }
}

struct AgentDirectoryListing: Codable {
    let path: String
    let entries: [AgentFileEntry]
}

struct AgentUploadResult: Hashable {
    var uploadedFiles: Int
    var uploadedDirectories: Int
}

struct AgentFilePreview: Codable {
    let path: String
    let text: String
    let truncated: Bool
    let binary: Bool
}

private struct DashboardEndpoint {
    let host: String
    let port: Int
}

@MainActor
@Observable
final class AgentManager {
    let runtimePath = "/usr/local/bin/container"
    let imageTag = "clawmarket/default:latest"
    let imageName = "clawmarket/default"
    let containerName = "claw-agent-1"
    let containerMemory = "4096M"
    let defaultBrowsePath = "/home/agent"
    let dashboardPort = 18789
    let dashboardLocalHost = "127.0.0.1"
    let runtimeInstallerURL = URL(string: "https://github.com/apple/container/releases/download/0.9.0/container-installer-signed.pkg")!
    let logMaxBytes = 1_000_000

    var state: AgentState = .checking
    var lastCommandOutput: String = ""
    var lastErrorMessage: String?

    init(autoSync: Bool = true) {
        prepareLogging()
        if autoSync {
            Task {
                await sync()
            }
        }
    }

    func sync() async {
        state = .checking
        lastErrorMessage = nil
        do {
            guard await checkRuntime() else {
                if case .error = state {
                    return
                }
                state = .noRuntime
                return
            }
            if try await !imageExists() {
                state = .needsImage
                return
            }
            if try await !containerExists() {
                state = .needsContainer
                return
            }
            state = try await containerIsRunning() ? .running : .stopped
        } catch {
            setError(error)
        }
    }

    func checkRuntime() async -> Bool {
        guard FileManager.default.fileExists(atPath: runtimePath) else {
            return false
        }

        do {
            let status = try await shell("system", "status")
            return status.contains("apiserver is running")
        } catch {
            do {
                _ = try await shell("system", "start")
                let status = try await shell("system", "status")
                return status.contains("apiserver is running")
            } catch {
                setError(error)
                return false
            }
        }
    }

    func imageExists() async throws -> Bool {
        let output = try await shell("image", "ls")
        return output.contains(imageName)
    }

    func buildImage() async throws {
        guard await checkRuntime() else {
            throw AgentManagerError.runtimeMissing
        }

        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "clawmarket-build-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        guard let dockerfileURL = resolveDockerfileURL() else {
            throw AgentManagerError.missingDockerfile
        }

        let destination = temporaryDirectory.appendingPathComponent("Dockerfile")
        try fileManager.copyItem(at: dockerfileURL, to: destination)

        do {
            _ = try await shell("build", "-t", imageTag, temporaryDirectory.path)
        } catch {
            throw AgentManagerError.imageBuildFailed(error.localizedDescription)
        }
    }

    func containerExists() async throws -> Bool {
        let output = try await shell("ls", "-a")
        return listOutput(output, containsName: containerName)
    }

    func containerIsRunning() async throws -> Bool {
        let output = try await shell("ls")
        return listOutput(output, containsName: containerName)
    }

    func createContainer() async throws {
        guard await checkRuntime() else {
            throw AgentManagerError.runtimeMissing
        }
        if try await containerExists() {
            return
        }
        _ = try await shell(
            "create",
            "--name", containerName,
            "-m", containerMemory,
            "-p", "\(dashboardLocalHost):\(dashboardPort):\(dashboardPort)",
            imageTag,
            "sleep", "infinity"
        )
    }

    func startContainer() async throws {
        guard await checkRuntime() else {
            throw AgentManagerError.runtimeMissing
        }
        if try await containerIsRunning() {
            state = .running
            return
        }
        if try await !containerExists() {
            try await createContainer()
        }

        state = .starting
        do {
            _ = try await shell("start", containerName)
            state = .running
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("already running") {
                state = .running
            } else {
                throw error
            }
        }
    }

    func stopContainer() async throws {
        guard await checkRuntime() else {
            throw AgentManagerError.runtimeMissing
        }
        if try await !containerExists() {
            state = .needsContainer
            return
        }
        if try await !containerIsRunning() {
            state = .stopped
            return
        }
        _ = try await shell("stop", containerName)
        state = .stopped
    }

    func deleteContainer() async throws {
        guard await checkRuntime() else {
            throw AgentManagerError.runtimeMissing
        }
        if try await containerIsRunning() {
            _ = try await shell("stop", containerName)
        }
        if try await containerExists() {
            _ = try await shell("rm", containerName)
        }
        state = .needsContainer
    }

    func deleteImage() async throws {
        guard await checkRuntime() else {
            throw AgentManagerError.runtimeMissing
        }
        if try await imageExists() {
            _ = try await shell("image", "rm", imageTag)
        }
        state = .needsImage
    }

    func factoryReset() async throws {
        try await deleteContainer()
        try await deleteImage()
        state = .needsImage
    }

    func listDirectory(path: String) async throws -> AgentDirectoryListing {
        guard await checkRuntime() else {
            throw AgentManagerError.runtimeMissing
        }
        guard try await containerIsRunning() else {
            throw AgentManagerError.commandFailed(
                command: "container exec",
                exitCode: 1,
                stderr: "Container \(containerName) is not running."
            )
        }

        let listingScript = """
import json, os, stat, sys
target = sys.argv[1] if len(sys.argv) > 1 else "."
target = os.path.abspath(os.path.expanduser(target))
result = {"path": target, "entries": []}
try:
    names = os.listdir(target)
except Exception as exc:
    print(json.dumps({"error": str(exc), "path": target}))
    raise SystemExit(0)

for name in names:
    full_path = os.path.join(target, name)
    try:
        st = os.lstat(full_path)
    except Exception:
        continue

    mode = st.st_mode
    if stat.S_ISDIR(mode):
        kind = "directory"
    elif stat.S_ISREG(mode):
        kind = "file"
    elif stat.S_ISLNK(mode):
        kind = "symlink"
    else:
        kind = "other"

    result["entries"].append({
        "name": name,
        "path": full_path,
        "kind": kind,
        "size": int(st.st_size),
        "modified": float(st.st_mtime),
    })

result["entries"].sort(key=lambda item: (item["kind"] != "directory", item["name"].lower()))
print(json.dumps(result))
"""

        let output = try await shell(
            ["exec", containerName, "python3", "-c", listingScript, path],
            timeout: 120
        )

        let data = Data(output.utf8)
        let decoder = JSONDecoder()

        struct ListingError: Decodable {
            let error: String
            let path: String
        }

        if let listingError = try? decoder.decode(ListingError.self, from: data) {
            throw AgentManagerError.invalidDirectoryListing("\(listingError.path): \(listingError.error)")
        }

        do {
            return try decoder.decode(AgentDirectoryListing.self, from: data)
        } catch {
            throw AgentManagerError.invalidDirectoryListing("Unexpected listing output for path \(path).")
        }
    }

    func uploadItem(from sourceURL: URL, toDirectory directoryPath: String) async throws -> AgentUploadResult {
        try await ensureContainerRunningForFileOperations()
        return try await uploadItemRecursive(from: sourceURL, toDirectory: directoryPath)
    }

    func readFilePreview(path: String, maxBytes: Int = 256_000) async throws -> AgentFilePreview {
        try await ensureContainerRunningForFileOperations()

        let previewScript = """
import json, sys
path = sys.argv[1]
max_bytes = int(sys.argv[2])
try:
    with open(path, "rb") as handle:
        data = handle.read(max_bytes + 1)
except Exception as exc:
    print(json.dumps({"error": str(exc), "path": path}))
    raise SystemExit(0)

truncated = len(data) > max_bytes
if truncated:
    data = data[:max_bytes]

binary = b"\\x00" in data
text = data.decode("utf-8", errors="replace")
print(json.dumps({
    "path": path,
    "text": text,
    "truncated": truncated,
    "binary": binary
}))
"""

        let output = try await shell(
            ["exec", containerName, "python3", "-c", previewScript, path, String(maxBytes)],
            timeout: 120
        )

        let data = Data(output.utf8)
        let decoder = JSONDecoder()

        struct PreviewError: Decodable {
            let error: String
            let path: String
        }

        if let previewError = try? decoder.decode(PreviewError.self, from: data) {
            throw AgentManagerError.invalidFilePreview("\(previewError.path): \(previewError.error)")
        }

        do {
            return try decoder.decode(AgentFilePreview.self, from: data)
        } catch {
            throw AgentManagerError.invalidFilePreview("Unexpected preview output for path \(path).")
        }
    }

    func dashboardURL() async throws -> URL {
        try await ensureContainerRunningForFileOperations()
        try await configureDashboardControlUIAccess()
        try await ensureDashboardGatewayRunning()
        if let endpoint = try await resolvePublishedDashboardEndpoint() {
            guard let publishedURL = URL(string: "http://\(endpoint.host):\(endpoint.port)") else {
                throw AgentManagerError.dashboardAddressUnavailable("Failed to construct dashboard URL from published port mapping.")
            }
            return publishedURL
        }

        let ipAddress = try await resolveContainerIPAddress()
        guard let fallbackURL = URL(string: "http://\(ipAddress):\(dashboardPort)") else {
            throw AgentManagerError.dashboardAddressUnavailable("Failed to construct dashboard URL from container IP.")
        }
        return fallbackURL
    }

    private func uploadItemRecursive(from sourceURL: URL, toDirectory directoryPath: String) async throws -> AgentUploadResult {
        guard sourceURL.isFileURL else {
            throw AgentManagerError.invalidUploadSource("Only local files can be uploaded.")
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        let values = try sourceURL.resourceValues(forKeys: keys)
        let fileName = sourceURL.lastPathComponent
        guard !fileName.isEmpty else {
            throw AgentManagerError.invalidUploadSource("Could not resolve item name for upload.")
        }

        if values.isSymbolicLink == true {
            throw AgentManagerError.invalidUploadSource("Symlinks are not supported: \(fileName)")
        }

        if values.isDirectory == true {
            let destinationDirectory = (directoryPath as NSString).appendingPathComponent(fileName)
            try await ensureDirectoryExistsInContainer(path: destinationDirectory)

            var result = AgentUploadResult(uploadedFiles: 0, uploadedDirectories: 1)
            let fileManager = FileManager.default
            let children = try fileManager.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
            for child in children.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
                let childResult = try await uploadItemRecursive(from: child, toDirectory: destinationDirectory)
                result.uploadedFiles += childResult.uploadedFiles
                result.uploadedDirectories += childResult.uploadedDirectories
            }
            return result
        }

        guard values.isRegularFile == true else {
            throw AgentManagerError.invalidUploadSource("Unsupported item type: \(fileName)")
        }

        let destinationPath = (directoryPath as NSString).appendingPathComponent(fileName)
        _ = try await uploadFileContents(from: sourceURL, destinationPath: destinationPath)
        return AgentUploadResult(uploadedFiles: 1, uploadedDirectories: 0)
    }

    private func uploadFileContents(from sourceURL: URL, destinationPath: String) async throws -> String {
        let uploadScript = """
import os, sys
destination = sys.argv[1]
parent = os.path.dirname(destination)
if parent:
    os.makedirs(parent, exist_ok=True)
with open(destination, "wb") as handle:
    while True:
        chunk = sys.stdin.buffer.read(1024 * 1024)
        if not chunk:
            break
        handle.write(chunk)
print(destination)
"""

        let timeout = max(120, inferredUploadTimeout(for: sourceURL))
        return try await runCommand(
            executable: runtimePath,
            args: ["exec", "-i", containerName, "python3", "-c", uploadScript, destinationPath],
            timeout: timeout,
            inputFilePath: sourceURL.path
        )
    }

    private func ensureDirectoryExistsInContainer(path: String) async throws {
        let mkdirScript = """
import os, sys
target = sys.argv[1]
os.makedirs(target, exist_ok=True)
print(target)
"""
        _ = try await shell(["exec", containerName, "python3", "-c", mkdirScript, path], timeout: 60)
    }

    private func ensureContainerRunningForFileOperations() async throws {
        guard await checkRuntime() else {
            throw AgentManagerError.runtimeMissing
        }
        guard try await containerIsRunning() else {
            throw AgentManagerError.commandFailed(
                command: "container exec",
                exitCode: 1,
                stderr: "Container \(containerName) is not running."
            )
        }
    }

    private func ensureDashboardGatewayRunning() async throws {
        let startGatewayScript = """
if pgrep -f "[o]penclaw-gateway" >/dev/null 2>&1; then
  echo "running"
else
  export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=768}"
  nohup openclaw gateway --bind lan >/tmp/openclaw-gateway.log 2>&1 &
  sleep 2
  pgrep -f "[o]penclaw-gateway" >/dev/null 2>&1 && echo "started" || echo "failed"
fi
"""

        let output = try await shell(
            ["exec", containerName, "/bin/bash", "-lc", startGatewayScript],
            timeout: 90
        )

        if output.contains("failed") {
            throw AgentManagerError.dashboardAddressUnavailable(
                "Could not start gateway inside container. Check /tmp/openclaw-gateway.log in the agent."
            )
        }
    }

    private func configureDashboardControlUIAccess() async throws {
        let configureScript = """
openclaw config set gateway.controlUi.allowInsecureAuth true --json >/dev/null 2>&1 || true
openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth true --json >/dev/null 2>&1 || true
echo "configured"
"""
        _ = try await shell(
            ["exec", containerName, "/bin/bash", "-lc", configureScript],
            timeout: 90
        )
    }

    private func resolvePublishedDashboardEndpoint() async throws -> DashboardEndpoint? {
        let output = try await shell("inspect", containerName)
        guard let data = output.data(using: .utf8) else {
            return nil
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let first = root.first,
            let configuration = first["configuration"] as? [String: Any],
            let publishedPorts = configuration["publishedPorts"] as? [[String: Any]]
        else {
            return nil
        }

        for mapping in publishedPorts {
            let containerPort = intValue(mapping["containerPort"])
            let hostPort = intValue(mapping["hostPort"])
            let rawHost = stringValue(mapping["hostAddress"]) ?? stringValue(mapping["hostIP"]) ?? stringValue(mapping["hostIp"]) ?? dashboardLocalHost

            guard containerPort == dashboardPort, let hostPort else {
                continue
            }

            let host = normalizeDashboardHost(rawHost)
            return DashboardEndpoint(host: host, port: hostPort)
        }

        return nil
    }

    private func normalizeDashboardHost(_ value: String) -> String {
        if value.isEmpty || value == "0.0.0.0" || value == "::" {
            return dashboardLocalHost
        }
        return value
    }

    private func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.intValue
        }
        if let stringValue = value as? String {
            return Int(stringValue)
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let stringValue = value as? String {
            return stringValue
        }
        return nil
    }

    private func resolveContainerIPAddress() async throws -> String {
        let output = try await shell("ls", "-a")
        let lines = output.split(whereSeparator: \.isNewline)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard
                !trimmed.isEmpty,
                !trimmed.hasPrefix("ID"),
                trimmed.hasPrefix(containerName)
            else {
                continue
            }

            if let match = trimmed.range(of: #"\b\d{1,3}(?:\.\d{1,3}){3}\b"#, options: .regularExpression) {
                return String(trimmed[match])
            }
        }

        throw AgentManagerError.dashboardAddressUnavailable(
            "Could not resolve container IP address from runtime output."
        )
    }

    func resetError() {
        lastErrorMessage = nil
    }

    func installRuntime(progress: @escaping (String) -> Void) async throws {
        progress("Downloading Apple container runtime...")
        let installerPath = try await downloadRuntimeInstaller()

        progress("Requesting administrator privileges for installation...")
        let installCommand = "installer -pkg '\(shellSingleQuoteSafe(installerPath))' -target /"
        let appleScript = "do shell script \"\(appleScriptStringSafe(installCommand))\" with administrator privileges"
        _ = try await runCommand(
            executable: "/usr/bin/osascript",
            args: ["-e", appleScript],
            timeout: 1800
        )

        progress("Starting container runtime service...")
        _ = try await shell("system", "start")
        _ = try await shell("system", "status")
        progress("Runtime installation complete.")
    }

    @discardableResult
    private func shell(_ args: String...) async throws -> String {
        try await shell(args)
    }

    @discardableResult
    private func shell(_ args: [String], timeout: TimeInterval = 600) async throws -> String {
        try await runCommand(executable: runtimePath, args: args, timeout: timeout)
    }

    @discardableResult
    private func runCommand(
        executable: String,
        args: [String],
        timeout: TimeInterval = 600,
        inputFilePath: String? = nil
    ) async throws -> String {
        let command = ([executable] + args).joined(separator: " ")
        log("CMD START: \(command)")
        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> CommandResult in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args

                let fileManager = FileManager.default
                let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent("clawmarket-shell-\(UUID().uuidString)")
                try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                defer {
                    try? fileManager.removeItem(at: tempDirectory)
                }

                let stdoutURL = tempDirectory.appendingPathComponent("stdout.log")
                let stderrURL = tempDirectory.appendingPathComponent("stderr.log")
                _ = fileManager.createFile(atPath: stdoutURL.path, contents: nil)
                _ = fileManager.createFile(atPath: stderrURL.path, contents: nil)
                let stdoutWriter = try FileHandle(forWritingTo: stdoutURL)
                let stderrWriter = try FileHandle(forWritingTo: stderrURL)
                defer {
                    try? stdoutWriter.close()
                    try? stderrWriter.close()
                }

                process.standardOutput = stdoutWriter
                process.standardError = stderrWriter

                var inputReader: FileHandle?
                if let inputFilePath {
                    let inputURL = URL(fileURLWithPath: inputFilePath)
                    inputReader = try FileHandle(forReadingFrom: inputURL)
                    process.standardInput = inputReader
                }
                defer {
                    try? inputReader?.close()
                }

                try process.run()
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning {
                    if Date() > deadline {
                        process.terminate()
                        try await Task.sleep(for: .milliseconds(250))
                        if process.isRunning {
                            process.interrupt()
                        }
                        throw AgentManagerError.commandTimeout(command: command, seconds: timeout)
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
                let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                let exitCode = process.terminationStatus
                if exitCode != 0 {
                    throw AgentManagerError.commandFailed(
                        command: command,
                        exitCode: exitCode,
                        stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                return CommandResult(stdout: stdout, stderr: stderr)
            }.value

            let stdoutTrimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderrTrimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            lastCommandOutput = ([stdoutTrimmed, stderrTrimmed].filter { !$0.isEmpty }).joined(separator: "\n")

            if !stdoutTrimmed.isEmpty {
                log("CMD OK: \(trimForLog(stdoutTrimmed))")
            } else {
                log("CMD OK: (no stdout)")
            }
            return stdoutTrimmed
        } catch {
            log("CMD ERROR: \(error.localizedDescription)")
            throw error
        }
    }

    private func downloadRuntimeInstaller() async throws -> String {
        let (downloadedFile, response) = try await URLSession.shared.download(from: runtimeInstallerURL)
        guard let http = response as? HTTPURLResponse else {
            throw AgentManagerError.downloadFailed("Invalid response type.")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw AgentManagerError.invalidHTTPStatus(http.statusCode)
        }

        let fileManager = FileManager.default
        let destination = fileManager.temporaryDirectory.appendingPathComponent("container-installer-signed.pkg")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: downloadedFile, to: destination)
        } catch {
            throw AgentManagerError.downloadFailed(error.localizedDescription)
        }
        return destination.path
    }

    private func shellSingleQuoteSafe(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func appleScriptStringSafe(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func listOutput(_ output: String, containsName name: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("ID") else {
                return false
            }
            let columns = trimmed.split(whereSeparator: \.isWhitespace)
            return columns.first == Substring(name)
        }
    }

    private func resolveDockerfileURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "Dockerfile", withExtension: nil) {
            return bundled
        }
        if let bundledInResources = Bundle.main.url(forResource: "Dockerfile", withExtension: nil, subdirectory: "Resources") {
            return bundledInResources
        }

        let sourcePath = URL(fileURLWithPath: #filePath)
        let developmentDockerfile = sourcePath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent("Dockerfile")
        if FileManager.default.fileExists(atPath: developmentDockerfile.path) {
            return developmentDockerfile
        }
        return nil
    }

    private var logDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("ClawMarket", isDirectory: true)
    }

    private var logFileURL: URL {
        logDirectoryURL.appendingPathComponent("agent.log")
    }

    private func prepareLogging() {
        try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
        log("Logger initialized")
    }

    private func rotateLogIfNeeded() {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
            let size = attrs[.size] as? NSNumber,
            size.intValue > logMaxBytes
        else {
            return
        }
        let archived = logDirectoryURL.appendingPathComponent("agent.log.1")
        try? FileManager.default.removeItem(at: archived)
        try? FileManager.default.moveItem(at: logFileURL, to: archived)
    }

    private func log(_ message: String) {
        rotateLogIfNeeded()
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    try? handle.close()
                }
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }

    private func trimForLog(_ message: String, maxLength: Int = 400) -> String {
        if message.count <= maxLength {
            return message
        }
        return String(message.prefix(maxLength)) + "..."
    }

    private func inferredUploadTimeout(for sourceURL: URL) -> TimeInterval {
        let size = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let bytesPerSecond = 8_000_000
        let seconds = Double(size) / Double(bytesPerSecond)
        return seconds + 30
    }

    private func setError(_ error: Error) {
        let message = error.localizedDescription
        lastErrorMessage = message
        state = .error(message)
        log("STATE ERROR: \(message)")
    }
}

private struct CommandResult {
    let stdout: String
    let stderr: String
}
