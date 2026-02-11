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

@MainActor
@Observable
final class AgentManager {
    let runtimePath = "/usr/local/bin/container"
    let imageTag = "clawmarket/default:latest"
    let imageName = "clawmarket/default"
    let containerName = "claw-agent-1"
    let containerMemory = "4096M"
    let defaultBrowsePath = "/home/agent"
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
    private func runCommand(executable: String, args: [String], timeout: TimeInterval = 600) async throws -> String {
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
