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
        }
    }
}

@MainActor
@Observable
final class AgentManager {
    let runtimePath = "/usr/local/bin/container"
    let imageTag = "clawmarket/default:latest"
    let imageName = "clawmarket/default"
    let containerName = "claw-agent-1"
    let containerMemory = "2048M"
    let runtimeInstallerURL = URL(string: "https://github.com/apple/container/releases/download/0.9.0/container-installer-signed.pkg")!

    var state: AgentState = .checking
    var lastCommandOutput: String = ""
    var lastErrorMessage: String?

    init(autoSync: Bool = true) {
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
        return stdoutTrimmed
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

    private func setError(_ error: Error) {
        let message = error.localizedDescription
        lastErrorMessage = message
        state = .error(message)
    }
}

private struct CommandResult {
    let stdout: String
    let stderr: String
}
