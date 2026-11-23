import Foundation

/// The host-operation side of the delegation policy, and the one rule that
/// carries an opener's mode into its children. Kept apart from
/// `AgentDelegation.swift`, which names tools as strings and no wire type,
/// so a check can compile that file alone.
public extension AgentDelegationToolPolicy {
    /// The capability a host operation needs, when it has a confined adapter.
    /// The same table as `capability(ofTool:)`, for the operation each tool
    /// becomes: the host checks it before dispatching, so a worker that skips
    /// `admit` meets the step's capability here too.
    static func capability(of operation: AppOperation) -> AgentDelegationBrief.Capability? {
        switch operation {
        case .buildStart, .buildAttach, .buildCancel: .build
        case .installPackage, .removePackage, .confirmLoaded, .confirmLoadedAttach, .respring: .install
        case .gitStage, .gitUnstage, .gitCommit: .gitCommit
        case .distributionPublish: .publish
        default: nil
        }
    }
}

public extension AgentPromptRequest {
    /// Gives a conversation its opener's mode, and only that: a conversation
    /// the opener opened runs as the opener does — at creation, and again
    /// with every message the opener sends it. The opener's own mode came
    /// from the app; an agent's message carries none and cannot widen one.
    mutating func applyOpenerMode(_ mode: ApprovalMode, targetParentSessionID: String?,
                                  openerSessionID: String) {
        guard targetParentSessionID == openerSessionID else { return }
        approvalMode = mode
    }
}
