import LurosProtocol
import Foundation

/// Checked before approval handling. The socket's worker identity, not a
/// session ID in a model argument, identifies the constrained caller.
enum AgentDelegationAdmission {
    /// A refusal for a capability the open step does not hold. The host
    /// records it in the assignment's ledger and wakes the opener, so the
    /// grant is one amendment away; the child is told the same in words.
    struct CapabilityRefusal: Error {
        var capability: AgentDelegationBrief.Capability
        var tool: String
        var violation: AgentDelegationViolation
    }

    static func refusal(_ request: HostRequest, host: SessionHost) async -> HostReply? {
        guard case let .worker(.agent, instance?) = request.caller else { return nil }
        do {
            guard let saved = try await host.delegations.record(instance) else {
                // Only a conversation that was opened from a brief and lost
                // its record is inert; one an agent opened before briefs
                // existed never had an authority and keeps working as it did.
                if AgentDelegatedMarker.exists(session: instance, state: host.stateDirectory) {
                    throw AgentDelegationViolation(stepID: "brief", title: "Assignment", rule: "This child has no saved authority. Start a new structured assignment; no mutation is authorised.")
                }
                return nil
            }
            do {
                try check(request.operation, promptTarget: request.operation == .agentPrompt
                          ? request.decode(AgentPromptRequest.self).sessionID : nil,
                          planTarget: request.operation == .agentDelegation
                          ? request.decode(AgentDelegationRequest.self).sessionID : nil,
                          saved: saved)
                try await AgentDelegationTargets.confine(request, saved: saved, host: host)
            } catch let refusal as CapabilityRefusal {
                await record(refusal, saved: saved, host: host)
                throw refusal.violation
            }
            return nil
        } catch {
            return request.fail(LurosError(.denied, error.localizedDescription))
        }
    }

    /// A request for a capability is not a grant: it is what the opener's
    /// next read of the account names, and the amendment that follows is the
    /// only thing that admits the operation.
    private static func record(_ refusal: CapabilityRefusal,
                               saved: AgentDelegationStore.Record,
                               host: SessionHost) async {
        _ = try? await host.assignments.requestCapability(
            child: saved.child,
            opener: saved.opener,
            capability: refusal.capability.rawValue,
            tool: refusal.tool,
            stepID: refusal.violation.stepID,
            planRevision: saved.plan.revision,
        )
        await AgentReportRelay.shared.accountChanged(saved.opener)
    }

    /// Host effects are narrower than tool labels. `confirmLoaded` can respring,
    /// git previews can fetch, and an opaque worker/plugin can execute code, so
    /// none gets a blanket read exemption from its UI name.
    static func check(_ operation: AppOperation, promptTarget: String? = nil,
                      planTarget: String? = nil, saved: AgentDelegationStore.Record) throws {
        let plan = saved.plan
        try plan.validate()
        switch operation {
        case .agentDelegation:
            guard planTarget == saved.child else { throw refusal(plan, "A constrained child may operate only on its own brief.") }
        case .agentPrompt:
            guard promptTarget == saved.opener else {
                throw refusal(plan, "A constrained child can report only to its opener, not delegate through another conversation.")
            }
        case .agentList, .agentAttach, .fileRead, .toolchainStatus, .toolchainCatalog,
             .sdkList, .extensionList, .projectCheck, .installationList,
             .gitStatus, .gitDiff, .gitBranches, .gitLog, .gitCommitDetail,
             .gitRemoteList, .gitSettings, .crashList, .crashOpen, .logStream,
             .captureScreen, .readUITree, .feedbackRead, .approvalDigestState:
            break
        default:
            // An operation with a confined adapter is admitted only while the
            // open step holds its capability; `AgentDelegationTargets` then
            // confines what it may act on. Everything else stays closed.
            guard let capability = AgentDelegationToolPolicy.capability(of: operation) else {
                throw refusal(plan, "\(operation.rawValue) has no confined execution adapter. Approval does not widen this step; an amendment of the step can.")
            }
            do {
                try plan.authorize(capability, expectedRevision: plan.revision)
            } catch let violation as AgentDelegationViolation {
                throw CapabilityRefusal(
                    capability: capability,
                    tool: operation.rawValue,
                    violation: AgentDelegationViolation(
                        stepID: violation.stepID,
                        title: violation.title,
                        rule: "\(operation.rawValue) needs the \(capability.rawValue) capability. \(violation.rule)",
                    ),
                )
            }
        }
    }

    private static func refusal(_ plan: AgentDelegationPlan, _ rule: String) -> AgentDelegationViolation {
        .init(stepID: plan.currentStep?.id ?? "end", title: plan.currentStep?.title ?? "Assignment", rule: rule)
    }
}
