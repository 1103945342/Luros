import Foundation
import KWWKAI
import LurosProtocol

/// The store id each provider's credential is kept under — the one
/// `ProviderConfiguration` and the quota cache read it back by (owner,
/// 2026-11-28). It moves here from the sign-in worker because the quota
/// coordinator in this package keys its snapshots by it too.
public extension AgentProvider {
    var storeID: String {
        switch self {
        case .githubCopilot: CredentialProviderID.githubCopilot
        case .anthropicOAuth: CredentialProviderID.anthropicOAuth
        case .anthropic: CredentialProviderID.anthropicAPIKey
        case .openAICompatible: CredentialProviderID.openAICompatible
        case let .openAICompatibleEndpoint(number): CredentialProviderID.openAICompatibleEndpoint(number)
        case .openAICodex: "openai-codex"
        case .cursor: "cursor"
        case .devin: "devin"
        case .kiro: "kiro"
        case .antigravity: "antigravity"
        case .qoder: QoderSite.global.id
        case .qoderCN: QoderSite.cn.id
        case .workBuddy: WorkBuddySite.china.id
        case .workBuddyAI: WorkBuddySite.international.id
        case .trae: TraeSite.china.id
        case .traeIntl: TraeSite.international.id
        case .raccoon: RaccoonOAuth.providerId
        case .kimiCoding: KimiSite.china.id
        case .kimiCodingGlobal: KimiSite.global.id
        case .xai: "xai"
        case .zai: ZaiSite.global.id
        case .zaiCodingCN: ZaiSite.china.id
        case .openRouter: "openrouter"
        case .openAI: "openai-api-key"
        case .google: "google-api-key"
        case .deepSeek: CredentialProviderID.deepSeek
        case .openCodeGo: OpenCodePlan.go.id
        case .openCodeZen: OpenCodePlan.zen.id
        }
    }
}
