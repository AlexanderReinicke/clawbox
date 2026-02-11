import Foundation
import Observation
import Darwin

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

enum AgentSlotRuntimeState: Equatable {
    case missing
    case stopped
    case running
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
    case invalidFileWrite(String)
    case invalidFileMutation(String)
    case dashboardAddressUnavailable(String)
    case keepAwakeControlFailed(String)

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
        case let .invalidFileWrite(message):
            return "File save failed.\n\(message)"
        case let .invalidFileMutation(message):
            return "File operation failed.\n\(message)"
        case let .dashboardAddressUnavailable(message):
            return "Dashboard is unavailable.\n\(message)"
        case let .keepAwakeControlFailed(message):
            return "Power control failed.\n\(message)"
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

struct HostSystemStats: Equatable {
    let cpuUserPercent: Double
    let cpuSystemPercent: Double
    let cpuIdlePercent: Double
    let memoryUsedGB: Double?
    let memoryUnusedGB: Double?
    let memoryTotalGB: Double?
    let load1: Double
    let load5: Double
    let load15: Double

    var cpuBusyPercent: Double {
        max(0, min(100, cpuUserPercent + cpuSystemPercent))
    }

    var memoryUsedPercent: Double? {
        guard let memoryUsedGB, let memoryTotalGB, memoryTotalGB > 0 else {
            return nil
        }
        return max(0, min(100, (memoryUsedGB / memoryTotalGB) * 100))
    }
}

struct AgentRuntimeSnapshot: Equatable {
    let slot: Int
    let state: AgentSlotRuntimeState
    let cpus: Int?
    let configuredMemoryBytes: Int64?
    let liveMemoryUsageBytes: Int64?
    let liveMemoryLimitBytes: Int64?
    let cpuPercent: Double?
    let processCount: Int?
    let networkRxBytes: Int64?
    let networkTxBytes: Int64?
    let ipv4Address: String?
    let dashboardHostPort: Int?
    let startedAt: Date?

    var configuredMemoryGB: Double? {
        configuredMemoryBytes.map { Double($0) / 1_073_741_824.0 }
    }

    var liveMemoryUsageGB: Double? {
        liveMemoryUsageBytes.map { Double($0) / 1_073_741_824.0 }
    }

    var liveMemoryLimitGB: Double? {
        liveMemoryLimitBytes.map { Double($0) / 1_073_741_824.0 }
    }
}

private struct ContainerListEntry: Decodable {
    struct Configuration: Decodable {
        struct Resources: Decodable {
            let cpus: Int?
            let memoryInBytes: Int64?
        }

        struct PublishedPort: Decodable {
            let hostPort: Int?
            let containerPort: Int?
        }

        let id: String
        let resources: Resources?
        let publishedPorts: [PublishedPort]?
    }

    struct NetworkAttachment: Decodable {
        let ipv4Address: String?
    }

    let status: String
    let configuration: Configuration
    let networks: [NetworkAttachment]?
    let startedDate: TimeInterval?
}

private struct ContainerStatsEntry: Decodable {
    let id: String
    let cpuUsageUsec: Int64?
    let memoryUsageBytes: Int64?
    let memoryLimitBytes: Int64?
    let numProcesses: Int?
    let networkRxBytes: Int64?
    let networkTxBytes: Int64?
}

@MainActor
@Observable
final class AgentManager {
    let runtimePath = "/usr/local/bin/container"
    let imageTag = "clawmarket/default:latest"
    let imageName = "clawmarket/default"
    let containerNamePrefix = "claw-agent-"
    var containerName = "claw-agent-1"
    let defaultContainerMemoryGB = 4
    let minimumContainerMemoryGB = 2
    let containerAccessMountPath = "/mnt/access"
    let defaultBrowsePath = "/home/agent"
    let dashboardContainerPort = 18789
    let dashboardHostBasePort = 18789
    let dashboardLocalHost = "127.0.0.1"
    let runtimeInstallerURL = URL(string: "https://github.com/apple/container/releases/download/0.9.0/container-installer-signed.pkg")!
    let logMaxBytes = 1_000_000
    let keepAwakeDurationSeconds = 24 * 60 * 60
    let lockScreenExecutable = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
    let caffeinateExecutable = "/usr/bin/caffeinate"
    let displaySleepExecutable = "/usr/bin/pmset"

    var state: AgentState = .checking
    var lastCommandOutput: String = ""
    var lastErrorMessage: String?
    var hostSystemStats: HostSystemStats?
    var containerAllocatedMemoryGB: Double?
    var containerAllocatedCPUs: Int?
    private var hasEnsuredGatewayForCurrentRun = false
    private var previousCPUStatByContainer: [String: (usageUsec: Int64, capturedAt: Date)] = [:]

    init(autoSync: Bool = true) {
        prepareLogging()
        if autoSync {
            Task {
                await sync()
            }
        }
    }

    func containerName(forSlot slot: Int) -> String {
        "\(containerNamePrefix)\(max(1, slot))"
    }

    func selectContainer(slot: Int) {
        selectContainer(named: containerName(forSlot: slot))
    }

    func selectContainer(named name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, containerName != normalized else {
            return
        }
        containerName = normalized
        hasEnsuredGatewayForCurrentRun = false
        clearContainerRuntimeResources()
    }

    func managedContainerStates(slotCount: Int) async -> [Int: AgentSlotRuntimeState] {
        let desiredSlots = max(1, slotCount)
        guard FileManager.default.fileExists(atPath: runtimePath) else {
            return Dictionary(uniqueKeysWithValues: (1 ... desiredSlots).map { ($0, .missing) })
        }

        do {
            let allOutput = try await shell("ls", "-a")
            let runningOutput = try await shell("ls")
            let existingNames = parseContainerNames(from: allOutput)
            let runningNames = parseContainerNames(from: runningOutput)

            var states: [Int: AgentSlotRuntimeState] = [:]
            for slot in 1 ... desiredSlots {
                let name = containerName(forSlot: slot)
                if runningNames.contains(name) {
                    states[slot] = .running
                } else if existingNames.contains(name) {
                    states[slot] = .stopped
                } else {
                    states[slot] = .missing
                }
            }
            return states
        } catch {
            log("Managed container state query failed: \(error.localizedDescription)")
            return Dictionary(uniqueKeysWithValues: (1 ... desiredSlots).map { ($0, .missing) })
        }
    }

    func managedContainerStates(slots: [Int]) async -> [Int: AgentSlotRuntimeState] {
        let normalizedSlots = Array(Set(slots.map { max(1, $0) })).sorted()
        guard !normalizedSlots.isEmpty else {
            return [:]
        }

        guard FileManager.default.fileExists(atPath: runtimePath) else {
            return Dictionary(uniqueKeysWithValues: normalizedSlots.map { ($0, .missing) })
        }

        do {
            let allOutput = try await shell("ls", "-a")
            let runningOutput = try await shell("ls")
            let existingNames = parseContainerNames(from: allOutput)
            let runningNames = parseContainerNames(from: runningOutput)

            var states: [Int: AgentSlotRuntimeState] = [:]
            for slot in normalizedSlots {
                let name = containerName(forSlot: slot)
                if runningNames.contains(name) {
                    states[slot] = .running
                } else if existingNames.contains(name) {
                    states[slot] = .stopped
                } else {
                    states[slot] = .missing
                }
            }
            return states
        } catch {
            log("Managed container state query failed: \(error.localizedDescription)")
            return Dictionary(uniqueKeysWithValues: normalizedSlots.map { ($0, .missing) })
        }
    }

    func discoveredManagedAgentSlots() async -> Set<Int> {
        guard FileManager.default.fileExists(atPath: runtimePath) else {
            return []
        }

        do {
            let allOutput = try await shell("ls", "-a")
            let names = parseContainerNames(from: allOutput)
            return Set(names.compactMap { containerSlotIndex(fromContainerName: $0) })
        } catch {
            log("Managed slot discovery failed: \(error.localizedDescription)")
            return []
        }
    }

    func managedAgentRuntimeSnapshots(slots: [Int]) async -> [Int: AgentRuntimeSnapshot] {
        let normalizedSlots = Array(Set(slots.map { max(1, $0) })).sorted()
        guard !normalizedSlots.isEmpty else {
            return [:]
        }

        guard FileManager.default.fileExists(atPath: runtimePath) else {
            return Dictionary(
                uniqueKeysWithValues: normalizedSlots.map { slot in
                    (slot, AgentRuntimeSnapshot(
                        slot: slot,
                        state: .missing,
                        cpus: nil,
                        configuredMemoryBytes: nil,
                        liveMemoryUsageBytes: nil,
                        liveMemoryLimitBytes: nil,
                        cpuPercent: nil,
                        processCount: nil,
                        networkRxBytes: nil,
                        networkTxBytes: nil,
                        ipv4Address: nil,
                        dashboardHostPort: nil,
                        startedAt: nil
                    ))
                }
            )
        }

        do {
            let listOutput = try await shell(["ls", "--all", "--format", "json"], timeout: 40)
            guard let listData = listOutput.data(using: .utf8) else {
                return [:]
            }
            let containers = try JSONDecoder().decode([ContainerListEntry].self, from: listData)
            let containersByName = Dictionary(uniqueKeysWithValues: containers.map { ($0.configuration.id, $0) })

            var snapshots: [Int: AgentRuntimeSnapshot] = [:]
            for slot in normalizedSlots {
                let name = containerName(forSlot: slot)
                guard let entry = containersByName[name] else {
                    previousCPUStatByContainer.removeValue(forKey: name)
                    snapshots[slot] = AgentRuntimeSnapshot(
                        slot: slot,
                        state: .missing,
                        cpus: nil,
                        configuredMemoryBytes: nil,
                        liveMemoryUsageBytes: nil,
                        liveMemoryLimitBytes: nil,
                        cpuPercent: nil,
                        processCount: nil,
                        networkRxBytes: nil,
                        networkTxBytes: nil,
                        ipv4Address: nil,
                        dashboardHostPort: nil,
                        startedAt: nil
                    )
                    continue
                }

                let runtimeState = runtimeState(fromListStatus: entry.status)
                let cpus = entry.configuration.resources?.cpus
                let configuredMemoryBytes = entry.configuration.resources?.memoryInBytes
                let startedAt = entry.startedDate.map { Date(timeIntervalSinceReferenceDate: $0) }
                let ipv4Address = normalizedIPv4Address(from: entry.networks?.first?.ipv4Address)
                let dashboardPort = entry.configuration.publishedPorts?
                    .first(where: { $0.containerPort == dashboardContainerPort })?.hostPort

                var liveMemoryUsageBytes: Int64?
                var liveMemoryLimitBytes: Int64?
                var cpuPercent: Double?
                var processCount: Int?
                var networkRxBytes: Int64?
                var networkTxBytes: Int64?

                if runtimeState == .running {
                    if let statsEntry = try await fetchContainerStats(containerName: name) {
                        liveMemoryUsageBytes = statsEntry.memoryUsageBytes
                        liveMemoryLimitBytes = statsEntry.memoryLimitBytes
                        processCount = statsEntry.numProcesses
                        networkRxBytes = statsEntry.networkRxBytes
                        networkTxBytes = statsEntry.networkTxBytes
                        if let cpuUsageUsec = statsEntry.cpuUsageUsec {
                            cpuPercent = updateAndComputeCPUPercent(
                                containerName: name,
                                cpuUsageUsec: cpuUsageUsec,
                                cpus: cpus
                            )
                        }
                    }
                } else {
                    previousCPUStatByContainer.removeValue(forKey: name)
                }

                snapshots[slot] = AgentRuntimeSnapshot(
                    slot: slot,
                    state: runtimeState,
                    cpus: cpus,
                    configuredMemoryBytes: configuredMemoryBytes,
                    liveMemoryUsageBytes: liveMemoryUsageBytes,
                    liveMemoryLimitBytes: liveMemoryLimitBytes,
                    cpuPercent: cpuPercent,
                    processCount: processCount,
                    networkRxBytes: networkRxBytes,
                    networkTxBytes: networkTxBytes,
                    ipv4Address: ipv4Address,
                    dashboardHostPort: dashboardPort,
                    startedAt: startedAt
                )
            }
            return snapshots
        } catch {
            log("Managed runtime metrics query failed: \(error.localizedDescription)")
            return [:]
        }
    }

    func sync() async {
        lastErrorMessage = nil
        do {
            guard await checkRuntime() else {
                if case .error = state {
                    return
                }
                state = .noRuntime
                return
            }
            let hasContainer = try await containerExists()
            if !hasContainer {
                if try await !imageExists() {
                    state = .needsImage
                    return
                }
                clearContainerRuntimeResources()
                state = .needsContainer
                return
            }
            await refreshContainerRuntimeResources()
            state = try await containerIsRunning() ? .running : .stopped
            if state == .running {
                if !hasEnsuredGatewayForCurrentRun {
                    hasEnsuredGatewayForCurrentRun = true
                    await ensureGatewayReadyAfterStart()
                }
            } else {
                hasEnsuredGatewayForCurrentRun = false
            }
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

    func createContainer(accessFolderHostPath: String? = nil, memoryGB: Int? = nil) async throws {
        guard await checkRuntime() else {
            throw AgentManagerError.runtimeMissing
        }
        if try await containerExists() {
            return
        }

        let requestedMemoryGB = normalizedContainerMemoryGB(memoryGB)
        let dashboardHostPort = dashboardHostPort(forContainerName: containerName)
        var args = [
            "create",
            "--name", containerName,
            "-m", "\(requestedMemoryGB)G",
            "-p", "\(dashboardLocalHost):\(dashboardHostPort):\(dashboardContainerPort)"
        ]
        if let hostPath = normalizedAccessFolderHostPath(accessFolderHostPath) {
            args += ["-v", "\(hostPath):\(containerAccessMountPath)"]
        }
        args += [imageTag, "sleep", "infinity"]
        _ = try await shell(args)
        await refreshContainerRuntimeResources()
    }

    func startContainer(accessFolderHostPath: String? = nil, memoryGB: Int? = nil) async throws {
        guard await checkRuntime() else {
            throw AgentManagerError.runtimeMissing
        }
        if try await containerIsRunning() {
            state = .running
            await refreshContainerRuntimeResources()
            await ensureGatewayReadyAfterStart()
            hasEnsuredGatewayForCurrentRun = true
            return
        }
        if try await !containerExists() {
            try await createContainer(accessFolderHostPath: accessFolderHostPath, memoryGB: memoryGB)
        }

        state = .starting
        do {
            _ = try await shell("start", containerName)
            state = .running
            await refreshContainerRuntimeResources()
            await ensureGatewayReadyAfterStart()
            hasEnsuredGatewayForCurrentRun = true
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("already running") {
                state = .running
                await refreshContainerRuntimeResources()
                await ensureGatewayReadyAfterStart()
                hasEnsuredGatewayForCurrentRun = true
            } else if isAddressInUseError(message) {
                log("Detected host port conflict for \(containerName). Recreating with slot-specific dashboard port.")
                if try await containerIsRunning() {
                    _ = try await shell("stop", containerName)
                }
                if try await containerExists() {
                    _ = try await shell("rm", containerName)
                }
                try await createContainer(accessFolderHostPath: accessFolderHostPath, memoryGB: memoryGB)
                _ = try await shell("start", containerName)
                state = .running
                await refreshContainerRuntimeResources()
                await ensureGatewayReadyAfterStart()
                hasEnsuredGatewayForCurrentRun = true
            } else {
                throw error
            }
        }
    }

    func recreateContainer(accessFolderHostPath: String? = nil, memoryGB: Int? = nil) async throws {
        guard await checkRuntime() else {
            throw AgentManagerError.runtimeMissing
        }

        if try await containerIsRunning() {
            _ = try await shell("stop", containerName)
        }
        if try await containerExists() {
            _ = try await shell("rm", containerName)
        }

        try await createContainer(accessFolderHostPath: accessFolderHostPath, memoryGB: memoryGB)
        try await startContainer(accessFolderHostPath: accessFolderHostPath, memoryGB: memoryGB)
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
        await refreshContainerRuntimeResources()
        hasEnsuredGatewayForCurrentRun = false
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
        clearContainerRuntimeResources()
        state = .needsContainer
        hasEnsuredGatewayForCurrentRun = false
    }

    func deleteImage() async throws {
        guard await checkRuntime() else {
            throw AgentManagerError.runtimeMissing
        }
        if try await imageExists() {
            _ = try await shell("image", "rm", imageTag)
        }
        clearContainerRuntimeResources()
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

    func writeFile(path: String, text: String) async throws {
        try await ensureContainerRunningForFileOperations()

        guard let data = text.data(using: .utf8) else {
            throw AgentManagerError.invalidFileWrite("Could not encode text as UTF-8.")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawmarket-write-\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: [.atomic])
            defer {
                try? FileManager.default.removeItem(at: tempURL)
            }

            let writeScript = """
import os, sys
path = sys.argv[1]
parent = os.path.dirname(path)
if parent:
    os.makedirs(parent, exist_ok=True)
payload = sys.stdin.buffer.read()
with open(path, "wb") as handle:
    handle.write(payload)
print(path)
"""

            _ = try await runCommand(
                executable: runtimePath,
                args: ["exec", "-i", containerName, "python3", "-c", writeScript, path],
                timeout: 180,
                inputFilePath: tempURL.path
            )
        } catch {
            throw AgentManagerError.invalidFileWrite(error.localizedDescription)
        }
    }

    func createFile(path: String, text: String = "") async throws {
        try await ensureContainerRunningForFileOperations()

        guard let data = text.data(using: .utf8) else {
            throw AgentManagerError.invalidFileMutation("Could not encode text as UTF-8.")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawmarket-create-file-\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: [.atomic])
            defer {
                try? FileManager.default.removeItem(at: tempURL)
            }

            let createScript = """
import os, sys
path = sys.argv[1]
parent = os.path.dirname(path)
if parent:
    os.makedirs(parent, exist_ok=True)
if os.path.exists(path):
    raise FileExistsError(path)
payload = sys.stdin.buffer.read()
with open(path, "xb") as handle:
    handle.write(payload)
print(path)
"""

            _ = try await runCommand(
                executable: runtimePath,
                args: ["exec", "-i", containerName, "python3", "-c", createScript, path],
                timeout: 180,
                inputFilePath: tempURL.path
            )
        } catch {
            throw AgentManagerError.invalidFileMutation(error.localizedDescription)
        }
    }

    func createDirectory(path: String) async throws {
        try await ensureContainerRunningForFileOperations()

        let createScript = """
import os, sys
target = sys.argv[1]
if os.path.exists(target):
    raise FileExistsError(target)
os.makedirs(target, exist_ok=False)
print(target)
"""

        do {
            _ = try await shell(
                ["exec", containerName, "python3", "-c", createScript, path],
                timeout: 90
            )
        } catch {
            throw AgentManagerError.invalidFileMutation(error.localizedDescription)
        }
    }

    func renameItem(from sourcePath: String, to destinationPath: String) async throws {
        try await ensureContainerRunningForFileOperations()

        let renameScript = """
import os, shutil, sys
source = sys.argv[1]
destination = sys.argv[2]
if not os.path.lexists(source):
    raise FileNotFoundError(source)
if os.path.lexists(destination):
    raise FileExistsError(destination)
parent = os.path.dirname(destination)
if parent:
    os.makedirs(parent, exist_ok=True)
shutil.move(source, destination)
print(destination)
"""

        do {
            _ = try await shell(
                ["exec", containerName, "python3", "-c", renameScript, sourcePath, destinationPath],
                timeout: 120
            )
        } catch {
            throw AgentManagerError.invalidFileMutation(error.localizedDescription)
        }
    }

    func deleteItem(path: String) async throws {
        try await ensureContainerRunningForFileOperations()

        let deleteScript = """
import os, shutil, sys
target = sys.argv[1]
if not os.path.lexists(target):
    raise FileNotFoundError(target)
if os.path.isdir(target) and not os.path.islink(target):
    shutil.rmtree(target)
else:
    os.remove(target)
print(target)
"""

        do {
            _ = try await shell(
                ["exec", containerName, "python3", "-c", deleteScript, path],
                timeout: 180
            )
        } catch {
            throw AgentManagerError.invalidFileMutation(error.localizedDescription)
        }
    }

    func restartContainer() async throws {
        guard await checkRuntime() else {
            throw AgentManagerError.runtimeMissing
        }
        if try await !containerExists() {
            throw AgentManagerError.commandFailed(
                command: "container restart",
                exitCode: 1,
                stderr: "Container \(containerName) does not exist."
            )
        }

        if try await containerIsRunning() {
            _ = try await shell("stop", containerName)
        }
        _ = try await shell("start", containerName)
        state = .running
        await refreshContainerRuntimeResources()
        await ensureGatewayReadyAfterStart()
        hasEnsuredGatewayForCurrentRun = true
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

        let derivedHostPort = dashboardHostPort(forContainerName: containerName)
        if let localhostURL = URL(string: "http://\(dashboardLocalHost):\(derivedHostPort)") {
            return localhostURL
        }

        let ipAddress = try await resolveContainerIPAddress()
        guard let fallbackURL = URL(string: "http://\(ipAddress):\(dashboardContainerPort)") else {
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
if curl -fsS --max-time 2 http://127.0.0.1:\(dashboardContainerPort)/ >/dev/null 2>&1; then
  echo "running"
else
  export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=768}"
  nohup openclaw gateway --bind lan >/tmp/openclaw-gateway.log 2>&1 &
  for _ in 1 2 3 4 5; do
    sleep 1
    if curl -fsS --max-time 2 http://127.0.0.1:\(dashboardContainerPort)/ >/dev/null 2>&1; then
      echo "started"
      exit 0
    fi
  done
  echo "failed"
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
openclaw config set gateway.mode local >/dev/null 2>&1 || true
openclaw config set gateway.auth.token clawmarket-local >/dev/null 2>&1 || true
openclaw config set gateway.remote.token clawmarket-local >/dev/null 2>&1 || true
openclaw config set gateway.controlUi.allowInsecureAuth true --json >/dev/null 2>&1 || true
openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth true --json >/dev/null 2>&1 || true
echo "configured"
"""
        _ = try await shell(
            ["exec", containerName, "/bin/bash", "-lc", configureScript],
            timeout: 90
        )
    }

    private func ensureGatewayReadyAfterStart() async {
        do {
            try await configureDashboardControlUIAccess()
            try await ensureDashboardGatewayRunning()
        } catch {
            log("Gateway auto-start check failed: \(error.localizedDescription)")
        }
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

            guard containerPort == dashboardContainerPort, let hostPort else {
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

    private func refreshContainerRuntimeResources() async {
        guard (try? await containerExists()) == true else {
            clearContainerRuntimeResources()
            return
        }

        do {
            let output = try await shell("inspect", containerName)
            guard let data = output.data(using: .utf8) else {
                return
            }

            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                let first = root.first,
                let configuration = first["configuration"] as? [String: Any],
                let resources = configuration["resources"] as? [String: Any]
            else {
                return
            }

            if let memoryBytes = int64Value(resources["memoryInBytes"]) {
                containerAllocatedMemoryGB = Double(memoryBytes) / 1_073_741_824.0
            } else {
                containerAllocatedMemoryGB = nil
            }

            containerAllocatedCPUs = intValue(resources["cpus"])
        } catch {
            log("Container resource inspect failed: \(error.localizedDescription)")
        }
    }

    private func clearContainerRuntimeResources() {
        containerAllocatedMemoryGB = nil
        containerAllocatedCPUs = nil
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

    private func int64Value(_ value: Any?) -> Int64? {
        if let int64Value = value as? Int64 {
            return int64Value
        }
        if let intValue = value as? Int {
            return Int64(intValue)
        }
        if let numberValue = value as? NSNumber {
            return numberValue.int64Value
        }
        if let stringValue = value as? String {
            return Int64(stringValue)
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

    func deletePrimaryAgentData() async throws {
        try await ensureContainerRunningForFileOperations()
        let resetScript = """
pkill -f "openclaw gateway" >/dev/null 2>&1 || true
rm -rf /home/agent/.openclaw
mkdir -p /home/agent/.openclaw
echo "agent-reset"
"""
        _ = try await shell(["exec", containerName, "/bin/bash", "-lc", resetScript], timeout: 90)
        await ensureGatewayReadyAfterStart()
    }

    func refreshHostSystemStats() async {
        let statsScript = #"""
top_output="$(/usr/bin/top -l 1 -n 0 2>/dev/null || true)"
cpu_line="$(printf "%s\n" "$top_output" | /usr/bin/awk -F': ' '/CPU usage/ {print $2; exit}')"
mem_line="$(printf "%s\n" "$top_output" | /usr/bin/awk -F': ' '/PhysMem/ {print $2; exit}')"
load_line="$(/usr/sbin/sysctl -n vm.loadavg 2>/dev/null || true)"
total_bytes="$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || true)"

printf "CPU|%s\n" "$cpu_line"
printf "MEM|%s\n" "$mem_line"
printf "LOAD|%s\n" "$load_line"
printf "TOTAL|%s\n" "$total_bytes"
"""#

        do {
            let output = try await runCommand(
                executable: "/bin/zsh",
                args: ["-lc", statsScript],
                timeout: 20
            )
            if let parsed = parseHostSystemStats(output) {
                hostSystemStats = parsed
            }
        } catch {
            log("Host stats update failed: \(error.localizedDescription)")
        }
    }

    func lockScreenAndKeepAwake24Hours() async throws {
        try stopExistingKeepAwakeSessionIfNeeded()
        try startKeepAwakeSession(seconds: keepAwakeDurationSeconds)
        try await enableLidCloseSleepOverride24Hours()

        do {
            _ = try await runCommand(
                executable: lockScreenExecutable,
                args: ["-suspend"],
                timeout: 10
            )
        } catch {
            log("CGSession lock failed. Falling back to display sleep. \(error.localizedDescription)")
            do {
                _ = try await runCommand(
                    executable: displaySleepExecutable,
                    args: ["displaysleepnow"],
                    timeout: 10
                )
            } catch {
                throw AgentManagerError.keepAwakeControlFailed(
                    "Could not lock the screen with CGSession or pmset."
                )
            }
        }
    }

    func disableLidCloseSleepOverride() async throws {
        try await runPrivilegedShell(
            "/usr/bin/pmset -b disablesleep 0; /usr/bin/pmset -c disablesleep 0",
            timeout: 30
        )
        try stopExistingKeepAwakeSessionIfNeeded()
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

    func openNativeTerminal(containerName: String) async throws {
        let normalizedContainerName = containerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContainerName.isEmpty else {
            throw AgentManagerError.commandFailed(
                command: "open terminal",
                exitCode: 1,
                stderr: "Container name is empty."
            )
        }

        let command = "\(runtimePath) exec -i -t \(normalizedContainerName) /bin/bash"
        let activateScript = "tell application \"Terminal\" to activate"
        let launchScript = "tell application \"Terminal\" to do script \"\(appleScriptStringSafe(command))\""
        _ = try await runCommand(
            executable: "/usr/bin/osascript",
            args: ["-e", activateScript, "-e", launchScript],
            timeout: 20
        )
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

    private func runPrivilegedShell(_ command: String, timeout: TimeInterval = 120) async throws {
        let appleScript = "do shell script \"\(appleScriptStringSafe(command))\" with administrator privileges"
        do {
            _ = try await runCommand(
                executable: "/usr/bin/osascript",
                args: ["-e", appleScript],
                timeout: timeout
            )
        } catch {
            throw AgentManagerError.keepAwakeControlFailed(error.localizedDescription)
        }
    }

    private func listOutput(_ output: String, containsName name: String) -> Bool {
        parseContainerNames(from: output).contains(name)
    }

    private func runtimeState(fromListStatus status: String) -> AgentSlotRuntimeState {
        switch status.lowercased() {
        case "running":
            return .running
        case "stopped":
            return .stopped
        default:
            return .missing
        }
    }

    private func normalizedIPv4Address(from raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        return raw.split(separator: "/").first.map(String.init)
    }

    private func fetchContainerStats(containerName: String) async throws -> ContainerStatsEntry? {
        let output = try await shell(
            ["stats", containerName, "--no-stream", "--format", "json"],
            timeout: 40
        )
        guard let data = output.data(using: .utf8) else {
            return nil
        }
        let entries = try JSONDecoder().decode([ContainerStatsEntry].self, from: data)
        return entries.first(where: { $0.id == containerName }) ?? entries.first
    }

    private func updateAndComputeCPUPercent(containerName: String, cpuUsageUsec: Int64, cpus: Int?) -> Double? {
        let now = Date()
        defer {
            previousCPUStatByContainer[containerName] = (cpuUsageUsec, now)
        }

        guard let previous = previousCPUStatByContainer[containerName] else {
            return nil
        }

        let deltaUsage = cpuUsageUsec - previous.usageUsec
        let deltaWallUsec = now.timeIntervalSince(previous.capturedAt) * 1_000_000.0
        guard deltaUsage >= 0, deltaWallUsec > 0 else {
            return nil
        }

        let cpuCount = Swift.max(1, cpus ?? 1)
        let normalized = (Double(deltaUsage) / (deltaWallUsec * Double(cpuCount))) * 100.0
        return Swift.max(0, Swift.min(100, normalized))
    }

    private func parseContainerNames(from output: String) -> Set<String> {
        let names = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("ID") else {
                return nil
            }
            return trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        return Set(names)
    }

    private func containerSlotIndex(fromContainerName name: String) -> Int? {
        guard name.hasPrefix(containerNamePrefix) else {
            return nil
        }
        let suffix = String(name.dropFirst(containerNamePrefix.count))
        guard let value = Int(suffix), value > 0 else {
            return nil
        }
        return value
    }

    private func dashboardHostPort(forContainerName name: String) -> Int {
        let slot = containerSlotIndex(fromContainerName: name) ?? 1
        return dashboardHostBasePort + (slot - 1)
    }

    private func isAddressInUseError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("address already in use") || lower.contains("errno: 48")
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

    private func normalizedAccessFolderHostPath(_ path: String?) -> String? {
        guard let path else {
            return nil
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func normalizedContainerMemoryGB(_ value: Int?) -> Int {
        max(minimumContainerMemoryGB, value ?? defaultContainerMemoryGB)
    }

    private func parseHostSystemStats(_ output: String) -> HostSystemStats? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        var cpuLine: String?
        var memLine: String?
        var loadLine: String?
        var totalBytes: Int64?

        for line in lines {
            if line.hasPrefix("CPU|") {
                cpuLine = String(line.dropFirst(4))
            } else if line.hasPrefix("MEM|") {
                memLine = String(line.dropFirst(4))
            } else if line.hasPrefix("LOAD|") {
                loadLine = String(line.dropFirst(5))
            } else if line.hasPrefix("TOTAL|") {
                totalBytes = Int64(String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        guard
            let cpuText = cpuLine,
            let user = firstDouble(in: cpuText, pattern: #"([0-9]+(?:\.[0-9]+)?)% user"#),
            let sys = firstDouble(in: cpuText, pattern: #"([0-9]+(?:\.[0-9]+)?)% sys"#),
            let idle = firstDouble(in: cpuText, pattern: #"([0-9]+(?:\.[0-9]+)?)% idle"#)
        else {
            return nil
        }

        let loads = allDoubles(in: loadLine ?? "")
        let load1 = loads.count > 0 ? loads[0] : 0
        let load5 = loads.count > 1 ? loads[1] : 0
        let load15 = loads.count > 2 ? loads[2] : 0

        var memoryUsedGB: Double?
        var memoryUnusedGB: Double?
        if let memText = memLine {
            if let usedToken = firstString(in: memText, pattern: #"([0-9]+(?:\.[0-9]+)?[KMGTP]?B?) used"#) {
                memoryUsedGB = convertSizeToGB(usedToken)
            }
            if let freeToken = firstString(in: memText, pattern: #"([0-9]+(?:\.[0-9]+)?[KMGTP]?B?) (?:unused|free)"#) {
                memoryUnusedGB = convertSizeToGB(freeToken)
            }
        }

        var memoryTotalGB: Double?
        if let totalBytes {
            memoryTotalGB = Double(totalBytes) / 1_073_741_824.0
        } else if let used = memoryUsedGB, let free = memoryUnusedGB {
            memoryTotalGB = used + free
        }

        return HostSystemStats(
            cpuUserPercent: user,
            cpuSystemPercent: sys,
            cpuIdlePercent: idle,
            memoryUsedGB: memoryUsedGB,
            memoryUnusedGB: memoryUnusedGB,
            memoryTotalGB: memoryTotalGB,
            load1: load1,
            load5: load5,
            load15: load15
        )
    }

    private func firstDouble(in text: String, pattern: String) -> Double? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Double(String(text[range]))
    }

    private func firstString(in text: String, pattern: String) -> String? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range])
    }

    private func allDoubles(in text: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)"#) else {
            return []
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { match -> Double? in
            guard
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: text)
            else {
                return nil
            }
            return Double(String(text[range]))
        }
    }

    private func convertSizeToGB(_ token: String) -> Double? {
        let sanitized = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .uppercased()

        guard !sanitized.isEmpty else {
            return nil
        }

        let suffix = sanitized.last.map(String.init) ?? ""
        let numberString: String
        let multiplier: Double

        switch suffix {
        case "B":
            let dropped = String(sanitized.dropLast())
            if let unit = dropped.last, "KMGTP".contains(unit) {
                numberString = String(dropped.dropLast())
                switch unit {
                case "K": multiplier = 1.0 / (1024.0 * 1024.0)
                case "M": multiplier = 1.0 / 1024.0
                case "G": multiplier = 1.0
                case "T": multiplier = 1024.0
                case "P": multiplier = 1024.0 * 1024.0
                default: multiplier = 0
                }
            } else {
                numberString = dropped
                multiplier = 1.0 / 1_073_741_824.0
            }
        case "K":
            numberString = String(sanitized.dropLast())
            multiplier = 1.0 / (1024.0 * 1024.0)
        case "M":
            numberString = String(sanitized.dropLast())
            multiplier = 1.0 / 1024.0
        case "G":
            numberString = String(sanitized.dropLast())
            multiplier = 1.0
        case "T":
            numberString = String(sanitized.dropLast())
            multiplier = 1024.0
        case "P":
            numberString = String(sanitized.dropLast())
            multiplier = 1024.0 * 1024.0
        default:
            numberString = sanitized
            multiplier = 1.0 / 1_073_741_824.0
        }

        guard let value = Double(numberString), multiplier > 0 else {
            return nil
        }
        return value * multiplier
    }

    private var appSupportDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("ClawNode", isDirectory: true)
    }

    private var keepAwakePIDFileURL: URL {
        appSupportDirectoryURL.appendingPathComponent("keepawake.pid")
    }

    private func enableLidCloseSleepOverride24Hours() async throws {
        let resetCommand = "/usr/bin/nohup /bin/sh -c 'sleep \(keepAwakeDurationSeconds); /usr/bin/pmset -b disablesleep 0; /usr/bin/pmset -c disablesleep 0' >/tmp/clawmarket-disablesleep-reset.log 2>&1 &"
        let command = "/usr/bin/pmset -b disablesleep 1; /usr/bin/pmset -c disablesleep 1; \(resetCommand)"
        try await runPrivilegedShell(command, timeout: 60)
    }

    private func stopExistingKeepAwakeSessionIfNeeded() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: keepAwakePIDFileURL.path) else {
            return
        }

        let pidString = try String(contentsOf: keepAwakePIDFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let pid = Int32(pidString), pid > 0 {
            if kill(pid, SIGTERM) == 0 {
                log("Stopped existing keep-awake process with PID \(pid).")
            } else if errno != ESRCH {
                throw AgentManagerError.keepAwakeControlFailed(
                    "Unable to stop previous keep-awake process (PID \(pid))."
                )
            }
        }

        try? fileManager.removeItem(at: keepAwakePIDFileURL)
    }

    private func startKeepAwakeSession(seconds: Int) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: appSupportDirectoryURL, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: caffeinateExecutable)
        process.arguments = ["-dimsu", "-t", String(seconds)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AgentManagerError.keepAwakeControlFailed(
                "Unable to start keep-awake session using /usr/bin/caffeinate."
            )
        }

        let pidData = Data(String(process.processIdentifier).utf8)
        try pidData.write(to: keepAwakePIDFileURL, options: .atomic)
        log("Started keep-awake process with PID \(process.processIdentifier) for \(seconds)s.")
    }

    private var logDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("ClawNode", isDirectory: true)
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
