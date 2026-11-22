import LurosCore
import LurosProtocol
import Foundation

// Lightweight stand-ins for the session host's own plumbing, so the real
// `AgentDelegationStore` and `AgentDelegationAdmission` compile against the
// protocol module without the whole dispatcher. Everything below the line is
// a stub; the checks at the bottom only exercise the two production files.

enum Caller: Sendable, Equatable {
    case app
    case worker(WorkerRole, instance: String?)
}
typealias HostReply = (WireReply, [OwnedDescriptor])
struct HostRequest: Sendable {
    var caller: Caller
    var operation: AppOperation
    var payload: Data
    var requestID: String
    func decode<R: OperationRequest>(_ type: R.Type) throws -> R {
        try JSONDecoder().decode(R.self, from: payload)
    }
    func fail(_ error: any Error) -> HostReply {
        let error = (error as? LurosError) ?? LurosError(.internal, "\(error)")
        return (WireReply.failure(requestID, error), [])
    }
}
final class SessionHost: @unchecked Sendable {
    let delegations: AgentDelegationStore
    let assignments: AgentAssignmentStore
    let home: String
    let stateDirectory: URL
    let registry = TaskRegistryStub()
    /// What `AgentDelegationTargets` reads: which project each artifact and
    /// installation belongs to.
    let artifacts = ArtifactRegistryStub()
    let installations = InstallationStoreStub()
    init(delegations: AgentDelegationStore, assignments: AgentAssignmentStore, home: String, stateDirectory: URL) {
        self.delegations = delegations
        self.assignments = assignments
        self.home = home
        self.stateDirectory = stateDirectory
    }
}
final class ArtifactRegistryStub: @unchecked Sendable {
    struct Artifact: Sendable { var projectID: String? }
    private var byID: [String: Artifact] = [:]
    private var byPath: [String: Artifact] = [:]
    func add(id: String, path: String, projectID: String?) {
        let artifact = Artifact(projectID: projectID)
        byID[id] = artifact
        byPath[path] = artifact
    }
    func artifact(_ id: String) -> Artifact? { byID[id] }
    func artifact(path: String) -> Artifact? { byPath[path] }
}
final class InstallationStoreStub: @unchecked Sendable {
    struct Record: Sendable { var projectID: String? }
    private var records: [String: Record] = [:]
    func add(_ id: String, projectID: String?) { records[id] = Record(projectID: projectID) }
    func record(_ id: String) -> Record? { records[id] }
}
final class TaskRegistryStub: @unchecked Sendable {
    struct Record: Sendable { var state: TaskState }
    private var records: [String: Record] = [:]
    func set(_ id: String, state: TaskState) { records[id] = Record(state: state) }
    func record(_ id: TaskID) -> Record? { records[id.rawValue] }
}
final class AgentSessionTable: @unchecked Sendable {
    struct Entry: Sendable {
        var sessionID: String
        var parentSessionID: String?
        var task: TaskHandle
    }
    static let shared = AgentSessionTable()
    private var entries: [String: Entry] = [:]
    private var startedTasks: Set<String> = []
    func add(_ entry: Entry) { entries[entry.sessionID] = entry }
    func entry(_ sessionID: String) -> Entry? { entries[sessionID] }
    func markStarted(_ taskID: TaskID, session: String) {
        startedTasks.insert("\(session)/\(taskID.rawValue)")
    }
    func started(_ taskID: TaskID, session: String) -> Bool {
        startedTasks.contains("\(session)/\(taskID.rawValue)")
    }
}
/// The host resolves a project under `Projects/`; the checks only need the
/// directory the path rule is applied to.
enum AgentProjects {
    static func resolve(home: String, projectID: String, projectName: String?) throws -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectName ?? projectID, isDirectory: true)
    }
}
/// The real relay sends an account update; the checks need the call to land.
actor AgentReportRelay {
    static let shared = AgentReportRelay()
    private(set) var accountChanges: [String] = []
    func accountChanged(_ opener: String) async { accountChanges.append(opener) }
}

// MARK: - Checks

@main
struct DelegationHandlerChecks {
    static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            count += 1
        }
        func refuses(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                fatalError("allowed: \(name)")
            } catch {
                check(true, name)
            }
        }

        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("delegation-handler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let authority = base.appendingPathComponent("authority", isDirectory: true)
        let project = base.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = AgentDelegationStore(directory: authority)
        let assignments = AgentAssignmentStore(directory: base.appendingPathComponent("assignments", isDirectory: true))
        let host = SessionHost(
            delegations: store,
            assignments: assignments,
            home: base.appendingPathComponent("home", isDirectory: true).path,
            stateDirectory: base.appendingPathComponent("state", isDirectory: true),
        )

        let opener = UUID().uuidString
        let child = UUID().uuidString
        let child2 = UUID().uuidString
        let stranger = UUID().uuidString
        let brief = AgentDelegationBrief(
            objective: "Make one verified change",
            acceptance: ["The syntax check passes"],
            steps: [
                .init(id: "edit", title: "Edit", writeRoots: ["Sources"], capabilities: [.fileWrite]),
                .init(id: "review", title: "Review"),
            ],
        )

        // Registration and the unconstrained answer.
        check(try await store.record(child) == nil, "no record before registration")
        let plan = try await store.register(child: child, opener: opener, projectID: "project-1", brief: brief)
        check(plan.revision == 1, "registration makes the first revision")
        let unconstrained = try await store.apply(
            AgentDelegationRequest(sessionID: stranger, action: .read), caller: stranger,
        )
        check(unconstrained.plan == nil, "an unconstrained conversation reads nil")

        // Who may read and act.
        check(try await store.apply(AgentDelegationRequest(sessionID: child, action: .read), caller: child).plan == plan,
              "the child reads its own plan")
        check(try await store.apply(AgentDelegationRequest(sessionID: child, action: .read), caller: opener).plan == plan,
              "the opener reads the plan")
        await refuses("a stranger reads the plan") {
            _ = try await store.apply(AgentDelegationRequest(sessionID: child, action: .read), caller: stranger)
        }

        // Admission: the child, its own tool, the open step's revision.
        let admitted = try await store.apply(AgentDelegationRequest(
            sessionID: child, action: .admit, expectedRevision: 1, tool: "file_read",
        ), caller: child)
        check(admitted.plan?.revision == 1, "a read tool is admitted at the revision read")
        await refuses("an unsupported tool is not admitted") {
            _ = try await store.apply(AgentDelegationRequest(
                sessionID: child, action: .admit, expectedRevision: 1, tool: "shell_run",
            ), caller: child)
        }
        await refuses("a stale revision is refused") {
            _ = try await store.apply(AgentDelegationRequest(
                sessionID: child, action: .admit, expectedRevision: 0, tool: "file_read",
            ), caller: child)
        }
        await refuses("the opener cannot admit tools for the child") {
            _ = try await store.apply(AgentDelegationRequest(
                sessionID: child, action: .admit, expectedRevision: 1, tool: "file_read",
            ), caller: opener)
        }

        // Step transitions.
        let blocked = try await store.apply(AgentDelegationRequest(
            sessionID: child, action: .blocked, expectedRevision: 1,
        ), caller: child)
        check(blocked.plan?.statuses.first == .blocked, "the child reports its step blocked")
        await refuses("a blocked step cannot be reviewed") {
            _ = try await store.apply(AgentDelegationRequest(
                sessionID: child, action: .review, expectedRevision: blocked.plan?.revision ?? 2,
            ), caller: child)
        }
        await refuses("a child cannot accept its own step") {
            _ = try await store.apply(AgentDelegationRequest(
                sessionID: child, action: .accept, expectedRevision: blocked.plan?.revision ?? 2,
            ), caller: child)
        }
        await refuses("a child cannot amend its own step") {
            _ = try await store.apply(AgentDelegationRequest(
                sessionID: child, action: .amend,
                expectedRevision: blocked.plan?.revision ?? 2,
                step: .init(id: "edit", title: "Edit", writeRoots: ["Sources"]),
            ), caller: child)
        }
        await refuses("check has no isolated adapter") {
            _ = try await store.apply(AgentDelegationRequest(
                sessionID: child, action: .check, expectedRevision: blocked.plan?.revision ?? 2,
            ), caller: child)
        }
        // The step acceptance is not the assignment's: those belong to the
        // ledger, and this store refuses all four rather than widening a step.
        for action in [AgentDelegationRequest.Action.acceptAssignment, .cancelAssignment, .failAssignment, .seal] {
            await refuses("\(action.rawValue) is not a step transition") {
                _ = try await store.apply(AgentDelegationRequest(
                    sessionID: child, action: action, expectedRevision: 1, note: "why",
                ), caller: opener)
            }
        }

        // A step is reviewed by its child and released by its opener. A
        // second assignment walks that, so the blocked one above keeps its
        // own state.
        try await store.register(child: child2, opener: opener, projectID: "project-1", brief: brief)
        check(AgentDelegationToolPolicy.effect(of: "file_show") == .unsupported,
              "file_show has no scoped export adapter")
        await refuses("file_show is not admitted in a constrained conversation") {
            _ = try await store.apply(AgentDelegationRequest(
                sessionID: child2, action: .admit, expectedRevision: 1,
                tool: "file_show", path: "Attachments/x.png",
            ), caller: child2)
        }
        let review = try await store.apply(AgentDelegationRequest(
            sessionID: child2, action: .review, expectedRevision: 1,
        ), caller: child2)
        check(review.plan?.currentStep?.id == "edit", "a review request keeps the step open")
        await refuses("the opener cannot review for the child") {
            _ = try await store.apply(AgentDelegationRequest(
                sessionID: child2, action: .review, expectedRevision: review.plan?.revision ?? 2,
            ), caller: opener)
        }
        let released = try await store.apply(AgentDelegationRequest(
            sessionID: child2, action: .accept, expectedRevision: review.plan?.revision ?? 2,
        ), caller: opener)
        check(released.plan?.currentStep?.id == "review", "the opener releases the reviewed step")
        await refuses("a stale acceptance is refused") {
            _ = try await store.apply(AgentDelegationRequest(
                sessionID: child2, action: .accept, expectedRevision: review.plan?.revision ?? 2,
            ), caller: opener)
        }
        await refuses("a finished write step admits no write") {
            _ = try await store.apply(AgentDelegationRequest(
                sessionID: child2, action: .admit,
                expectedRevision: released.plan?.revision ?? 0, tool: "file_write", path: "Sources/a.txt",
            ), caller: child2)
        }

        // The host-side path check the mobile committer repeats.
        try AgentDelegationPath.validate("Sources/a.txt", projectRoot: project.path)
        check(true, "a plain project path is accepted")
        for path in ["../Outside/a.txt", "/etc/passwd", ".git/config", "Sources/../Elsewhere/a.txt"] {
            do {
                try AgentDelegationPath.validate(path, projectRoot: project.path)
                fatalError("allowed: \(path)")
            } catch {
                check(true, "the path check refuses \(path)")
            }
        }
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let outside = base.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("Sources/Link"), withDestinationURL: outside,
        )
        do {
            try AgentDelegationPath.validate("Sources/Link/a.txt", projectRoot: project.path)
            fatalError("allowed: a link component")
        } catch {
            check(true, "the path check refuses a link component")
        }

        // The operation admission, as the dispatcher calls it.
        guard let saved = try await store.record(child) else { fatalError("the record was not saved") }
        try AgentDelegationAdmission.check(.agentDelegation, planTarget: child, saved: saved)
        check(true, "agentDelegation on its own brief passes")
        for (operation, promptTarget, planTarget) in [
            (AppOperation.agentDelegation, nil, opener),
            (AppOperation.agentPrompt, stranger, nil),
            (AppOperation.agentOpen, nil, nil),
            (AppOperation.agentAbort, nil, nil),
        ] {
            do {
                try AgentDelegationAdmission.check(
                    operation,
                    promptTarget: promptTarget,
                    planTarget: planTarget,
                    saved: saved,
                )
                fatalError("allowed: \(operation.rawValue)")
            } catch {
                check(true, "\(operation.rawValue) is refused by the admission")
            }
        }
        try AgentDelegationAdmission.check(.agentPrompt, promptTarget: opener, saved: saved)
        check(true, "a report to the opener passes")
        for operation in [AppOperation.fileRead, .gitStatus, .logStream] {
            try AgentDelegationAdmission.check(operation, saved: saved)
            check(true, "\(operation.rawValue) reads are admitted")
        }
        check(await AgentDelegationAdmission.refusal(
            HostRequest(caller: .app, operation: .fileRead, payload: Data(), requestID: "admission"),
            host: host,
        ) == nil, "the app's own call is not a constrained one")
        check(await AgentDelegationAdmission.refusal(
            HostRequest(caller: .worker(.agent, instance: child), operation: .fileRead, payload: Data(), requestID: "admission"),
            host: host,
        ) == nil, "the child's read passes the admission")

        // A conversation opened from a brief whose record is gone is inert; one
        // an agent opened before briefs existed never had an authority to lose
        // and keeps working, as it did before there were briefs.
        let legacy = UUID().uuidString.lowercased()
        check(await AgentDelegationAdmission.refusal(
            HostRequest(caller: .worker(.agent, instance: legacy), operation: .respring, payload: Data(), requestID: "admission"),
            host: host,
        ) == nil, "a chat with no brief and no marker is not treated as constrained")
        let orphan = UUID().uuidString.lowercased()
        try AgentDelegatedMarker.mark(session: orphan, state: host.stateDirectory)
        check(AgentDelegatedMarker.exists(session: orphan, state: host.stateDirectory), "the marker is written")
        check(!AgentDelegatedMarker.exists(session: legacy, state: host.stateDirectory), "an unmarked chat stays unmarked")
        check(await AgentDelegationAdmission.refusal(
            HostRequest(caller: .worker(.agent, instance: orphan), operation: .respring, payload: Data(), requestID: "admission"),
            host: host,
        ) != nil, "a chat governed by a brief that lost its record is refused")

        // MARK: - A step's capability admits its own project's work

        for (tool, capability) in [
            ("luros_project_build", AgentDelegationBrief.Capability.build),
            ("luros_package_install", AgentDelegationBrief.Capability.install),
            ("luros_package_remove", AgentDelegationBrief.Capability.install),
            ("luros_package_confirm_loaded", AgentDelegationBrief.Capability.install),
            ("luros_device_respring", AgentDelegationBrief.Capability.install),
            ("git_stage", AgentDelegationBrief.Capability.gitCommit),
            ("git_commit", AgentDelegationBrief.Capability.gitCommit),
            ("luros_package_publish", AgentDelegationBrief.Capability.publish),
        ] {
            check(AgentDelegationToolPolicy.effect(of: tool) == .confined(capability),
                  "\(tool) is confined to \(capability.rawValue)")
        }
        check(AgentDelegationToolPolicy.effect(of: "shell_run") == .unsupported,
              "shell_run stays closed")
        check(AgentDelegationToolPolicy.capability(of: .buildStart) == .build
            && AgentDelegationToolPolicy.capability(of: .buildAttach) == .build
            && AgentDelegationToolPolicy.capability(of: .distributionPublish) == .publish
            && AgentDelegationToolPolicy.capability(of: .gitCommit) == .gitCommit
            && AgentDelegationToolPolicy.capability(of: .confirmLoaded) == .install,
            "the host's operations carry the same table")
        check(AgentDelegationToolPolicy.capability(of: .agentRunCode) == nil,
              "run-as-code has no confined adapter")

        // A conversation its opener opened follows the opener's mode as that
        // opener holds it now; every other conversation keeps the app's.
        var childMode = AgentPromptRequest(sessionID: child, text: "x", approvalMode: .confirm)
        childMode.applyOpenerMode(.full, targetParentSessionID: opener, openerSessionID: opener)
        check(childMode.approvalMode == .full, "a child follows its opener's Full")
        var foreignMode = AgentPromptRequest(sessionID: child, text: "x", approvalMode: .confirm)
        foreignMode.applyOpenerMode(.full, targetParentSessionID: nil, openerSessionID: opener)
        check(foreignMode.approvalMode == .confirm, "a conversation it did not open keeps the app's mode")
        var othersChild = AgentPromptRequest(sessionID: child, text: "x", approvalMode: .relaxed)
        othersChild.applyOpenerMode(.full, targetParentSessionID: stranger, openerSessionID: opener)
        check(othersChild.approvalMode == .relaxed, "another opener's child is not this opener's to widen")

        let builder = UUID().uuidString
        let building = AgentDelegationBrief(
            objective: "Build the project",
            acceptance: ["It builds"],
            steps: [.init(id: "build", title: "Build", capabilities: [.build, .install, .publish])],
        )
        try await store.register(child: builder, opener: opener, projectID: "project-1", brief: building)
        let buildAdmitted = try await store.apply(AgentDelegationRequest(
            sessionID: builder, action: .admit, expectedRevision: 1, tool: "luros_project_build",
        ), caller: builder)
        check(buildAdmitted.plan?.currentStep?.id == "build",
              "a step's build capability admits luros_project_build")
        do {
            _ = try await store.apply(AgentDelegationRequest(
                sessionID: builder, action: .admit, expectedRevision: 1, tool: "git_commit",
            ), caller: builder)
            fatalError("allowed: git_commit under a step without gitCommit")
        } catch {
            check(error.localizedDescription.contains("needs the gitCommit capability")
                && error.localizedDescription.contains("amendment"),
                "the refusal names the capability and the amendment: \(error.localizedDescription)")
        }

        if let forwarded = buildAdmitted.plan {
            try AgentDelegationToolPolicy.authorizeBeforeForwarding(
                tool: "luros_project_build", path: nil, plan: forwarded,
                expectedRevision: forwarded.revision,
            )
            check(true, "a confined tool is left to the host's admission")
            do {
                try AgentDelegationToolPolicy.authorizeBeforeForwarding(
                    tool: "shell_run", path: nil, plan: forwarded,
                    expectedRevision: forwarded.revision,
                )
                fatalError("allowed: shell_run forwarded")
            } catch {
                check(true, "an unsupported tool is still refused before forwarding")
            }
        } else {
            check(false, "the admitted plan reads back")
        }

        // The target: the conversation's own project, its own artifact and
        // installation, never another's.
        host.artifacts.add(id: "artifact-own", path: "/Builds/own/x.deb", projectID: "project-1")
        host.artifacts.add(id: "artifact-other", path: "/Builds/other/y.deb", projectID: "another")
        host.installations.add("install-own", projectID: "project-1")
        host.installations.add("install-other", projectID: "another")
        func askTarget(_ operation: AppOperation, _ payload: Data) async -> Bool {
            await AgentDelegationAdmission.refusal(
                HostRequest(caller: .worker(.agent, instance: builder), operation: operation,
                            payload: payload, requestID: "target"),
                host: host,
            ) == nil
        }
        let digestValue = "sha256:" + String(repeating: "0", count: 64)
        let ownBuild = try JSONEncoder().encode(BuildStartRequest(projectID: "project-1"))
        let otherBuild = try JSONEncoder().encode(BuildStartRequest(projectID: "another"))
        check(await askTarget(.buildStart, ownBuild),
              "a build of the conversation's own project is admitted")
        check(!(await askTarget(.buildStart, otherBuild)),
              "a build of another project is refused")
        let ownInstall = try JSONEncoder().encode(
            InstallPackageRequest(artifactID: "artifact-own", digest: digestValue),
        )
        let otherInstall = try JSONEncoder().encode(
            InstallPackageRequest(artifactID: "artifact-other", digest: digestValue),
        )
        check(await askTarget(.installPackage, ownInstall),
              "the project's own artifact installs")
        check(!(await askTarget(.installPackage, otherInstall)),
              "another project's artifact is refused")
        let ownRemoval = try JSONEncoder().encode(RemovePackageRequest(installationID: "install-own"))
        let otherRemoval = try JSONEncoder().encode(RemovePackageRequest(installationID: "install-other"))
        check(await askTarget(.removePackage, ownRemoval),
              "the project's own installation is removed")
        check(!(await askTarget(.removePackage, otherRemoval)),
              "another project's installation is refused")
        let ownPublish = try JSONEncoder().encode(
            DistributionPublishRequest(files: ["/Builds/own/x.deb"]),
        )
        let otherPublish = try JSONEncoder().encode(
            DistributionPublishRequest(files: ["/Builds/other/y.deb"]),
        )
        check(await askTarget(.distributionPublish, ownPublish),
              "the project's own package publishes")
        check(!(await askTarget(.distributionPublish, otherPublish)),
              "another project's package does not")

        // A refused capability is recorded where the opener reads it, once:
        // the child asks the host to admit the tool, which is the one place
        // it cannot record for itself what the step lacked.
        _ = try await assignments.register(child: builder, opener: opener, brief: building)
        let admitCommit = try JSONEncoder().encode(AgentDelegationRequest(
            sessionID: builder, action: .admit, expectedRevision: 1, tool: "git_commit",
        ))
        check(!(await askTarget(.agentDelegation, admitCommit)),
              "an admit for a capability the step lacks is refused")
        let ledger = try await assignments.read(opener: opener)
        let group = ledger?.groups.first { $0.assignment(builder) != nil }
        check(group?.assignment(builder)?.capabilityRequests?.map(\.capability) == ["gitCommit"],
              "the refusal is recorded for the opener: \(String(describing: group?.assignment(builder)?.capabilityRequests))")
        check(group?.snapshot().member(builder)?.capabilityRequests?.first?.capability == "gitCommit",
              "the account shows the request")
        check(!(await askTarget(.gitCommit, Data())), "the same refusal is refused again")
        let again = try await assignments.assignment(child: builder, opener: opener)
        check(again?.capabilityRequests?.count == 1, "a repeated request is recorded once")

        // Corrupt authority is refused, never read as an empty plan.
        let file = authority.appendingPathComponent(child + ".json")
        let preserved = try Data(contentsOf: file)
        try Data("not json".utf8).write(to: file)
        do {
            _ = try await store.apply(AgentDelegationRequest(sessionID: child, action: .read), caller: child)
            fatalError("allowed: a corrupt record")
        } catch {
            check(true, "a corrupt record refuses the read")
        }
        check(try Data(contentsOf: file) == Data("not json".utf8), "the corrupt bytes were preserved")
        try preserved.write(to: file)

        // MARK: - The real handler: the assignment's lifecycle

        func call(_ caller: Caller, _ request: AgentDelegationRequest) async throws -> WireReply {
            await AgentDelegationHandler.handle(
                HostRequest(
                    caller: caller,
                    operation: .agentDelegation,
                    payload: try JSONEncoder().encode(request),
                    requestID: "check",
                ),
                host: host,
            ).0
        }
        func succeeded(_ name: String, _ reply: WireReply) throws -> AgentDelegationResponse {
            guard case let .success(data) = reply.result else { fatalError("refused: \(name)") }
            check(true, name)
            return try JSONCoding.decode(AgentDelegationResponse.self, from: data)
        }
        func refused(_ name: String, _ reply: WireReply) {
            if case .success = reply.result { fatalError("allowed: \(name)") }
            check(true, name)
        }

        // The host's own tables, which the handler trusts for identity and
        // for whether a session is still running.
        let running = TaskHandle(taskID: TaskID(rawValue: UUID().uuidString), kind: .agent)
        host.registry.set(running.taskID.rawValue, state: .running)
        AgentSessionTable.shared.add(.init(sessionID: opener, parentSessionID: nil, task: running))
        AgentSessionTable.shared.add(.init(sessionID: child, parentSessionID: opener, task: running))
        AgentSessionTable.shared.add(.init(sessionID: child2, parentSessionID: opener, task: running))

        try await assignments.register(child: child, opener: opener, brief: brief)
        try await assignments.register(child: child2, opener: opener, brief: brief)
        let member = try await assignments.assignment(child: child, opener: opener)
        let memberRevision = member?.revision ?? 0

        // The app may read a plan and nothing else.
        let appRead = try succeeded("the app reads a plan", try await call(
            .app, AgentDelegationRequest(sessionID: child, action: .read),
        ))
        check(appRead.plan != nil, "the plan came back")
        refused("the app cannot change a plan", try await call(
            .app, AgentDelegationRequest(sessionID: child, action: .blocked, expectedRevision: memberRevision),
        ))

        // Only the assignment's opener disposes of it, and only its own.
        refused("a child cannot cancel its assignment", try await call(
            .worker(.agent, instance: child),
            AgentDelegationRequest(
                sessionID: child, action: .cancelAssignment,
                expectedRevision: memberRevision, note: "The user ended it",
            ),
        ))
        refused("a child cannot seal another group", try await call(
            .worker(.agent, instance: child),
            AgentDelegationRequest(
                sessionID: opener, action: .seal,
                expectedRevision: (try await assignments.read(opener: opener))?.groups.first?.revision ?? 0,
            ),
        ))
        let cancelled = try succeeded("the opener cancels the assignment", try await call(
            .worker(.agent, instance: opener),
            AgentDelegationRequest(
                sessionID: child, action: .cancelAssignment,
                expectedRevision: memberRevision, note: "The user ended it",
            ),
        ))
        check(cancelled.ledger?.groups.first?.assignments.first { $0.id == child }?.state == .cancelled,
              "the ledger says cancelled")
        check(await AgentReportRelay.shared.accountChanges.contains(opener), "the opener's account heard it")

        // A terminal assignment takes no further mutation, and still reads.
        let planRevision = try await store.record(child)?.plan.revision ?? 0
        refused("a cancelled child cannot write", try await call(
            .worker(.agent, instance: child),
            AgentDelegationRequest(
                sessionID: child, action: .admit, expectedRevision: planRevision,
                tool: "file_write", path: "Sources/a.txt",
            ),
        ))
        _ = try succeeded("a cancelled child can still read its plan", try await call(
            .worker(.agent, instance: child), AgentDelegationRequest(sessionID: child, action: .read),
        ))
        let ledgerRead = try succeeded("the opener reads the whole account", try await call(
            .worker(.agent, instance: opener), AgentDelegationRequest(sessionID: child, action: .read),
        ))
        check(ledgerRead.ledger != nil, "the opener's read carries the ledger")

        // Seal fixes the membership, then the last working member is ended.
        let groupRevision = try await assignments.read(opener: opener)?.groups.first?.revision ?? 0
        let sealed = try succeeded("the opener seals the group", try await call(
            .worker(.agent, instance: opener),
            AgentDelegationRequest(sessionID: opener, action: .seal, expectedRevision: groupRevision),
        ))
        check(sealed.ledger?.groups.first?.isSealed == true, "the group is sealed")
        do {
            _ = try await assignments.register(child: UUID().uuidString, opener: opener, brief: brief)
            fatalError("allowed: a member after seal")
        } catch {
            check(true, "a sealed group takes no new member")
        }
        let second = try await assignments.assignment(child: child2, opener: opener)
        let final = try succeeded("the opener ends the remaining member", try await call(
            .worker(.agent, instance: opener),
            AgentDelegationRequest(
                sessionID: child2, action: .failAssignment,
                expectedRevision: second?.revision ?? 0, note: "The service went away",
            ),
        ))
        check(final.ledger?.groups.first?.assignments.first { $0.id == child2 }?.state == .failed,
              "the ledger says failed")

        print("ok: \(count) delegation-handler checks")
    }
}
