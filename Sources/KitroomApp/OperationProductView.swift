import KitroomCore
import SwiftUI
import UniformTypeIdentifiers

struct ActivityProductView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Activity")
                        .font(.largeTitle.bold())
                    Text(
                        "Planned changes, verification results, and recoverable backups."
                    )
                    .foregroundStyle(.secondary)
                }

                if let message = model.operationMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.callout)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            .secondary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                }

                if model.operationRecords.isEmpty {
                    ContentUnavailableView(
                        "No operations yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(
                            "Approved local changes will appear here with "
                                + "their verification and rollback state."
                        )
                    )
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(model.operationRecords) { record in
                            OperationRecordCard(record: record)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Activity")
    }
}

struct OperationPlanReviewView: View {
    @EnvironmentObject private var model: AppModel
    let plan: OperationPlan

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusSummary
                    identitySection
                    changeSection
                    if !plan.warnings.isEmpty {
                        warningSection
                    }
                    verificationSection
                }
                .padding(24)
            }
            .navigationTitle("Review \(plan.kind.actionName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task {
                            await model.dismissPendingOperation()
                        }
                    }
                    .disabled(isApplying)
                }
                ToolbarItem(placement: .confirmationAction) {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Button(
                            plan.approvalButtonTitle,
                            role: plan.kind == .uninstall ? .destructive : nil
                        ) {
                            Task {
                                await model.applyPendingOperation()
                            }
                        }
                        .disabled(
                            isApplying
                                || plan.isExpired(at: timeline.date)
                        )
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 620)
        .interactiveDismissDisabled(isApplying)
    }

    private var isApplying: Bool {
        model.applyingOperationIDs.contains(plan.id)
    }

    private var statusSummary: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isApplying ? "hourglass" : "checkmark.shield")
                    .font(.title2)
                    .foregroundStyle(
                        isApplying ? Color.orange : Color.accentColor
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        isApplying
                            ? "Applying and verifying"
                            : "No change has been applied"
                    )
                    .font(.headline)
                    Text(
                        isApplying
                            ? "Kitroom is checking fresh agent state before "
                                + "and after the exact change."
                            : "Approval is bound to this plan's digest and "
                                + "expires at \(plan.expiresAt.formatted())."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if isApplying {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var identitySection: some View {
        GroupBox("Target") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Host") {
                    Text(hostName)
                }
                LabeledContent("Transport", value: "Local")
                if let identity = plan.hostIdentity {
                    LabeledContent("Verified identity") {
                        Text(identity)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Agent", value: plan.agent.displayName)
                LabeledContent(
                    "Scope",
                    value: operationScopeName(plan.scope)
                )
                LabeledContent(
                    "Expected transition",
                    value: operationTransitionSummary(plan)
                )
                LabeledContent(
                    "Risk",
                    value: plan.risk.rawValue.capitalized
                )
                if let extensionID = plan.extensionID {
                    LabeledContent("Capability") {
                        Text(extensionID)
                            .font(.body.monospaced())
                    }
                }
                if let source = plan.sourceReference {
                    LabeledContent("Source") {
                        Text(source)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if let version = plan.version {
                    LabeledContent("Version", value: version)
                }
                if let revision = plan.revision {
                    LabeledContent("Revision") {
                        Text(revision)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if let digest = plan.contentDigest {
                    LabeledContent("Content digest") {
                        Text(digest)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Plan digest") {
                    Text(plan.approvalDigest)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var changeSection: some View {
        GroupBox("Exact effect") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(plan.changes.enumerated()), id: \.offset) {
                    _, change in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(change.summary)
                            .font(.headline)
                        Text(change.target)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        if let preview = change.commandPreview {
                            LabeledContent("Method", value: preview)
                                .font(.callout)
                        }
                        if let rollback = change.rollback {
                            LabeledContent("Rollback", value: rollback)
                                .font(.callout)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var warningSection: some View {
        GroupBox("Warnings") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                }
            }
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(.vertical, 4)
        }
    }

    private var verificationSection: some View {
        GroupBox("Verification") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.verificationSteps, id: \.self) { step in
                    Label(step, systemImage: "checkmark.circle")
                }
            }
            .font(.callout)
            .padding(.vertical, 4)
        }
    }

    private var hostName: String {
        model.hosts.first { $0.id == plan.hostID }?.name ?? "Unknown host"
    }
}

struct LocalSkillInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    let availableAgents: [AgentKind]
    let onSelect: (URL, AgentKind) -> Void

    @State private var selectedAgent: AgentKind
    @State private var isChoosingDirectory = false
    @State private var selectionError: String?

    init(
        availableAgents: [AgentKind],
        onSelect: @escaping (URL, AgentKind) -> Void
    ) {
        self.availableAgents = availableAgents
        self.onSelect = onSelect
        _selectedAgent = State(initialValue: availableAgents.first ?? .codex)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose a folder that contains SKILL.md. Kitroom will "
                    + "inspect and digest every regular file before it creates "
                    + "an approval plan.")
                    .foregroundStyle(.secondary)

                Picker("Agent", selection: $selectedAgent) {
                    ForEach(availableAgents) { agent in
                        Text(agent.displayName).tag(agent)
                    }
                }
                .pickerStyle(.segmented)

                Label(
                    "This step only selects a source. The exact destination, "
                        + "rollback, and verification will appear on the next screen.",
                    systemImage: "checkmark.shield"
                )
                .font(.callout)

                if let selectionError {
                    Text(selectionError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                Spacer()

                HStack {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    Spacer()
                    Button("Choose skill folder") {
                        isChoosingDirectory = true
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .navigationTitle("Install or update skill")
        }
        .frame(width: 520, height: 320)
        .fileImporter(
            isPresented: $isChoosingDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            do {
                let url = try result.get().first
                    .map { $0.standardizedFileURL }
                guard let url else {
                    return
                }
                let agent = selectedAgent
                dismiss()
                Task { @MainActor in
                    await Task.yield()
                    onSelect(url, agent)
                }
            } catch {
                selectionError = SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            }
        }
    }
}

struct CodexMCPAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSubmit: (String, String) -> Void

    @State private var name = ""
    @State private var serverURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server name", text: $name)
                        .textContentType(.none)
                    TextField(
                        "HTTPS URL",
                        text: $serverURL,
                        prompt: Text("https://example.com/mcp")
                    )
                    .textContentType(.URL)
                } header: {
                    Text("Codex HTTP server")
                } footer: {
                    Text(
                        "For the first guarded path, Kitroom accepts only "
                            + "credential-free HTTPS URLs without query "
                            + "parameters. Tokens stay in environment-based "
                            + "configuration outside this form."
                    )
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add MCP server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review plan") {
                        let submittedName = name.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        let submittedURL = serverURL.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        dismiss()
                        onSubmit(submittedName, submittedURL)
                    }
                    .disabled(
                        name.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                            || serverURL.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 560, height: 360)
    }
}

private struct OperationRecordCard: View {
    let record: OperationRecord

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            "\(record.plan.kind.actionName) "
                                + (record.plan.extensionID ?? "capability")
                        )
                        .font(.headline)
                        Text(record.plan.agent.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(
                        record.state.displayName,
                        systemImage: record.state.systemImage
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(record.state.tint)
                }

                if let change = record.plan.changes.first {
                    Text(change.target)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let failure = record.failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let backupPath = record.backupPath {
                    LabeledContent("Backup") {
                        Text(backupPath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                LabeledContent(
                    "Rollback",
                    value: record.rollbackState.displayName
                )

                DisclosureGroup("Timeline") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(record.events) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Text(event.occurredAt, style: .time)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(event.message)
                                    .font(.callout)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
    }
}

private extension OperationKind {
    var actionName: String {
        switch self {
        case .inspect:
            "Inspect"
        case .install:
            "Install"
        case .update:
            "Update"
        case .enable:
            "Enable"
        case .disable:
            "Disable"
        case .uninstall:
            "Uninstall"
        }
    }

}

private extension OperationPlan {
    var approvalButtonTitle: String {
        if case .nativeMCP = execution {
            return kind == .install
                ? "Add MCP server"
                : "Remove MCP server"
        }
        if case .nativePlugin = execution {
            return switch kind {
            case .install:
                "Install plugin"
            case .update:
                "Update plugin"
            case .enable:
                "Enable plugin"
            case .disable:
                "Disable plugin"
            case .uninstall:
                "Uninstall plugin"
            case .inspect:
                "Inspect"
            }
        }
        return switch kind {
        case .install:
            "Install skill"
        case .update:
            "Update skill"
        case .uninstall:
            "Uninstall skill"
        default:
            kind.actionName
        }
    }
}

private extension OperationLifecycleState {
    var displayName: String {
        switch self {
        case .draft:
            "Draft"
        case .planned:
            "Planned"
        case .awaitingApproval:
            "Awaiting approval"
        case .applying:
            "Applying"
        case .verifying:
            "Verifying"
        case .completed:
            "Completed"
        case .failed:
            "Failed"
        case .rolledBack:
            "Rolled back"
        case .verificationFailed:
            "Verification failed"
        case .invalidated:
            "Invalidated"
        }
    }

    var systemImage: String {
        switch self {
        case .completed:
            "checkmark.circle.fill"
        case .failed, .verificationFailed:
            "xmark.octagon.fill"
        case .rolledBack:
            "arrow.uturn.backward.circle.fill"
        case .invalidated:
            "exclamationmark.triangle.fill"
        case .applying, .verifying:
            "hourglass"
        default:
            "clock"
        }
    }

    var tint: Color {
        switch self {
        case .completed:
            .green
        case .failed, .verificationFailed:
            .red
        case .rolledBack, .invalidated:
            .orange
        default:
            .secondary
        }
    }
}

private extension OperationRollbackState {
    var displayName: String {
        switch self {
        case .notRequired:
            "Not required"
        case .available:
            "Available"
        case .succeeded:
            "Succeeded"
        case .failed:
            "Failed"
        }
    }
}

private func operationScopeName(_ scope: InventoryScope?) -> String {
    switch scope {
    case .user:
        "User"
    case .repository:
        "Repository"
    case .localProject:
        "Local project"
    case .managed:
        "Managed"
    case .system:
        "System"
    case .session:
        "Session"
    case .unknown, nil:
        "Unknown"
    }
}

private func operationTransitionSummary(
    _ plan: OperationPlan
) -> String {
    switch plan.execution {
    case let .localSkill(spec):
        return switch spec.action {
        case .install:
            "Absent → installed"
        case .update:
            "Installed digest → approved new digest"
        case .uninstall:
            "Installed → absent"
        }
    case let .nativePlugin(spec):
        let before = pluginStateSummary(
            installed: spec.expectedBeforeInstalled,
            state: spec.expectedBeforeState,
            version: spec.expectedBeforeVersion
        )
        let after = pluginStateSummary(
            installed: spec.expectedAfterInstalled,
            state: spec.expectedAfterState,
            version: spec.expectedAfterVersion
        )
        return "\(before) → \(after)"
    case let .nativeMCP(spec):
        return spec.expectedAfterConfigured
            ? "Absent → configured"
            : "Configured → absent"
    case nil:
        return "Not specified"
    }
}

private func pluginStateSummary(
    installed: Bool,
    state: EffectiveState?,
    version: String?
) -> String {
    guard installed else {
        return "Absent"
    }
    var values = [state?.rawValue ?? "installed"]
    if let version {
        values.append(version)
    }
    return values.joined(separator: " · ")
}
