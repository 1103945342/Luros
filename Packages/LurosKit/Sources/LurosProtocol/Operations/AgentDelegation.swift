import Foundation

/// Delegation authority is kept by the host, not in a worker's todo list.
public struct AgentDelegationRequest: OperationRequest {
    public typealias Response = AgentDelegationResponse
    public static let operation = AppOperation.agentDelegation
    public enum Action: String, Codable, Sendable {
        case read, admit, blocked, review, accept, amend, check
        case acceptAssignment, cancelAssignment, failAssignment, seal
    }
    public var sessionID: String
    public var action: Action
    public var expectedRevision: UInt64?
    public var tool: String?
    public var path: String?
    public var step: AgentDelegationBrief.Step?
    public var note: String?
    /// What the child says it produced, on `review` and `blocked`: its own
    /// claim, never a check receipt. Nil leaves the ledger's claims alone.
    public var outputs: [AgentAssignment.Output]?
    /// On `amend`: what the assignment is now measured against. A step that
    /// changes what "done" means restates it here, and the member's old
    /// receipts stop counting. Nil keeps the acceptance as it was.
    public var acceptance: [String]?

    public init(sessionID: String, action: Action, expectedRevision: UInt64? = nil,
                tool: String? = nil, path: String? = nil, step: AgentDelegationBrief.Step? = nil,
                note: String? = nil, outputs: [AgentAssignment.Output]? = nil,
                acceptance: [String]? = nil) {
        self.sessionID = sessionID
        self.action = action
        self.expectedRevision = expectedRevision
        self.tool = tool
        self.path = path
        self.step = step
        self.note = note
        self.outputs = outputs
        self.acceptance = acceptance
    }
}

public struct AgentDelegationResponse: Codable, Sendable {
    /// Nil only for a session with no delegated assignment. Missing or corrupt
    /// state of a constrained session is an error, never an unrestricted plan.
    public var plan: AgentDelegationPlan?
    /// The opener's complete account; turn completion never implies acceptance.
    public var ledger: AgentAssignmentLedger?
    public init(plan: AgentDelegationPlan?, ledger: AgentAssignmentLedger? = nil) {
        self.plan = plan
        self.ledger = ledger
    }
}

public extension LurosService {
    func agentDelegation(_ request: AgentDelegationRequest) async throws -> AgentDelegationResponse {
        try await send(request)
    }
}

/// A deliberately closed first set. A capability in the brief does NOT make
/// an opaque executable safe: a tool has no way into a constrained
/// assignment until it has a reviewed adapter that confines its target, and
/// the open step must hold the capability the tool needs. Everything else —
/// commands, toolchains, SDKs, git pushes and history resets, subdelegation,
/// opaque extensions — stays closed whatever a step allows.
public enum AgentDelegationToolPolicy {
    public enum Effect: Sendable, Equatable {
        case read, bookkeeping, fileWrite
        /// A host operation with a confined adapter. The open step must hold
        /// `capability`, and the adapter (`AgentDelegationTargets` in the
        /// host) confines what it acts on to this conversation's own project.
        case confined(AgentDelegationBrief.Capability)
        case unsupported
    }

    public static func effect(of tool: String) -> Effect {
        if let capability = capability(ofTool: tool) {
            return .confined(capability)
        }
        switch tool {
        // file_show materializes managed Attachments/ inside the workspace;
        // without a scoped export adapter it is not a read-only operation.
        case "file_read", "file_list", "file_find", "file_grep",
             "luros_sdk_analyze_framework", "luros_sdk_read_header",
             "luros_memory_list", "luros_skill_list", "luros_skill_read",
             "luros_template_list", "luros_project_list", "luros_project_check_distribution",
             "luros_package_list", "luros_toolchain_list", "luros_sdk_list",
             "git_status", "git_diff", "git_branches", "git_log", "git_commit_detail",
             "git_remote_list", "luros_git_read_settings",
             "luros_conversation_list", "luros_conversation_read",
             "luros_todo_list", "luros_crash_list", "luros_crash_read", "luros_log_read",
             "luros_screen_read_tree", "luros_screen_capture", "luros_feedback_read",
             "web_search", "luros_web_fetch": return .read
        case "luros_todo_write", "luros_notification_send", "luros_question_ask",
             "luros_run_mode", "luros_conversation_plan", "luros_conversation_send":
            return .bookkeeping
        case "file_write", "file_create", "file_edit": return .fileWrite
        default: return .unsupported
        }
    }

    /// The capability a tool's host operation needs, when it has a confined
    /// adapter. Every tool absent here is refused whatever its step allows.
    public static func capability(ofTool tool: String) -> AgentDelegationBrief.Capability? {
        switch tool {
        // A build of this conversation's own project, and reading back or
        // cancelling the task it started.
        case "luros_project_build": .build
        // The package this project's build made: installed, confirmed
        // loaded, followed; removal is held to an installation this project
        // made. A respring is the last step of loading a tweak.
        case "luros_package_install", "luros_package_remove",
             "luros_package_confirm_loaded", "luros_device_respring": .install
        // The project's own history. Nothing leaves the device.
        case "git_stage", "git_unstage", "git_commit": .gitCommit
        // The packages this project's builds made, as they made them.
        case "luros_package_publish": .publish
        default: nil
        }
    }

    /// What a child checks before it asks the host: reads, bookkeeping and
    /// file writes are decided here, and a confined operation is left to the
    /// host's admission, which is also where a missing capability is recorded
    /// for the opener. The revision is checked either way.
    public static func authorizeBeforeForwarding(tool: String, path: String?, plan: AgentDelegationPlan,
                                                 expectedRevision: UInt64) throws {
        guard case .confined = effect(of: tool) else {
            return try authorize(tool: tool, path: path, plan: plan, expectedRevision: expectedRevision)
        }
        try plan.validate()
        let current = plan.currentStep
        guard plan.revision == expectedRevision else {
            throw AgentDelegationViolation(
                stepID: current?.id ?? "end",
                title: current?.title ?? "Assignment",
                rule: "The brief changed. Read its current revision before another operation.",
            )
        }
    }

    public static func authorize(tool: String, path: String?, plan: AgentDelegationPlan,
                                 expectedRevision: UInt64) throws {
        try plan.validate()
        let current = plan.currentStep
        func refuse(_ rule: String) -> AgentDelegationViolation {
            .init(stepID: current?.id ?? "end", title: current?.title ?? "Assignment", rule: rule)
        }
        guard plan.revision == expectedRevision else {
            throw refuse("The brief changed. Read its current revision before another operation.")
        }
        switch effect(of: tool) {
        case .read, .bookkeeping: return
        case .fileWrite:
            try plan.authorize(.fileWrite, canonicalRelativePath: path, expectedRevision: expectedRevision)
        case let .confined(capability):
            do {
                try plan.authorize(capability, expectedRevision: expectedRevision)
            } catch let violation as AgentDelegationViolation {
                // The step's own refusal, said for the tool that met it: the
                // child reports the blocker, and its opener amends the step.
                throw refuse("\(tool) needs the \(capability.rawValue) capability. \(violation.rule)")
            }
        case .unsupported:
            throw refuse("\(tool) has no confined execution adapter. Commands (including argv), toolchains, SDKs, pushes and history resets, subdelegation and opaque extensions are not allowed in a constrained assignment.")
        }
    }
}

