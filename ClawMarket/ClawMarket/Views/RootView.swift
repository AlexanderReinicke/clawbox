import SwiftUI
import AppKit

private struct StoredSubAgent: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var memoryMB: Int
    var createdAt: TimeInterval
}

struct RootView: View {
    @AppStorage("clawmarket.hasSeenWelcome") private var hasSeenWelcome = false
    @AppStorage("clawmarket.accessFolderPath") private var legacyAccessFolderPath = ""
    @AppStorage("clawmarket.accessFolderBySlotJSON") private var accessFolderBySlotJSON = "{}"
    @AppStorage("clawmarket.containerMemoryGB") private var legacyDefaultMemoryGB = 4
    @AppStorage("clawmarket.agentMemoryBySlotJSON") private var agentMemoryBySlotJSON = "{}"
    @AppStorage("clawmarket.agentDisplayNameBySlotJSON") private var agentDisplayNameBySlotJSON = "{}"
    @AppStorage("clawmarket.subAgentsBySlotJSON") private var subAgentsBySlotJSON = "{}"
    @AppStorage("clawmarket.selectedAgentSlot") private var selectedAgentSlot = 1

    @State private var manager = AgentManager()
    @State private var slotRuntimeStates: [Int: AgentSlotRuntimeState] = [:]
    @State private var agentRuntimeSnapshots: [Int: AgentRuntimeSnapshot] = [:]
    @State private var knownAgentSlots: [Int] = []

    @State private var runtimeInstallStatus: RuntimeInstallStatus = .idle
    @State private var setupProgressState: SetupProgressState?

    @State private var isCreateAgentPresented = false
    @State private var pendingCreateAgentSlot = 1
    @State private var createAgentMemoryGB = 4
    @State private var isCreatingAgent = false

    @State private var settingsAgentSlot: Int?
    @State private var settingsAgentMemoryGB = 4

    @State private var powerStatusMessage: String?
    @State private var powerStatusIsError = false
    @State private var powerStatusDismissTask: Task<Void, Never>?
    @State private var setupStatusDismissTask: Task<Void, Never>?

    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if !hasSeenWelcome {
                WelcomeView {
                    hasSeenWelcome = true
                    Task {
                        await refreshAgentState()
                    }
                }
            } else {
                appContent
            }
        }
        .task {
            migrateLegacyAccessFolderIfNeeded()
            migrateLegacyMemoryIfNeeded()
            clampMemorySettingsToHostBounds()
            await refreshAgentState()
            await manager.refreshHostSystemStats()
        }
        .task(id: pollingKey) {
            guard shouldPollAgentState else { return }
            while !Task.isCancelled && shouldPollAgentState {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled {
                    await refreshAgentState()
                }
            }
        }
        .task(id: hasSeenWelcome ? "stats-on" : "stats-off") {
            guard hasSeenWelcome else { return }
            while !Task.isCancelled {
                await manager.refreshHostSystemStats()
                try? await Task.sleep(for: .seconds(6))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await refreshAgentState()
                await manager.refreshHostSystemStats()
                clampMemorySettingsToHostBounds()
            }
        }
        .onChange(of: manager.hostSystemStats?.memoryTotalGB) { _, _ in
            clampMemorySettingsToHostBounds()
        }
        .onChange(of: selectedAgentSlot) { _, _ in
            manager.selectContainer(slot: selectedAgentSlot)
        }
        .onChange(of: setupProgressState) { _, newValue in
            setupStatusDismissTask?.cancel()
            setupStatusDismissTask = nil
            if case .failed = newValue {
                setupStatusDismissTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .seconds(10))
                    } catch {
                        return
                    }
                    if case .failed = setupProgressState {
                        setupProgressState = nil
                    }
                    setupStatusDismissTask = nil
                }
            }
        }
        .onDisappear {
            dismissPowerStatus()
            setupStatusDismissTask?.cancel()
            setupStatusDismissTask = nil
        }
        .sheet(isPresented: $isCreateAgentPresented) {
            CreateAgentSheet(
                agentSlot: pendingCreateAgentSlot,
                minimumMemoryGB: manager.minimumContainerMemoryGB,
                maximumMemoryGB: maximumSelectableContainerMemoryGB,
                memoryGB: $createAgentMemoryGB,
                isCreating: isCreatingAgent,
                onCreate: createAgentFromTemplate
            )
        }
        .sheet(isPresented: settingsSheetPresented) {
            if let settingsAgentSlot {
                AgentSettingsSheet(
                    agentSlot: settingsAgentSlot,
                    containerName: manager.containerName(forSlot: settingsAgentSlot),
                    runtimeState: slotRuntimeStates[settingsAgentSlot] ?? .missing,
                    hostMemoryTotalGB: manager.hostSystemStats?.memoryTotalGB,
                    minimumMemoryGB: manager.minimumContainerMemoryGB,
                    maximumMemoryGB: maximumSelectableContainerMemoryGB,
                    memoryGB: Binding(
                        get: { settingsAgentMemoryGB },
                        set: { newValue in
                            let bounded = boundedMemory(newValue)
                            settingsAgentMemoryGB = bounded
                            setConfiguredMemoryGB(bounded, for: settingsAgentSlot)
                        }
                    ),
                    accessFolderPath: normalizedAccessFolderPath(for: settingsAgentSlot),
                    onSelectAccessFolder: { selectAccessFolder(for: settingsAgentSlot) },
                    onClearAccessFolder: { setAccessFolderPath(nil, for: settingsAgentSlot) },
                    onRecreateAgent: { recreateAgent(slot: settingsAgentSlot) }
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                if let powerStatusMessage {
                    powerStatusToast(message: powerStatusMessage, isError: powerStatusIsError)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let setupProgressState {
                    setupStatusToast(state: setupProgressState)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
        .animation(.easeInOut(duration: 0.2), value: hasSeenWelcome)
        .animation(.easeInOut(duration: 0.2), value: setupProgressState != nil)
        .animation(.easeInOut(duration: 0.2), value: powerStatusMessage != nil)
    }

    @ViewBuilder
    private var appContent: some View {
        if manager.state == .noRuntime {
            RuntimeInstallView(
                status: runtimeInstallStatus,
                onInstallNow: installRuntime,
                onInstallManually: openManualInstallPage,
                onCheckAgain: checkRuntimeAgain
            )
        } else if manager.state == .checking && displayedAgentSlots.isEmpty {
            checkingView
        } else if case let .error(message) = manager.state, displayedAgentSlots.isEmpty {
            ErrorView(
                message: message,
                onRetry: {
                    runtimeInstallStatus = .idle
                    Task { await refreshAgentState() }
                },
                onReset: resetEnvironment
            )
        } else {
            homeContent
        }
    }

    private var homeContent: some View {
        HomeView(
            agents: agentListItems,
            selectedAgentSlot: selectedAgentSlot,
            isBusy: isAgentOperationBusy,
            manager: manager,
            agentRuntimeSnapshots: agentRuntimeSnapshots,
            subAgentsByAgentSlot: subAgentListItemsBySlot,
            hostStats: manager.hostSystemStats,
            nodeName: nodeDisplayName,
            runningAgentCount: runningAgentCount,
            onSelectAgent: selectAgent,
            onCreateAgent: beginCreateAgentFlow,
            onRenameAgent: renameAgent,
            onStart: startAgent,
            onStop: stopAgent,
            onDeleteAgentData: deleteAgentData,
            onDeleteInstance: deleteInstance,
            onOpenDashboard: openDashboard,
            onOpenSettings: openAgentSettings,
            onCreateSubAgent: createSubAgent,
            onRenameSubAgent: renameSubAgent,
            onDeleteSubAgent: deleteSubAgent,
            onRefresh: {
                Task {
                    await refreshAgentState()
                    await manager.refreshHostSystemStats()
                }
            },
            onLockAndKeepAwake: lockScreenAndKeepAwake24Hours,
            onDisableLidCloseOverride: disableLidCloseOverride
        )
    }

    private var appNavigationBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ClawNode")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Open Claw Agents")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.78))
            }

            Spacer()

            Button {
                beginCreateAgentFlow()
            } label: {
                Label("Create OpenClaw System", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(Color(red: 0.11, green: 0.20, blue: 0.35))
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isAgentOperationBusy || manager.state == .noRuntime)

            Button {
                Task {
                    await refreshAgentState()
                    await manager.refreshHostSystemStats()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(Color(red: 0.11, green: 0.20, blue: 0.35))
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)

            Menu {
                Section("Power") {
                    Button {
                        lockScreenAndKeepAwake24Hours()
                    } label: {
                        Label("Lock + Lid-Close Mode (24h)", systemImage: "lock.fill")
                    }

                    Button {
                        disableLidCloseOverride()
                    } label: {
                        Label("Disable Lid-Close Mode", systemImage: "lock.open.fill")
                    }
                }
            } label: {
                Label("Settings", systemImage: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(.white)
                    .background(Color.white.opacity(0.18), in: Capsule())
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.20, blue: 0.37), Color(red: 0.11, green: 0.28, blue: 0.48)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private var systemStatsBar: some View {
        HStack(spacing: 10) {
            if let stats = manager.hostSystemStats {
                statChip(
                    title: "CPU",
                    value: String(format: "%.0f%% busy", stats.cpuBusyPercent),
                    color: cpuColor(for: stats.cpuBusyPercent)
                )

                statChip(
                    title: "Memory",
                    value: memorySummaryText(for: stats),
                    color: memoryColor(for: stats.memoryUsedPercent)
                )

                statChip(
                    title: "Load (1m)",
                    value: String(format: "%.2f", stats.load1),
                    color: loadColor(for: stats.load1)
                )

                statChip(
                    title: "Agents",
                    value: "\(runningAgentCount)/\(displayedAgentSlots.count) running",
                    color: Color(red: 0.14, green: 0.35, blue: 0.72)
                )
            } else {
                Label("Collecting host system stats...", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.22, green: 0.28, blue: 0.36))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(red: 0.92, green: 0.95, blue: 0.99))
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func powerStatusToast(message: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(isError ? Color(red: 0.78, green: 0.23, blue: 0.19) : Color(red: 0.12, green: 0.54, blue: 0.27))

            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.16, green: 0.22, blue: 0.32))
                .lineLimit(4)

            Button {
                dismissPowerStatus()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(Color.black.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 420, alignment: .leading)
        .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    private func setupStatusToast(state: SetupProgressState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            switch state {
            case .working:
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 1)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 0.86, green: 0.27, blue: 0.20))
            }

            VStack(alignment: .leading, spacing: 4) {
                switch state {
                case let .working(message):
                    Text("Working")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.14, green: 0.20, blue: 0.31))
                    Text(message)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.23, green: 0.30, blue: 0.40))
                        .lineLimit(3)
                case let .failed(message):
                    Text("Operation failed")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.67, green: 0.19, blue: 0.15))
                    Text(message)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.23, green: 0.30, blue: 0.40))
                        .lineLimit(4)
                }
            }

            Button {
                setupProgressState = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(Color.black.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 420, alignment: .leading)
        .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    private func statChip(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(title): \(value)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.22, green: 0.28, blue: 0.36))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white, in: Capsule())
    }

    private func cpuColor(for busyPercent: Double) -> Color {
        switch busyPercent {
        case ..<45:
            return Color(red: 0.18, green: 0.64, blue: 0.35)
        case ..<75:
            return Color(red: 0.91, green: 0.62, blue: 0.17)
        default:
            return Color(red: 0.78, green: 0.23, blue: 0.19)
        }
    }

    private func memoryColor(for usedPercent: Double?) -> Color {
        guard let usedPercent else {
            return Color(red: 0.52, green: 0.56, blue: 0.62)
        }
        switch usedPercent {
        case ..<65:
            return Color(red: 0.18, green: 0.64, blue: 0.35)
        case ..<82:
            return Color(red: 0.91, green: 0.62, blue: 0.17)
        default:
            return Color(red: 0.78, green: 0.23, blue: 0.19)
        }
    }

    private func loadColor(for load: Double) -> Color {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let normalized = load / Double(cores)
        switch normalized {
        case ..<0.55:
            return Color(red: 0.18, green: 0.64, blue: 0.35)
        case ..<0.9:
            return Color(red: 0.91, green: 0.62, blue: 0.17)
        default:
            return Color(red: 0.78, green: 0.23, blue: 0.19)
        }
    }

    private func memorySummaryText(for stats: HostSystemStats) -> String {
        guard let used = stats.memoryUsedGB, let total = stats.memoryTotalGB else {
            return "n/a"
        }
        return String(format: "%.1f / %.1f GB", used, total)
    }

    private var checkingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Checking container runtime...")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.95, green: 0.97, blue: 0.99))
    }

    private var settingsSheetPresented: Binding<Bool> {
        Binding(
            get: { settingsAgentSlot != nil },
            set: { newValue in
                if !newValue {
                    settingsAgentSlot = nil
                }
            }
        )
    }

    private var shouldPollAgentState: Bool {
        hasSeenWelcome && manager.state != .noRuntime
    }

    private var pollingKey: String {
        shouldPollAgentState ? "poll-on" : "poll-off"
    }

    private var displayedAgentSlots: [Int] {
        let combined = Set(knownAgentSlots)
            .union(accessFolderMapping.keys)
            .union(agentMemoryMapping.keys)
            .union(agentDisplayNameMapping.keys)
            .union(subAgentMapping.keys)
        return combined.sorted()
    }

    private var runningAgentCount: Int {
        displayedAgentSlots.filter { slotRuntimeStates[$0] == .running }.count
    }

    private var nodeDisplayName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private var agentListItems: [AgentListItem] {
        displayedAgentSlots.map { slot in
            AgentListItem(
                slot: slot,
                displayName: displayName(for: slot),
                containerName: manager.containerName(forSlot: slot),
                runtime: slotRuntimeStates[slot] ?? .missing,
                configuredMemoryGB: configuredMemoryGB(for: slot),
                accessFolderDisplayPath: normalizedAccessFolderPath(for: slot)
            )
        }
    }

    private var subAgentListItemsBySlot: [Int: [SubAgentListItem]] {
        subAgentMapping.mapValues { stored in
            stored
                .sorted(by: { $0.createdAt < $1.createdAt })
                .map { item in
                    SubAgentListItem(
                        id: item.id,
                        displayName: item.name,
                        memoryMB: item.memoryMB,
                        createdAt: item.createdAt
                    )
                }
        }
    }

    private var isAgentOperationBusy: Bool {
        isCreatingAgent || manager.state == .starting
    }

    private var maximumSelectableContainerMemoryGB: Int {
        guard let total = manager.hostSystemStats?.memoryTotalGB else {
            return 64
        }
        return max(manager.minimumContainerMemoryGB, Int(floor(total)))
    }

    private func boundedMemory(_ value: Int) -> Int {
        min(max(value, manager.minimumContainerMemoryGB), maximumSelectableContainerMemoryGB)
    }

    private func defaultConfiguredMemoryGB() -> Int {
        boundedMemory(max(manager.minimumContainerMemoryGB, legacyDefaultMemoryGB))
    }

    private var nextAvailableAgentSlot: Int {
        (displayedAgentSlots.max() ?? 0) + 1
    }

    private func beginCreateAgentFlow() {
        pendingCreateAgentSlot = nextAvailableAgentSlot
        createAgentMemoryGB = defaultConfiguredMemoryGB()
        isCreateAgentPresented = true
    }

    private func createAgentFromTemplate() {
        guard !isCreatingAgent else {
            return
        }

        let slot = pendingCreateAgentSlot
        let configuredMemory = boundedMemory(createAgentMemoryGB)
        createAgentMemoryGB = configuredMemory
        setConfiguredMemoryGB(configuredMemory, for: slot)
        selectedAgentSlot = slot
        manager.selectContainer(slot: slot)

        isCreatingAgent = true
        setupProgressState = .working("Creating Agent \(slot)...")

        Task {
            do {
                try await ensureDefaultImageExists()

                setupProgressState = .working("Provisioning container for Agent \(slot)...")
                try await manager.createContainer(
                    accessFolderHostPath: normalizedAccessFolderPath(for: slot),
                    memoryGB: configuredMemory
                )

                setupProgressState = .working("Starting Agent \(slot)...")
                try await manager.startContainer(
                    accessFolderHostPath: normalizedAccessFolderPath(for: slot),
                    memoryGB: configuredMemory
                )

                await refreshAgentState()
                setupProgressState = nil
                isCreatingAgent = false
                isCreateAgentPresented = false
            } catch {
                setupProgressState = .failed(error.localizedDescription)
                isCreatingAgent = false
            }
        }
    }

    private func openAgentSettings(_ slot: Int) {
        selectAgent(slot)
        settingsAgentSlot = slot
        settingsAgentMemoryGB = configuredMemoryGB(for: slot)
    }

    private func selectAgent(_ slot: Int) {
        selectedAgentSlot = max(1, slot)
        manager.selectContainer(slot: selectedAgentSlot)
    }

    private func renameAgent(slot: Int, name: String) {
        let normalizedSlot = max(1, slot)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        var mapping = agentDisplayNameMapping
        if trimmed.isEmpty || trimmed == "Agent \(normalizedSlot)" {
            mapping.removeValue(forKey: normalizedSlot)
        } else {
            mapping[normalizedSlot] = trimmed
        }
        writeAgentDisplayNameMapping(mapping)
    }

    private func createSubAgent(parentSlot: Int) {
        let normalizedSlot = max(1, parentSlot)
        var mapping = subAgentMapping
        var subAgents = mapping[normalizedSlot] ?? []
        let newIndex = subAgents.count + 1
        let subAgent = StoredSubAgent(
            id: "sub-\(UUID().uuidString.prefix(8).lowercased())",
            name: "Sub-agent \(newIndex)",
            memoryMB: 1024,
            createdAt: Date().timeIntervalSinceReferenceDate
        )
        subAgents.append(subAgent)
        mapping[normalizedSlot] = subAgents
        writeSubAgentMapping(mapping)
    }

    private func renameSubAgent(parentSlot: Int, subAgentID: String, name: String) {
        let normalizedSlot = max(1, parentSlot)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        var mapping = subAgentMapping
        guard var subAgents = mapping[normalizedSlot] else {
            return
        }
        guard let index = subAgents.firstIndex(where: { $0.id == subAgentID }) else {
            return
        }
        subAgents[index].name = trimmed
        mapping[normalizedSlot] = subAgents
        writeSubAgentMapping(mapping)
    }

    private func deleteSubAgent(parentSlot: Int, subAgentID: String) {
        let normalizedSlot = max(1, parentSlot)
        var mapping = subAgentMapping
        guard var subAgents = mapping[normalizedSlot] else {
            return
        }
        subAgents.removeAll(where: { $0.id == subAgentID })
        if subAgents.isEmpty {
            mapping.removeValue(forKey: normalizedSlot)
        } else {
            mapping[normalizedSlot] = subAgents
        }
        writeSubAgentMapping(mapping)
    }

    private func startAgent(_ slot: Int) {
        Task {
            do {
                selectAgent(slot)
                try await ensureDefaultImageExists()
                try await manager.startContainer(
                    accessFolderHostPath: normalizedAccessFolderPath(for: slot),
                    memoryGB: configuredMemoryGB(for: slot)
                )
                await refreshAgentState()
            } catch {
                setupProgressState = .failed("Start failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopAgent(_ slot: Int) {
        Task {
            do {
                selectAgent(slot)
                try await manager.stopContainer()
                await refreshAgentState()
            } catch {
                setupProgressState = .failed("Stop failed: \(error.localizedDescription)")
            }
        }
    }

    private func recreateAgent(slot: Int) {
        setupProgressState = .working("Recreating Agent \(slot)...")
        Task {
            do {
                selectAgent(slot)
                try await ensureDefaultImageExists()
                try await manager.recreateContainer(
                    accessFolderHostPath: normalizedAccessFolderPath(for: slot),
                    memoryGB: configuredMemoryGB(for: slot)
                )
                await refreshAgentState()
                setupProgressState = nil
            } catch {
                setupProgressState = .failed("Recreate failed: \(error.localizedDescription)")
            }
        }
    }

    private func deleteAgentData(_ slot: Int) {
        setupProgressState = .working("Deleting data for Agent \(slot)...")
        Task {
            do {
                selectAgent(slot)
                try await manager.deletePrimaryAgentData()
                await refreshAgentState()
                setupProgressState = nil
            } catch {
                setupProgressState = .failed("Delete data failed: \(error.localizedDescription)")
            }
        }
    }

    private func deleteInstance(_ slot: Int) {
        setupProgressState = .working("Deleting Agent \(slot)...")
        Task {
            do {
                selectAgent(slot)
                try await manager.deleteContainer()
                removeAgentConfiguration(slot: slot)
                settingsAgentSlot = settingsAgentSlot == slot ? nil : settingsAgentSlot
                await refreshAgentState()
                setupProgressState = nil
            } catch {
                setupProgressState = .failed("Delete instance failed: \(error.localizedDescription)")
            }
        }
    }

    private func openDashboard(_ slot: Int) {
        Task {
            do {
                selectAgent(slot)
                let url = try await manager.dashboardURL()
                await MainActor.run {
                    openURL(url)
                }
            } catch {
                await MainActor.run {
                    setupProgressState = .failed("Dashboard failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func ensureDefaultImageExists() async throws {
        if try await !manager.imageExists() {
            setupProgressState = .working("Building default template image...")
            try await manager.buildImage()
        }
    }

    private func refreshAgentState() async {
        manager.selectContainer(slot: selectedAgentSlot)
        await manager.sync()

        let discoveredSlots = await manager.discoveredManagedAgentSlots()
        let configuredSlots = Set(accessFolderMapping.keys).union(agentMemoryMapping.keys)
        let combinedSlots = discoveredSlots.union(configuredSlots)
        knownAgentSlots = combinedSlots.sorted()

        if knownAgentSlots.isEmpty {
            slotRuntimeStates = [:]
            agentRuntimeSnapshots = [:]
            selectedAgentSlot = 1
            return
        }

        if !knownAgentSlots.contains(selectedAgentSlot), let first = knownAgentSlots.first {
            selectedAgentSlot = first
        }

        slotRuntimeStates = await manager.managedContainerStates(slots: knownAgentSlots)
        agentRuntimeSnapshots = await manager.managedAgentRuntimeSnapshots(slots: knownAgentSlots)
    }

    private func installRuntime() {
        Task {
            runtimeInstallStatus = .working("Preparing runtime installation...")
            do {
                try await manager.installRuntime { status in
                    runtimeInstallStatus = .working(status)
                }
                runtimeInstallStatus = .working("Verifying runtime...")
                await refreshAgentState()
                runtimeInstallStatus = .idle
            } catch {
                runtimeInstallStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func checkRuntimeAgain() {
        Task {
            runtimeInstallStatus = .working("Checking runtime availability...")
            await refreshAgentState()
            if manager.state == .noRuntime {
                runtimeInstallStatus = .failed("Runtime still not detected at /usr/local/bin/container.")
            } else {
                runtimeInstallStatus = .idle
            }
        }
    }

    private func openManualInstallPage() {
        openURL(URL(string: "https://github.com/apple/container/releases")!)
    }

    private func resetEnvironment() {
        Task {
            do {
                try await manager.factoryReset()
                runtimeInstallStatus = .idle
                setupProgressState = nil
                isCreatingAgent = false
                await refreshAgentState()
            } catch {
                setupProgressState = .failed("Reset failed: \(error.localizedDescription)")
            }
        }
    }

    private func lockScreenAndKeepAwake24Hours() {
        Task {
            do {
                try await manager.lockScreenAndKeepAwake24Hours()
                let until = Date().addingTimeInterval(TimeInterval(manager.keepAwakeDurationSeconds))
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                showPowerStatus(
                    "Screen locked. Lid-close mode enabled until \(formatter.string(from: until)). This is an aggressive power override.",
                    isError: false
                )
            } catch {
                showPowerStatus("Power action failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func disableLidCloseOverride() {
        Task {
            do {
                try await manager.disableLidCloseSleepOverride()
                showPowerStatus("Lid-close mode disabled. Normal sleep behavior restored.", isError: false)
            } catch {
                showPowerStatus("Disable failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func showPowerStatus(_ message: String, isError: Bool) {
        dismissPowerStatus()
        powerStatusMessage = message
        powerStatusIsError = isError

        powerStatusDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(isError ? 10 : 6))
            } catch {
                return
            }
            powerStatusMessage = nil
            powerStatusIsError = false
            powerStatusDismissTask = nil
        }
    }

    private func dismissPowerStatus() {
        powerStatusDismissTask?.cancel()
        powerStatusDismissTask = nil
        powerStatusMessage = nil
        powerStatusIsError = false
    }

    private func normalizedAccessFolderPath(for slot: Int) -> String? {
        let mapping = accessFolderMapping
        let value = mapping[slot] ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func selectAccessFolder(for slot: Int) {
        let panel = NSOpenPanel()
        panel.title = "Select Access Folder (Agent \(slot))"
        panel.prompt = "Select Folder"
        panel.message = "This folder will be mounted into Agent \(slot) at /mnt/access after recreating that agent."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let selectedURL = panel.url {
            setAccessFolderPath(selectedURL.path, for: slot)
        }
    }

    private func setAccessFolderPath(_ path: String?, for slot: Int) {
        var mapping = accessFolderMapping
        let normalizedSlot = max(1, slot)
        let trimmed = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            mapping.removeValue(forKey: normalizedSlot)
        } else {
            mapping[normalizedSlot] = trimmed
        }
        writeAccessFolderMapping(mapping)
    }

    private func migrateLegacyAccessFolderIfNeeded() {
        let legacy = legacyAccessFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacy.isEmpty else { return }
        guard accessFolderMapping.isEmpty else {
            legacyAccessFolderPath = ""
            return
        }

        var mapping: [Int: String] = [:]
        mapping[1] = legacy
        writeAccessFolderMapping(mapping)
        legacyAccessFolderPath = ""
    }

    private func migrateLegacyMemoryIfNeeded() {
        let boundedLegacy = boundedMemory(legacyDefaultMemoryGB)
        if legacyDefaultMemoryGB != boundedLegacy {
            legacyDefaultMemoryGB = boundedLegacy
        }
    }

    private func removeAgentConfiguration(slot: Int) {
        var memory = agentMemoryMapping
        memory.removeValue(forKey: slot)
        writeAgentMemoryMapping(memory)

        var access = accessFolderMapping
        access.removeValue(forKey: slot)
        writeAccessFolderMapping(access)

        var names = agentDisplayNameMapping
        names.removeValue(forKey: slot)
        writeAgentDisplayNameMapping(names)

        var subAgents = subAgentMapping
        subAgents.removeValue(forKey: slot)
        writeSubAgentMapping(subAgents)
    }

    private func clampMemorySettingsToHostBounds() {
        createAgentMemoryGB = boundedMemory(createAgentMemoryGB)
        settingsAgentMemoryGB = boundedMemory(settingsAgentMemoryGB)

        let boundedMapping = agentMemoryMapping.mapValues { boundedMemory($0) }
        if boundedMapping != agentMemoryMapping {
            writeAgentMemoryMapping(boundedMapping)
        }
    }

    private func configuredMemoryGB(for slot: Int) -> Int {
        boundedMemory(agentMemoryMapping[slot] ?? defaultConfiguredMemoryGB())
    }

    private func setConfiguredMemoryGB(_ memoryGB: Int, for slot: Int) {
        var mapping = agentMemoryMapping
        mapping[max(1, slot)] = boundedMemory(memoryGB)
        writeAgentMemoryMapping(mapping)
    }

    private var accessFolderMapping: [Int: String] {
        let data = Data(accessFolderBySlotJSON.utf8)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            return [:]
        }

        var mapping: [Int: String] = [:]
        for (key, value) in object {
            guard let slot = Int(key), slot > 0 else { continue }
            mapping[slot] = value
        }
        return mapping
    }

    private func writeAccessFolderMapping(_ mapping: [Int: String]) {
        let stringKeyed = Dictionary(uniqueKeysWithValues: mapping.map { (String($0.key), $0.value) })
        guard
            let data = try? JSONSerialization.data(withJSONObject: stringKeyed, options: [.sortedKeys]),
            let encoded = String(data: data, encoding: .utf8)
        else {
            return
        }
        accessFolderBySlotJSON = encoded
    }

    private var agentMemoryMapping: [Int: Int] {
        let data = Data(agentMemoryBySlotJSON.utf8)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }

        var mapping: [Int: Int] = [:]
        for (key, value) in object {
            guard let slot = Int(key), slot > 0 else { continue }
            if let intValue = value as? Int {
                mapping[slot] = intValue
            } else if let numberValue = value as? NSNumber {
                mapping[slot] = numberValue.intValue
            } else if let stringValue = value as? String, let intValue = Int(stringValue) {
                mapping[slot] = intValue
            }
        }
        return mapping
    }

    private func writeAgentMemoryMapping(_ mapping: [Int: Int]) {
        let stringKeyed = Dictionary(uniqueKeysWithValues: mapping.map { (String($0.key), $0.value) })
        guard
            let data = try? JSONSerialization.data(withJSONObject: stringKeyed, options: [.sortedKeys]),
            let encoded = String(data: data, encoding: .utf8)
        else {
            return
        }
        agentMemoryBySlotJSON = encoded
    }

    private func displayName(for slot: Int) -> String {
        let trimmed = (agentDisplayNameMapping[slot] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Agent \(slot)" : trimmed
    }

    private var agentDisplayNameMapping: [Int: String] {
        let data = Data(agentDisplayNameBySlotJSON.utf8)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            return [:]
        }

        var mapping: [Int: String] = [:]
        for (key, value) in object {
            guard let slot = Int(key), slot > 0 else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            mapping[slot] = trimmed
        }
        return mapping
    }

    private func writeAgentDisplayNameMapping(_ mapping: [Int: String]) {
        let cleaned = mapping.reduce(into: [Int: String]()) { partialResult, element in
            let trimmed = element.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                partialResult[element.key] = trimmed
            }
        }
        let stringKeyed = Dictionary(uniqueKeysWithValues: cleaned.map { (String($0.key), $0.value) })
        guard
            let data = try? JSONSerialization.data(withJSONObject: stringKeyed, options: [.sortedKeys]),
            let encoded = String(data: data, encoding: .utf8)
        else {
            return
        }
        agentDisplayNameBySlotJSON = encoded
    }

    private var subAgentMapping: [Int: [StoredSubAgent]] {
        guard let data = subAgentsBySlotJSON.data(using: .utf8) else {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode([String: [StoredSubAgent]].self, from: data) else {
            return [:]
        }

        var mapping: [Int: [StoredSubAgent]] = [:]
        for (key, value) in decoded {
            guard let slot = Int(key), slot > 0 else { continue }
            mapping[slot] = value
        }
        return mapping
    }

    private func writeSubAgentMapping(_ mapping: [Int: [StoredSubAgent]]) {
        let normalized = mapping.reduce(into: [Int: [StoredSubAgent]]()) { partialResult, entry in
            let cleaned = entry.value.filter { !$0.id.isEmpty }
            if !cleaned.isEmpty {
                partialResult[entry.key] = cleaned
            }
        }

        let keyed = Dictionary(uniqueKeysWithValues: normalized.map { (String($0.key), $0.value) })
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(keyed), let encoded = String(data: data, encoding: .utf8) else {
            return
        }
        subAgentsBySlotJSON = encoded
    }
}

#Preview {
    RootView()
}
