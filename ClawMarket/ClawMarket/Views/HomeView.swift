import SwiftUI

struct AgentListItem: Identifiable, Hashable {
    let slot: Int
    let displayName: String
    let containerName: String
    let runtime: AgentSlotRuntimeState
    let configuredMemoryGB: Int
    let accessFolderDisplayPath: String?

    var id: Int { slot }
}

struct SubAgentListItem: Identifiable, Hashable {
    let id: String
    let displayName: String
    let memoryMB: Int
    let createdAt: TimeInterval
}

private enum PendingDangerAction: Equatable {
    case stop(slot: Int)
    case deleteData(slot: Int)
    case deleteInstance(slot: Int)
}

private enum ProjectTab: String, CaseIterable {
    case home = "Home"
    case dashboard = "Dashboard"
    case settings = "Settings"
    case logs = "Logs"

    var icon: String {
        switch self {
        case .home: return "house"
        case .dashboard: return "chart.xyaxis.line"
        case .settings: return "gearshape"
        case .logs: return "doc.text"
        }
    }
}

private enum AgentTab: String, CaseIterable {
    case home = "Home"
    case shell = "Shell"
    case files = "Files"
    case dashboard = "Dashboard"
    case config = "Config"
    case logs = "Logs"

    var icon: String {
        switch self {
        case .home: return "house"
        case .shell: return "terminal"
        case .files: return "folder"
        case .dashboard: return "chart.xyaxis.line"
        case .config: return "slider.horizontal.3"
        case .logs: return "doc.text"
        }
    }
}

private enum ShellSelection: Equatable {
    case project
    case agent(Int)
    case subAgent(parentSlot: Int, subAgentID: String)
}

struct HomeView: View {
    let agents: [AgentListItem]
    let selectedAgentSlot: Int
    let isBusy: Bool
    let manager: AgentManager
    let agentRuntimeSnapshots: [Int: AgentRuntimeSnapshot]
    let subAgentsByAgentSlot: [Int: [SubAgentListItem]]
    let hostStats: HostSystemStats?
    let nodeName: String
    let runningAgentCount: Int

    let onSelectAgent: (Int) -> Void
    let onCreateAgent: () -> Void
    let onRenameAgent: (Int, String) -> Void
    let onStart: (Int) -> Void
    let onStop: (Int) -> Void
    let onDeleteAgentData: (Int) -> Void
    let onDeleteInstance: (Int) -> Void
    let onOpenDashboard: (Int) -> Void
    let onOpenSettings: (Int) -> Void
    let onCreateSubAgent: (Int) -> Void
    let onRenameSubAgent: (Int, String, String) -> Void
    let onDeleteSubAgent: (Int, String) -> Void
    let onRefresh: () -> Void
    let onLockAndKeepAwake: () -> Void
    let onDisableLidCloseOverride: () -> Void

    @State private var shellSelection: ShellSelection = .project
    @State private var selectedProjectTab: ProjectTab = .home
    @State private var selectedAgentTab: AgentTab = .home
    @State private var pendingDangerAction: PendingDangerAction?

    @State private var editingNameSlot: Int?
    @State private var editingNameDraft = ""
    @State private var editingSubAgentParentSlot: Int?
    @State private var editingSubAgentID: String?
    @State private var editingSubAgentDraft = ""
    @State private var projectExpanded = true

    @State private var filesCurrentPath: String
    @State private var filesSelectedPath: String?

    private struct ProjectActivityRow: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
        let tint: Color
    }

    init(
        agents: [AgentListItem],
        selectedAgentSlot: Int,
        isBusy: Bool,
        manager: AgentManager,
        agentRuntimeSnapshots: [Int: AgentRuntimeSnapshot],
        subAgentsByAgentSlot: [Int: [SubAgentListItem]],
        hostStats: HostSystemStats?,
        nodeName: String,
        runningAgentCount: Int,
        onSelectAgent: @escaping (Int) -> Void,
        onCreateAgent: @escaping () -> Void,
        onRenameAgent: @escaping (Int, String) -> Void,
        onStart: @escaping (Int) -> Void,
        onStop: @escaping (Int) -> Void,
        onDeleteAgentData: @escaping (Int) -> Void,
        onDeleteInstance: @escaping (Int) -> Void,
        onOpenDashboard: @escaping (Int) -> Void,
        onOpenSettings: @escaping (Int) -> Void,
        onCreateSubAgent: @escaping (Int) -> Void,
        onRenameSubAgent: @escaping (Int, String, String) -> Void,
        onDeleteSubAgent: @escaping (Int, String) -> Void,
        onRefresh: @escaping () -> Void,
        onLockAndKeepAwake: @escaping () -> Void,
        onDisableLidCloseOverride: @escaping () -> Void
    ) {
        self.agents = agents
        self.selectedAgentSlot = selectedAgentSlot
        self.isBusy = isBusy
        self.manager = manager
        self.agentRuntimeSnapshots = agentRuntimeSnapshots
        self.subAgentsByAgentSlot = subAgentsByAgentSlot
        self.hostStats = hostStats
        self.nodeName = nodeName
        self.runningAgentCount = runningAgentCount
        self.onSelectAgent = onSelectAgent
        self.onCreateAgent = onCreateAgent
        self.onRenameAgent = onRenameAgent
        self.onStart = onStart
        self.onStop = onStop
        self.onDeleteAgentData = onDeleteAgentData
        self.onDeleteInstance = onDeleteInstance
        self.onOpenDashboard = onOpenDashboard
        self.onOpenSettings = onOpenSettings
        self.onCreateSubAgent = onCreateSubAgent
        self.onRenameSubAgent = onRenameSubAgent
        self.onDeleteSubAgent = onDeleteSubAgent
        self.onRefresh = onRefresh
        self.onLockAndKeepAwake = onLockAndKeepAwake
        self.onDisableLidCloseOverride = onDisableLidCloseOverride
        _filesCurrentPath = State(initialValue: manager.defaultBrowsePath)
    }

    var body: some View {
        ZStack {
            Color.shellDeepest.ignoresSafeArea()

            if agents.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    titleBar
                    divider
                    breadcrumbBar
                    divider

                    HSplitView {
                        sidebar
                            .frame(minWidth: 240, idealWidth: 260, maxWidth: 300)

                        VStack(spacing: 0) {
                            tabBar
                            divider
                            contentArea
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.shellSurface)
                        }
                    }

                    divider
                    statusBar
                }
            }
        }
        .alert(dangerTitle, isPresented: dangerAlertPresented) {
            switch pendingDangerAction {
            case let .stop(slot):
                Button("Stop", role: .destructive) {
                    onStop(slot)
                    pendingDangerAction = nil
                }
            case let .deleteData(slot):
                Button("Delete Data", role: .destructive) {
                    onDeleteAgentData(slot)
                    pendingDangerAction = nil
                }
            case let .deleteInstance(slot):
                Button("Delete", role: .destructive) {
                    onDeleteInstance(slot)
                    pendingDangerAction = nil
                }
            case .none:
                EmptyView()
            }
            Button("Cancel", role: .cancel) {
                pendingDangerAction = nil
            }
        } message: {
            Text(dangerMessage)
        }
        .onAppear {
            if agents.contains(where: { $0.slot == selectedAgentSlot }) {
                shellSelection = .agent(selectedAgentSlot)
            } else {
                shellSelection = .project
            }
        }
        .onChange(of: selectedAgentSlot) { _, newSlot in
            if shellSelection.isAgentContext {
                if case let .subAgent(_, subAgentID) = shellSelection,
                   subAgents(for: newSlot).contains(where: { $0.id == subAgentID }) {
                    shellSelection = .subAgent(parentSlot: newSlot, subAgentID: subAgentID)
                } else {
                    shellSelection = .agent(newSlot)
                }
            }
        }
        .onChange(of: agents) { _, newAgents in
            switch shellSelection {
            case let .agent(slot):
                if !newAgents.contains(where: { $0.slot == slot }) {
                    shellSelection = newAgents.isEmpty ? .project : .agent(newAgents[0].slot)
                }
            case let .subAgent(parentSlot, subAgentID):
                if !newAgents.contains(where: { $0.slot == parentSlot }) {
                    shellSelection = newAgents.isEmpty ? .project : .agent(newAgents[0].slot)
                } else if !subAgents(for: parentSlot).contains(where: { $0.id == subAgentID }) {
                    shellSelection = .agent(parentSlot)
                }
            case .project:
                break
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.shellBorder)
            .frame(height: 1)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.shellAccent)

            Text("No OpenClaw agents yet")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.shellTextPrimary)

            Text("Create your first OpenClaw system to start.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.shellTextSecondary)

            Button {
                onCreateAgent()
            } label: {
                Label("Create OpenClaw System", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)
        }
        .padding(30)
        .background(Color.shellSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.shellBorder, lineWidth: 1)
        )
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            Label {
                Text("ClawNode")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.shellTextPrimary)
            } icon: {
                Text("◆")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.shellAccent)
            }

            Text(nodeName)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.shellTextSecondary)

            Spacer()

            statusPill(color: Color.shellRunning, text: "\(runningAgentCount) running")
            statusPill(color: Color.shellStopped, text: "\(max(0, agents.count - runningAgentCount)) stopped")

            Button {
                onCreateAgent()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)

            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh")

            Menu {
                Button {
                    onLockAndKeepAwake()
                } label: {
                    Label("Lock + Lid-Close Mode (24h)", systemImage: "lock.fill")
                }

                Button {
                    onDisableLidCloseOverride()
                } label: {
                    Label("Disable Lid-Close Mode", systemImage: "lock.open.fill")
                }
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.shellDeepest)
    }

    private func statusPill(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.shellTextSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.shellSurface, in: Capsule())
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(breadcrumbSegments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Text("▸")
                            .foregroundStyle(Color.shellTextMuted)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                    }

                    if segment.isActive {
                        breadcrumbLabel(icon: segment.icon, label: segment.label, active: true)
                    } else {
                        Button {
                            segment.action()
                        } label: {
                            breadcrumbLabel(icon: segment.icon, label: segment.label, active: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(Color.shellSurface)
    }

    private func breadcrumbLabel(icon: String?, label: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
        .foregroundStyle(active ? Color.shellTextPrimary : Color.shellAccent)
    }

    private var breadcrumbSegments: [(icon: String?, label: String, isActive: Bool, action: () -> Void)] {
        if case .project = shellSelection {
            var segments: [(String?, String, Bool, () -> Void)] = [
                ("shippingbox", "Project X", false, {
                    shellSelection = .project
                    selectedProjectTab = .home
                })
            ]

            let tabLabel = selectedProjectTab.rawValue
            if selectedProjectTab == .home {
                segments[0].2 = true
            } else {
                segments.append((selectedProjectTab.icon, tabLabel, true, {}))
            }
            return segments
        }

        guard let context = selectedContext else {
            return [("shippingbox", "Project X", true, {})]
        }

        var segments: [(String?, String, Bool, () -> Void)] = [
            ("shippingbox", "Project X", false, {
                shellSelection = .project
                selectedProjectTab = .home
            }),
            ("person.crop.square", context.agent.displayName, false, {
                shellSelection = .agent(context.agent.slot)
                selectedAgentTab = .home
            })
        ]

        if let subAgent = context.subAgent {
            segments.append(("arrow.turn.down.right", subAgent.displayName, false, {
                shellSelection = .subAgent(parentSlot: context.agent.slot, subAgentID: subAgent.id)
                selectedAgentTab = .home
            }))
        }

        if selectedAgentTab == .home {
            if context.subAgent != nil {
                segments[2].2 = true
            } else {
                segments[1].2 = true
            }
            return segments
        }

        let currentTab = selectedAgentTab
        segments.append((currentTab.icon, currentTab.rawValue, false, {
            selectedAgentTab = currentTab
            if currentTab == .files {
                filesSelectedPath = nil
            }
        }))

        if selectedAgentTab == .files {
            let fileContext = filesSelectedPath ?? filesCurrentPath
            segments.append(("doc.text", fileContext, true, {}))
        } else {
            segments[segments.count - 1].2 = true
        }

        return segments
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PROJECTS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.shellTextSecondary)
                Spacer()
                Menu {
                    Button("New Agent", action: onCreateAgent)
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.shellTextSecondary)
                }
                .menuStyle(.borderlessButton)
                .disabled(isBusy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            divider

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    projectRow

                    if projectExpanded {
                        VStack(spacing: 6) {
                            ForEach(agents) { agent in
                                agentSidebarRow(agent)
                            }
                        }
                        .padding(.leading, 10)
                    }
                }
                .padding(10)
            }
        }
        .background(Color.shellDeepest)
    }

    private var projectRow: some View {
        Button {
            shellSelection = .project
            selectedProjectTab = .home
        } label: {
            HStack(spacing: 8) {
                Image(systemName: projectExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.shellTextMuted)
                    .onTapGesture {
                        projectExpanded.toggle()
                    }

                Image(systemName: "shippingbox")
                    .foregroundStyle(Color.shellAccent)
                Text("Project X")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.shellTextPrimary)
                Spacer()
                Text("\(agents.count) / \(totalSubAgentCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.shellTextSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(shellSelection == .project ? Color.shellAccentMuted : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func agentSidebarRow(_ agent: AgentListItem) -> some View {
        let isSelected: Bool
        switch shellSelection {
        case let .agent(slot):
            isSelected = slot == agent.slot
        case let .subAgent(parentSlot, _):
            isSelected = parentSlot == agent.slot
        case .project:
            isSelected = false
        }
        let subAgents = subAgents(for: agent.slot)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(statusColor(agent.runtime))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 2) {
                    if editingNameSlot == agent.slot {
                        TextField("Agent name", text: $editingNameDraft)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                commitInlineRename(slot: agent.slot)
                            }
                    } else {
                        Text(agent.displayName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.shellTextPrimary)
                            .lineLimit(1)
                    }

                    Text(agent.containerName)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.shellTextMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text("\(agent.configuredMemoryGB) GB")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.shellTextSecondary)
            }

            HStack(spacing: 8) {
                Button {
                    onCreateSubAgent(agent.slot)
                } label: {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.shellTextSecondary)
                }
                .buttonStyle(.plain)

                Button {
                    if editingNameSlot == agent.slot {
                        commitInlineRename(slot: agent.slot)
                    } else {
                        beginInlineRename(agent)
                    }
                } label: {
                    Image(systemName: editingNameSlot == agent.slot ? "checkmark.circle.fill" : "pencil")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.shellTextSecondary)
                }
                .buttonStyle(.plain)

                Menu {
                    if agent.runtime == .running {
                        Button("Stop", role: .destructive) {
                            pendingDangerAction = .stop(slot: agent.slot)
                        }
                    } else {
                        Button("Start") {
                            onStart(agent.slot)
                        }
                    }

                    Button("Delete Data", role: .destructive) {
                        pendingDangerAction = .deleteData(slot: agent.slot)
                    }
                    .disabled(agent.runtime != .running)

                    Divider()

                    Button("Delete Agent", role: .destructive) {
                        pendingDangerAction = .deleteInstance(slot: agent.slot)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.shellTextSecondary)
                }
                .menuStyle(.borderlessButton)

                Spacer()
            }

            if !subAgents.isEmpty {
                VStack(spacing: 4) {
                    ForEach(subAgents) { subAgent in
                        subAgentSidebarRow(parentAgent: agent, subAgent: subAgent)
                    }
                }
                .padding(.leading, 14)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.shellAccentMuted : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? Color.shellAccent : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture {
            shellSelection = .agent(agent.slot)
            onSelectAgent(agent.slot)
        }
    }

    private func subAgentSidebarRow(parentAgent: AgentListItem, subAgent: SubAgentListItem) -> some View {
        let isSelected: Bool
        switch shellSelection {
        case let .subAgent(parentSlot, subAgentID):
            isSelected = parentSlot == parentAgent.slot && subAgentID == subAgent.id
        default:
            isSelected = false
        }

        let isEditing = editingSubAgentParentSlot == parentAgent.slot && editingSubAgentID == subAgent.id

        return HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.shellTextMuted)

            if isEditing {
                TextField("Sub-agent name", text: $editingSubAgentDraft)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        commitSubAgentRename(parentSlot: parentAgent.slot, subAgentID: subAgent.id)
                    }
            } else {
                Text(subAgent.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.shellTextPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text("\(subAgent.memoryMB) MB")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.shellTextMuted)

            Menu {
                Button(isEditing ? "Save Rename" : "Rename") {
                    if isEditing {
                        commitSubAgentRename(parentSlot: parentAgent.slot, subAgentID: subAgent.id)
                    } else {
                        beginSubAgentRename(parentSlot: parentAgent.slot, subAgent: subAgent)
                    }
                }
                Button("Delete Sub-agent", role: .destructive) {
                    onDeleteSubAgent(parentAgent.slot, subAgent.id)
                    if isSelected {
                        shellSelection = .agent(parentAgent.slot)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.shellTextSecondary)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.shellAccentMuted.opacity(0.85) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(isSelected ? Color.shellAccent : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onTapGesture {
            shellSelection = .subAgent(parentSlot: parentAgent.slot, subAgentID: subAgent.id)
            onSelectAgent(parentAgent.slot)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            if case .project = shellSelection {
                ForEach(ProjectTab.allCases, id: \.rawValue) { tab in
                    tabButton(title: tab.rawValue, icon: tab.icon, selected: selectedProjectTab == tab) {
                        selectedProjectTab = tab
                    }
                }
            } else {
                ForEach(AgentTab.allCases, id: \.rawValue) { tab in
                    tabButton(title: tab.rawValue, icon: tab.icon, selected: selectedAgentTab == tab) {
                        selectedAgentTab = tab
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.shellSurface)
    }

    private func tabButton(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(selected ? Color.shellTextPrimary : Color.shellTextSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.shellElevated : Color.clear)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selected ? Color.shellAccent : Color.clear)
                    .frame(height: 2)
                    .offset(y: 6)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var contentArea: some View {
        switch shellSelection {
        case .project:
            projectContent
        case .agent:
            if let agent = selectedAgent {
                agentContent(agent)
            } else {
                projectContent
            }
        case let .subAgent(parentSlot, subAgentID):
            if let parentAgent = agents.first(where: { $0.slot == parentSlot }),
               let subAgent = subAgents(for: parentSlot).first(where: { $0.id == subAgentID }) {
                subAgentContent(parentAgent: parentAgent, subAgent: subAgent)
            } else if let fallbackAgent = selectedAgent {
                agentContent(fallbackAgent)
            } else {
                projectContent
            }
        }
    }

    @ViewBuilder
    private var projectContent: some View {
        switch selectedProjectTab {
        case .home:
            projectHomeContent
        case .dashboard:
            projectDashboardContent
        case .settings:
            projectSettingsContent
        case .logs:
            projectLogsContent
        }
    }

    private var projectHomeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Project X")

                Text("OpenClaw orchestration workspace with \(agents.count) agents, \(totalSubAgentCount) sub-agents, and \(totalConfiguredMemoryGB) GB configured capacity.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.shellTextSecondary)

                shellCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Health")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.shellTextPrimary)

                        HStack(spacing: 12) {
                            statusCell(title: "Processes", value: "\(runningAgentCount)/\(agents.count) running")
                            statusCell(title: "CPU", value: hostStats.map { String(format: "%.0f%%", $0.cpuBusyPercent) } ?? "n/a")
                            statusCell(title: "Memory", value: memorySummary)
                            statusCell(title: "Load", value: hostStats.map { String(format: "%.2f", $0.load1) } ?? "n/a")
                        }

                        dashboardProgressRow(
                            label: "Memory pressure",
                            detail: hostStats?.memoryUsedPercent.map { String(format: "%.0f%%", $0) } ?? "n/a",
                            normalized: (hostStats?.memoryUsedPercent ?? 0) / 100
                        )
                    }
                }

                sectionTitle("Open Claw Agents")

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(agents) { agent in
                        let snapshot = snapshot(for: agent.slot)
                        shellCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(statusColor(agent.runtime))
                                        .frame(width: 8, height: 8)
                                    Text(agent.displayName)
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.shellTextPrimary)
                                    Spacer()
                                }

                                Text(agent.containerName)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Color.shellTextMuted)

                                HStack(spacing: 10) {
                                    Text("RAM \(agent.configuredMemoryGB) GB")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.shellTextSecondary)
                                    Text("•")
                                        .foregroundStyle(Color.shellTextMuted)
                                    Text(statusLabel(snapshot?.state ?? agent.runtime))
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(statusColor(snapshot?.state ?? agent.runtime))
                                }

                                Text("\(subAgents(for: agent.slot).count) sub-agents")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.shellTextMuted)

                                if let snapshot {
                                    HStack(spacing: 10) {
                                        if let cpu = snapshot.cpuPercent {
                                            Text(String(format: "CPU %.0f%%", cpu))
                                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                                .foregroundStyle(Color.shellTextSecondary)
                                        }
                                        if let used = snapshot.liveMemoryUsageGB {
                                            let limit = snapshot.liveMemoryLimitGB ?? snapshot.configuredMemoryGB
                                            if let limit {
                                                Text(String(format: "MEM %.2f/%.1f GB", used, limit))
                                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                                    .foregroundStyle(Color.shellTextSecondary)
                                            } else {
                                                Text(String(format: "MEM %.2f GB", used))
                                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                                    .foregroundStyle(Color.shellTextSecondary)
                                            }
                                        }
                                        if let processes = snapshot.processCount {
                                            Text("PROC \(processes)")
                                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                                .foregroundStyle(Color.shellTextSecondary)
                                        }
                                    }
                                }

                                if let uptime = snapshot?.startedAt.map(formatUptime(since:)) {
                                    Text(uptime)
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.shellTextMuted)
                                }

                                if let folder = agent.accessFolderDisplayPath {
                                    Text(folder)
                                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                                        .foregroundStyle(Color.shellTextMuted)
                                        .lineLimit(1)
                                }

                                HStack(spacing: 8) {
                                    Button("Open") {
                                        shellSelection = .agent(agent.slot)
                                        selectedAgentTab = .home
                                        onSelectAgent(agent.slot)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("Shell") {
                                        shellSelection = .agent(agent.slot)
                                        selectedAgentTab = .shell
                                        onSelectAgent(agent.slot)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("Config") {
                                        onOpenSettings(agent.slot)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                shellCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Topology")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.shellTextPrimary)

                        if runningAgents.isEmpty {
                            Text("No running agents. Start an agent to visualize active topology.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.shellTextSecondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(runningAgents.enumerated()), id: \.element.id) { index, agent in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(Color.shellRunning)
                                            .frame(width: 6, height: 6)
                                        Text(agent.displayName)
                                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.shellTextPrimary)
                                        if index < runningAgents.count - 1 {
                                            Image(systemName: "arrow.right")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(Color.shellAccent)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                shellCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent Activity")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.shellTextPrimary)

                        ForEach(projectActivityRows, id: \.id) { row in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: row.icon)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(row.tint)
                                    .frame(width: 14, alignment: .center)
                                Text(row.text)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.shellTextSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var projectDashboardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Project Dashboard")

                shellCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Resource Overview")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.shellTextPrimary)
                        dashboardProgressRow(
                            label: "CPU busy",
                            detail: hostStats.map { String(format: "%.0f%%", $0.cpuBusyPercent) } ?? "n/a",
                            normalized: (hostStats?.cpuBusyPercent ?? 0) / 100
                        )
                        dashboardProgressRow(
                            label: "Memory usage",
                            detail: memorySummary,
                            normalized: (hostStats?.memoryUsedPercent ?? 0) / 100
                        )
                        dashboardProgressRow(
                            label: "Load / core",
                            detail: hostStats.map { String(format: "%.2f", $0.load1) } ?? "n/a",
                            normalized: loadNormalized
                        )
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    shellCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Agent Status Distribution")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.shellTextPrimary)

                            statusDistributionBar

                            HStack(spacing: 12) {
                                legendPill(color: .shellRunning, label: "\(runningAgentCount) running")
                                legendPill(color: .shellStopped, label: "\(stoppedAgentCount) stopped")
                                legendPill(color: .shellWarning, label: "\(missingAgentCount) missing")
                            }
                        }
                    }

                    shellCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("RAM Allocation by Agent")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.shellTextPrimary)

                            if agents.isEmpty {
                                Text("No agents configured.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.shellTextSecondary)
                            } else {
                                ForEach(agents) { agent in
                                    let snapshot = snapshot(for: agent.slot)
                                    let liveMemory = snapshot?.liveMemoryUsageGB
                                    dashboardProgressRow(
                                        label: agent.displayName,
                                        detail: liveMemory.map { String(format: "%.2f GB live", $0) } ?? "\(agent.configuredMemoryGB) GB configured",
                                        normalized: liveMemoryShare(for: agent.slot) ?? ramShare(for: agent)
                                    )
                                }
                            }
                        }
                    }

                    shellCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Access Folder Coverage")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.shellTextPrimary)

                            dashboardProgressRow(
                                label: "Folder configured",
                                detail: "\(agentsWithAccessFolder)/\(agents.count)",
                                normalized: agents.isEmpty ? 0 : Double(agentsWithAccessFolder) / Double(agents.count)
                            )

                            Text("Agents without folder mounts can still run, but host file workflows are limited.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.shellTextSecondary)
                        }
                    }

                    shellCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Quick Actions")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.shellTextPrimary)

                            HStack(spacing: 8) {
                                Button("Create Agent", action: onCreateAgent)
                                    .buttonStyle(.borderedProminent)
                                Button("Refresh", action: onRefresh)
                                    .buttonStyle(.bordered)
                            }

                            Divider()
                                .overlay(Color.shellBorder)

                            Text("Open agent dashboard")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.shellTextSecondary)

                            ForEach(agents.prefix(3)) { agent in
                                Button {
                                    shellSelection = .agent(agent.slot)
                                    selectedAgentTab = .dashboard
                                    onSelectAgent(agent.slot)
                                } label: {
                                    HStack {
                                        Text(agent.displayName)
                                        Spacer()
                                        Image(systemName: "arrow.right")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var projectSettingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Project Settings")

                shellCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Project-level templates and shared secrets are planned for next phase.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.shellTextSecondary)

                        Text("Current configuration remains agent-scoped to keep runtime behavior explicit and deterministic.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.shellTextSecondary)
                    }
                }

                shellCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Current Project Snapshot")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.shellTextPrimary)
                        monoRow(label: "Agents", value: "\(agents.count)")
                        monoRow(label: "Running", value: "\(runningAgentCount)")
                        monoRow(label: "Configured RAM", value: "\(totalConfiguredMemoryGB) GB")
                    }
                }
            }
            .padding(14)
        }
    }

    private var projectLogsContent: some View {
        ScrollView {
            shellCard {
                Text(manager.lastCommandOutput.isEmpty ? "No recent logs." : manager.lastCommandOutput)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.shellTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func subAgentContent(parentAgent: AgentListItem, subAgent: SubAgentListItem) -> some View {
        switch selectedAgentTab {
        case .home:
            let runtimeSnapshot = snapshot(for: parentAgent.slot)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle(subAgent.displayName)

                    shellCard {
                        HStack(spacing: 14) {
                            statusCell(title: "Parent Agent", value: parentAgent.displayName)
                            statusCell(title: "Allocated RAM", value: "\(subAgent.memoryMB) MB")
                            statusCell(title: "State", value: statusLabel(runtimeSnapshot?.state ?? parentAgent.runtime))
                            statusCell(title: "Created", value: formattedCreatedAt(subAgent.createdAt))
                        }
                    }

                    shellCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sub-agent workspace")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.shellTextPrimary)
                            Text(subAgentWorkspacePath(for: subAgent))
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(Color.shellTextSecondary)
                        }
                    }

                    shellCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Quick actions")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.shellTextPrimary)
                            HStack(spacing: 8) {
                                Button("Open Parent Shell") { selectedAgentTab = .shell }
                                    .buttonStyle(.borderedProminent)
                                Button("Open Parent Files") { selectedAgentTab = .files }
                                    .buttonStyle(.bordered)
                                Button("Open Parent Config") { selectedAgentTab = .config }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(14)
            }
        case .shell:
            TerminalScreen(
                containerName: parentAgent.containerName,
                agentLabel: "\(parentAgent.displayName)/\(subAgent.displayName)"
            )
            .id("terminal-sub-\(parentAgent.slot)-\(subAgent.id)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .files:
            FileBrowserScreen(
                manager: manager,
                initialPath: subAgentWorkspacePath(for: subAgent),
                onLocationChanged: { path, selected in
                    filesCurrentPath = path
                    filesSelectedPath = selected
                }
            )
            .id("files-sub-\(parentAgent.slot)-\(subAgent.id)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .dashboard:
            let runtimeSnapshot = snapshot(for: parentAgent.slot)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("\(subAgent.displayName) Dashboard")
                    shellCard {
                        HStack(spacing: 14) {
                            metricBar(
                                title: "CPU",
                                value: runtimeSnapshot?.cpuPercent ?? hostStats?.cpuBusyPercent ?? 0,
                                limit: 100
                            )
                            metricBar(
                                title: "Sub-agent RAM Share",
                                value: Double(subAgent.memoryMB),
                                limit: Double(Swift.max(512, parentAgent.configuredMemoryGB * 1024))
                            )
                        }
                    }
                    shellCard {
                        Text("Runs inside parent agent container \(parentAgent.containerName).")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.shellTextSecondary)
                    }
                }
                .padding(14)
            }

        case .config:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Sub-agent Config")
                    shellCard {
                        VStack(alignment: .leading, spacing: 8) {
                            monoRow(label: "Name", value: subAgent.displayName)
                            monoRow(label: "ID", value: subAgent.id)
                            monoRow(label: "RAM", value: "\(subAgent.memoryMB) MB")
                            monoRow(label: "Parent", value: parentAgent.containerName)
                            monoRow(label: "Workspace", value: subAgentWorkspacePath(for: subAgent))
                        }
                    }
                }
                .padding(14)
            }

        case .logs:
            ScrollView {
                shellCard {
                    Text(manager.lastCommandOutput.isEmpty ? "No logs captured yet." : manager.lastCommandOutput)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.shellTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private func agentContent(_ agent: AgentListItem) -> some View {
        switch selectedAgentTab {
        case .home:
            let runtimeSnapshot = snapshot(for: agent.slot)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle(agent.displayName)

                    shellCard {
                        HStack(spacing: 14) {
                            statusCell(title: "Status", value: statusLabel(runtimeSnapshot?.state ?? agent.runtime))
                            statusCell(title: "RAM", value: "\(agent.configuredMemoryGB) GB")
                            statusCell(title: "Folder", value: agent.accessFolderDisplayPath ?? "Not configured")
                        }
                    }

                    shellCard {
                        HStack(spacing: 14) {
                            statusCell(
                                title: "CPU",
                                value: runtimeSnapshot?.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "n/a"
                            )
                            statusCell(
                                title: "Live Memory",
                                value: formattedLiveMemory(snapshot: runtimeSnapshot) ?? "n/a"
                            )
                            statusCell(
                                title: "Processes",
                                value: runtimeSnapshot?.processCount.map(String.init) ?? "n/a"
                            )
                            statusCell(
                                title: "Uptime",
                                value: runtimeSnapshot?.startedAt.map(formatUptime(since:)) ?? "n/a"
                            )
                        }
                    }

                    shellCard {
                        HStack(spacing: 14) {
                            statusCell(title: "IP", value: runtimeSnapshot?.ipv4Address ?? "n/a")
                            statusCell(
                                title: "Dashboard Port",
                                value: runtimeSnapshot?.dashboardHostPort.map(String.init) ?? "n/a"
                            )
                            statusCell(
                                title: "Net Rx",
                                value: formattedBytes(runtimeSnapshot?.networkRxBytes)
                            )
                            statusCell(
                                title: "Net Tx",
                                value: formattedBytes(runtimeSnapshot?.networkTxBytes)
                            )
                        }
                    }

                    shellCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sub-agents")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.shellTextPrimary)

                            let subAgents = subAgents(for: agent.slot)
                            if subAgents.isEmpty {
                                Text("No sub-agents configured.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.shellTextSecondary)
                            } else {
                                ForEach(subAgents) { subAgent in
                                    HStack(spacing: 8) {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Color.shellTextMuted)
                                        Text(subAgent.displayName)
                                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.shellTextPrimary)
                                        Spacer()
                                        Text("\(subAgent.memoryMB) MB")
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(Color.shellTextSecondary)
                                        Button("Open") {
                                            onSelectAgent(agent.slot)
                                            shellSelection = .subAgent(parentSlot: agent.slot, subAgentID: subAgent.id)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                            }

                            Button {
                                onCreateSubAgent(agent.slot)
                            } label: {
                                Label("Create Sub-agent", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    shellCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Quick actions")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.shellTextPrimary)

                            HStack(spacing: 8) {
                                Button("Shell") {
                                    selectedAgentTab = .shell
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Files") {
                                    selectedAgentTab = .files
                                }
                                .buttonStyle(.bordered)

                                Button("Dashboard") {
                                    selectedAgentTab = .dashboard
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(14)
            }

        case .shell:
            TerminalScreen(containerName: agent.containerName, agentLabel: agent.displayName)
                .id("terminal-\(agent.slot)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .files:
            FileBrowserScreen(
                manager: manager,
                onLocationChanged: { path, selected in
                    filesCurrentPath = path
                    filesSelectedPath = selected
                }
            )
            .id("files-\(agent.slot)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .dashboard:
            let runtimeSnapshot = snapshot(for: agent.slot)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("\(agent.displayName) Dashboard")

                    shellCard {
                        HStack(spacing: 14) {
                            metricBar(
                                title: "CPU",
                                value: runtimeSnapshot?.cpuPercent ?? hostStats?.cpuBusyPercent ?? 0,
                                limit: 100
                            )
                            metricBar(
                                title: "Memory",
                                value: runtimeSnapshot?.liveMemoryUsageGB ?? Double(agent.configuredMemoryGB),
                                limit: runtimeSnapshot?.liveMemoryLimitGB ?? Double(Swift.max(2, agent.configuredMemoryGB))
                            )
                        }
                    }

                    shellCard {
                        HStack(spacing: 14) {
                            statusCell(title: "Processes", value: runtimeSnapshot?.processCount.map(String.init) ?? "n/a")
                            statusCell(title: "Uptime", value: runtimeSnapshot?.startedAt.map(formatUptime(since:)) ?? "n/a")
                            statusCell(title: "Network Rx", value: formattedBytes(runtimeSnapshot?.networkRxBytes))
                            statusCell(title: "Network Tx", value: formattedBytes(runtimeSnapshot?.networkTxBytes))
                        }
                    }

                    shellCard {
                        HStack {
                            Text("OpenClaw Control UI")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.shellTextPrimary)
                            Spacer()
                            Button("Open Dashboard") {
                                onOpenDashboard(agent.slot)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(14)
            }

        case .config:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Agent Config")

                    shellCard {
                        VStack(alignment: .leading, spacing: 8) {
                            monoRow(label: "Container", value: agent.containerName)
                            monoRow(label: "RAM", value: "\(agent.configuredMemoryGB) GB")
                            monoRow(label: "Access Folder", value: agent.accessFolderDisplayPath ?? "Not configured")

                            Button("Open Full Settings") {
                                onOpenSettings(agent.slot)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(14)
            }

        case .logs:
            ScrollView {
                shellCard {
                    Text(manager.lastCommandOutput.isEmpty ? "No logs captured yet." : manager.lastCommandOutput)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.shellTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.shellTextPrimary)
    }

    private func shellCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.shellElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.shellBorder, lineWidth: 1)
            )
    }

    private func statusCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.shellTextMuted)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.shellTextPrimary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dashboardProgressRow(label: String, detail: String, normalized: Double) -> some View {
        let clamped = min(max(normalized, 0), 1)
        let tint: Color = clamped > 0.95 ? .shellError : (clamped > 0.8 ? .shellWarning : .shellAccent)

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.shellTextSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.shellTextPrimary)
                    .lineLimit(1)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.shellBorder)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(tint)
                        .frame(width: Swift.max(6, geo.size.width * clamped))
                }
            }
            .frame(height: 8)
        }
    }

    private var statusDistributionBar: some View {
        let total = Swift.max(1, agents.count)
        let runningWidth = CGFloat(Double(runningAgentCount) / Double(total))
        let stoppedWidth = CGFloat(Double(stoppedAgentCount) / Double(total))
        let missingWidth = CGFloat(Double(missingAgentCount) / Double(total))

        return GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.shellRunning)
                    .frame(width: geo.size.width * runningWidth)
                Rectangle()
                    .fill(Color.shellStopped)
                    .frame(width: geo.size.width * stoppedWidth)
                Rectangle()
                    .fill(Color.shellWarning)
                    .frame(width: geo.size.width * missingWidth)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.shellBorder, lineWidth: 1)
            )
        }
        .frame(height: 12)
    }

    private func legendPill(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.shellTextSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.shellSurface, in: Capsule())
    }

    private func metricBar(title: String, value: Double, limit: Double) -> some View {
        let safeLimit = limit > 0 ? limit : 1
        let percent = min(Swift.max(value / safeLimit, 0), 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.shellTextSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.shellBorder)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(percent > 0.9 ? Color.shellError : (percent > 0.7 ? Color.shellWarning : Color.shellRunning))
                        .frame(width: Swift.max(6, geo.size.width * percent))
                }
            }
            .frame(height: 8)
            Text(String(format: "%.0f%%", percent * 100))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.shellTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.shellTextSecondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.shellTextPrimary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            statusMetricChip(
                title: "CPU",
                value: hostStats.map { String(format: "%.0f%%", $0.cpuBusyPercent) } ?? "n/a",
                normalized: hostStats.map { min(max($0.cpuBusyPercent / 100, 0), 1) } ?? 0
            )

            statusMetricChip(
                title: "MEM",
                value: memorySummary,
                normalized: (hostStats?.memoryUsedPercent ?? 0) / 100
            )

            statusMetricChip(
                title: "LOAD",
                value: hostStats.map { String(format: "%.2f", $0.load1) } ?? "n/a",
                normalized: loadNormalized
            )

            Spacer()

            Text(statusContextText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.shellTextSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.shellDeepest)
    }

    private func statusMetricChip(title: String, value: String, normalized: Double) -> some View {
        let clamped = min(max(normalized, 0), 1)
        let barColor: Color = clamped > 0.95 ? .shellError : (clamped > 0.8 ? .shellWarning : .shellAccent)

        return HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.shellTextMuted)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.shellBorder)
                    .frame(width: 34, height: 6)
                RoundedRectangle(cornerRadius: 3)
                    .fill(barColor)
                    .frame(width: max(4, 34 * clamped), height: 6)
            }

            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.shellTextSecondary)
        }
    }

    private var totalConfiguredMemoryGB: Int {
        agents.reduce(0) { $0 + $1.configuredMemoryGB }
    }

    private var totalSubAgentCount: Int {
        subAgentsByAgentSlot.values.reduce(0) { $0 + $1.count }
    }

    private func subAgents(for slot: Int) -> [SubAgentListItem] {
        subAgentsByAgentSlot[slot] ?? []
    }

    private func snapshot(for slot: Int) -> AgentRuntimeSnapshot? {
        agentRuntimeSnapshots[slot]
    }

    private var runningAgents: [AgentListItem] {
        agents.filter { $0.runtime == .running }
    }

    private var stoppedAgentCount: Int {
        agents.filter { $0.runtime == .stopped }.count
    }

    private var missingAgentCount: Int {
        agents.filter { $0.runtime == .missing }.count
    }

    private var agentsWithAccessFolder: Int {
        agents.filter { $0.accessFolderDisplayPath != nil }.count
    }

    private var totalLiveMemoryUsageGB: Double {
        agentRuntimeSnapshots.values.compactMap(\.liveMemoryUsageGB).reduce(0, +)
    }

    private func ramShare(for agent: AgentListItem) -> Double {
        guard totalConfiguredMemoryGB > 0 else {
            return 0
        }
        return Double(agent.configuredMemoryGB) / Double(totalConfiguredMemoryGB)
    }

    private func liveMemoryShare(for slot: Int) -> Double? {
        guard totalLiveMemoryUsageGB > 0 else {
            return nil
        }
        guard let live = snapshot(for: slot)?.liveMemoryUsageGB else {
            return nil
        }
        return live / totalLiveMemoryUsageGB
    }

    private func formattedLiveMemory(snapshot: AgentRuntimeSnapshot?) -> String? {
        guard let snapshot else {
            return nil
        }
        guard let used = snapshot.liveMemoryUsageGB else {
            return nil
        }
        if let limit = snapshot.liveMemoryLimitGB {
            return String(format: "%.2f / %.1f GB", used, limit)
        }
        return String(format: "%.2f GB", used)
    }

    private func formatUptime(since date: Date) -> String {
        let interval = max(0, Date().timeIntervalSince(date))
        let days = Int(interval) / 86_400
        let hours = (Int(interval) % 86_400) / 3_600
        let minutes = (Int(interval) % 3_600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func formattedBytes(_ value: Int64?) -> String {
        guard let value else {
            return "n/a"
        }
        return Self.byteCountFormatter.string(fromByteCount: value)
    }

    private func subAgentWorkspacePath(for subAgent: SubAgentListItem) -> String {
        "/home/agent/subagents/\(subAgent.id)"
    }

    private func formattedCreatedAt(_ timestamp: TimeInterval) -> String {
        let date = Date(timeIntervalSinceReferenceDate: timestamp)
        return Self.createdAtFormatter.string(from: date)
    }

    private func beginSubAgentRename(parentSlot: Int, subAgent: SubAgentListItem) {
        editingSubAgentParentSlot = parentSlot
        editingSubAgentID = subAgent.id
        editingSubAgentDraft = subAgent.displayName
    }

    private func commitSubAgentRename(parentSlot: Int, subAgentID: String) {
        let cleaned = editingSubAgentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        onRenameSubAgent(parentSlot, subAgentID, cleaned)
        editingSubAgentParentSlot = nil
        editingSubAgentID = nil
        editingSubAgentDraft = ""
    }

    private var projectActivityRows: [ProjectActivityRow] {
        var rows: [ProjectActivityRow] = []
        rows.append(
            ProjectActivityRow(
                icon: "checkmark.circle.fill",
                text: "Project snapshot refreshed. \(runningAgentCount) running, \(stoppedAgentCount) stopped, \(missingAgentCount) missing, \(totalSubAgentCount) sub-agents configured.",
                tint: .shellRunning
            )
        )
        if let hostStats {
            rows.append(
                ProjectActivityRow(
                    icon: "cpu",
                    text: String(format: "Node metrics: CPU %.0f%%, Memory %@", hostStats.cpuBusyPercent, memorySummary),
                    tint: .shellAccent
                )
            )
        }
        if !manager.lastCommandOutput.isEmpty {
            rows.append(
                ProjectActivityRow(
                    icon: "terminal.fill",
                    text: "Recent runtime output available in Logs tab.",
                    tint: .shellWarning
                )
            )
        }
        if rows.count < 4 {
            rows.append(
                ProjectActivityRow(
                    icon: "clock",
                    text: "Auto-refresh runs in the background for runtime and host metrics.",
                    tint: .shellTextMuted
                )
            )
        }
        return rows
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    private static let createdAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var selectedContext: (agent: AgentListItem, subAgent: SubAgentListItem?)? {
        switch shellSelection {
        case let .agent(slot):
            guard let agent = agents.first(where: { $0.slot == slot }) else {
                return nil
            }
            return (agent: agent, subAgent: nil)
        case let .subAgent(parentSlot, subAgentID):
            guard
                let agent = agents.first(where: { $0.slot == parentSlot }),
                let subAgent = subAgents(for: parentSlot).first(where: { $0.id == subAgentID })
            else {
                return nil
            }
            return (agent: agent, subAgent: subAgent)
        case .project:
            return nil
        }
    }

    private var selectedAgent: AgentListItem? {
        switch shellSelection {
        case let .agent(slot):
            return agents.first(where: { $0.slot == slot })
        case let .subAgent(parentSlot, _):
            return agents.first(where: { $0.slot == parentSlot })
        case .project:
            return agents.first(where: { $0.slot == selectedAgentSlot }) ?? agents.first
        }
    }

    private var memorySummary: String {
        guard let used = hostStats?.memoryUsedGB, let total = hostStats?.memoryTotalGB else {
            return "n/a"
        }
        return String(format: "%.1f/%.1f GB", used, total)
    }

    private var loadNormalized: Double {
        guard let hostStats else {
            return 0
        }
        let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return min(max(hostStats.load1 / Double(coreCount), 0), 1)
    }

    private var statusContextText: String {
        switch shellSelection {
        case .project:
            return "Project scope"
        case let .agent(slot):
            if selectedAgentTab == .files {
                return filesSelectedPath ?? filesCurrentPath
            }
            if selectedAgentTab == .shell {
                return "Agent \(slot) shell active"
            }
            return "Agent \(slot)"
        case let .subAgent(parentSlot, subAgentID):
            let subName = subAgents(for: parentSlot).first(where: { $0.id == subAgentID })?.displayName ?? subAgentID
            if selectedAgentTab == .files {
                return "\(subName): \(filesSelectedPath ?? filesCurrentPath)"
            }
            if selectedAgentTab == .shell {
                return "\(subName) shell via Agent \(parentSlot)"
            }
            return subName
        }
    }

    private func statusColor(_ runtime: AgentSlotRuntimeState) -> Color {
        switch runtime {
        case .running:
            return Color.shellRunning
        case .stopped:
            return Color.shellStopped
        case .missing:
            return Color.shellWarning
        }
    }

    private func statusLabel(_ runtime: AgentSlotRuntimeState) -> String {
        switch runtime {
        case .running:
            return "Running"
        case .stopped:
            return "Stopped"
        case .missing:
            return "Not created"
        }
    }

    private func beginInlineRename(_ agent: AgentListItem) {
        editingNameSlot = agent.slot
        editingNameDraft = agent.displayName
    }

    private func commitInlineRename(slot: Int) {
        let cleaned = editingNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        onRenameAgent(slot, cleaned)
        editingNameSlot = nil
        editingNameDraft = ""
    }

    private var dangerAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingDangerAction != nil },
            set: { if !$0 { pendingDangerAction = nil } }
        )
    }

    private var dangerTitle: String {
        switch pendingDangerAction {
        case .stop:
            return "Stop this agent?"
        case .deleteData:
            return "Delete agent data?"
        case .deleteInstance:
            return "Delete this agent instance?"
        case .none:
            return "Confirm action"
        }
    }

    private var dangerMessage: String {
        switch pendingDangerAction {
        case .stop:
            return "The OpenClaw process will stop and can be started again."
        case .deleteData:
            return "This removes OpenClaw profile data for this agent."
        case .deleteInstance:
            return "This removes the container and lightweight VM for this agent."
        case .none:
            return ""
        }
    }
}

private extension ShellSelection {
    var isAgentContext: Bool {
        switch self {
        case .agent, .subAgent:
            return true
        case .project:
            return false
        }
    }
}

private extension Color {
    static let shellDeepest = Color(hex: 0x0B0E14)
    static let shellSurface = Color(hex: 0x131720)
    static let shellElevated = Color(hex: 0x1A1F2E)
    static let shellBorder = Color(hex: 0x21262D)
    static let shellAccent = Color(hex: 0x58A6FF)
    static let shellAccentMuted = Color(hex: 0x1F3A5C)
    static let shellRunning = Color(hex: 0x3FB950)
    static let shellWarning = Color(hex: 0xD29922)
    static let shellError = Color(hex: 0xF85149)
    static let shellStopped = Color(hex: 0x484F58)
    static let shellTextPrimary = Color(hex: 0xE6EDF3)
    static let shellTextSecondary = Color(hex: 0x8B949E)
    static let shellTextMuted = Color(hex: 0x484F58)

    init(hex: UInt32, alpha: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

#Preview {
    HomeView(
        agents: [
            AgentListItem(
                slot: 1,
                displayName: "Research Agent",
                containerName: "claw-agent-1",
                runtime: .running,
                configuredMemoryGB: 4,
                accessFolderDisplayPath: "/Users/example/Documents/OpenClaw/Research"
            ),
            AgentListItem(
                slot: 2,
                displayName: "Build Agent",
                containerName: "claw-agent-2",
                runtime: .stopped,
                configuredMemoryGB: 2,
                accessFolderDisplayPath: nil
            )
        ],
        selectedAgentSlot: 1,
        isBusy: false,
        manager: AgentManager(autoSync: false),
        agentRuntimeSnapshots: [:],
        subAgentsByAgentSlot: [
            1: [
                SubAgentListItem(id: "scraper", displayName: "Scraper", memoryMB: 1024, createdAt: Date().timeIntervalSinceReferenceDate),
                SubAgentListItem(id: "indexer", displayName: "Indexer", memoryMB: 768, createdAt: Date().timeIntervalSinceReferenceDate)
            ]
        ],
        hostStats: HostSystemStats(
            cpuUserPercent: 18,
            cpuSystemPercent: 7,
            cpuIdlePercent: 75,
            memoryUsedGB: 12.6,
            memoryUnusedGB: 3.4,
            memoryTotalGB: 16,
            load1: 2.1,
            load5: 1.9,
            load15: 1.6
        ),
        nodeName: "node-01.clawnode.local",
        runningAgentCount: 1,
        onSelectAgent: { _ in },
        onCreateAgent: {},
        onRenameAgent: { _, _ in },
        onStart: { _ in },
        onStop: { _ in },
        onDeleteAgentData: { _ in },
        onDeleteInstance: { _ in },
        onOpenDashboard: { _ in },
        onOpenSettings: { _ in },
        onCreateSubAgent: { _ in },
        onRenameSubAgent: { _, _, _ in },
        onDeleteSubAgent: { _, _ in },
        onRefresh: {},
        onLockAndKeepAwake: {},
        onDisableLidCloseOverride: {}
    )
}
