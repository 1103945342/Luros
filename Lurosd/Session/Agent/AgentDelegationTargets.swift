import LurosProtocol
import Foundation

/// What a confined operation may act on. `AgentDelegationToolPolicy` says
/// the open step allows the operation; this says the target is the child's
/// own: its project's build, a task it started, a package its project's
/// build made, an installation its project made, or the packages its own
/// builds publish. Checked on every host request a constrained worker
/// sends, before approval handling, and never from what the worker claims
/// about itself.
enum AgentDelegationTargets {
    static func confine(
        _ request: HostRequest,
        saved: AgentDelegationStore.Record,
        host: SessionHost,
    ) async throws {
        let project = saved.projectID
        func deny(_ rule: String) -> AgentDelegationViolation {
            .init(
                stepID: saved.plan.currentStep?.id ?? "end",
                title: saved.plan.currentStep?.title ?? "Assignment",
                rule: rule,
            )
        }
        func started(_ taskID: TaskID) async -> Bool {
            guard case let .worker(.agent, session?) = request.caller else { return false }
            return await AgentSessionTable.shared.started(taskID, session: session)
        }

        switch request.operation {
        case .buildStart:
            let build = try request.decode(BuildStartRequest.self)
            guard build.projectID == project else {
                throw deny("A constrained build runs only this conversation's own project, never \(build.projectID).")
            }
        case .buildAttach:
            let attach = try request.decode(BuildAttachRequest.self)
            guard await started(attach.taskID) else {
                throw deny("A constrained child follows only the tasks its own conversation started.")
            }
        case .buildCancel:
            let cancel = try request.decode(BuildCancelRequest.self)
            guard await started(cancel.taskID) else {
                throw deny("A constrained child cancels only the tasks its own conversation started.")
            }
        case .installPackage:
            let install = try request.decode(InstallPackageRequest.self)
            guard let artifact = await host.artifacts.artifact(install.artifactID) else {
                throw deny("\(install.artifactID) is not an artifact one of Luros's builds made.")
            }
            guard artifact.projectID == project else {
                throw deny("A constrained child installs only packages this conversation's own project built.")
            }
        case .removePackage:
            let remove = try request.decode(RemovePackageRequest.self)
            guard let record = await host.installations.record(remove.installationID) else {
                throw deny("\(remove.installationID) is not an installation Luros recorded.")
            }
            guard record.projectID == project else {
                throw deny("A constrained child removes only what its own project installed.")
            }
        case .confirmLoaded:
            let confirm = try request.decode(ConfirmLoadedRequest.self)
            guard let named = confirm.projectID, named == project else {
                throw deny("A constrained child confirms only a build of its own project, named in the call.")
            }
        case .distributionPublish:
            let publish = try request.decode(DistributionPublishRequest.self)
            for file in publish.files {
                guard let artifact = await host.artifacts.artifact(path: file), artifact.projectID == project else {
                    throw deny("A constrained child publishes only packages its own project's builds made, as they made them.")
                }
            }
        default:
            break
        }
    }
}
