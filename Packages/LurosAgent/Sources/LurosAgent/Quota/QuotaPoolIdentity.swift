import CryptoKit
import Foundation
import KWWKAI
import LurosProtocol

/// Deterministic deduplication identity and official billing links for provider accounts.
public enum QuotaPoolIdentity {
    /// First 16 lowercase hex characters of the SHA-256 digest of `secret`.
    /// Never retains or exposes the raw key.
    public static func keyDigestPrefix16(for secret: String) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    public static func isOAuthSubscription(_ provider: AgentProvider) -> Bool {
        switch provider {
        case .anthropicOAuth, .openAICodex, .githubCopilot, .cursor, .devin, .kiro,
             .antigravity, .qoder, .qoderCN, .workBuddy, .workBuddyAI, .trae, .traeIntl,
             .raccoon, .kimiCoding, .kimiCodingGlobal, .xai:
            true
        case .anthropic, .openAI, .google, .deepSeek, .openRouter,
             .openAICompatible, .openAICompatibleEndpoint, .openCodeGo, .openCodeZen,
             .zai, .zaiCodingCN:
            false
        }
    }

    /// Canonical pool key:
    /// - API key accounts deduplicate by SHA-256 prefix 16 (`key:<hex16>`).
    /// - OAuth subscriptions identify by store instance (`oauth:<storeID>`).
    public static func poolID(
        provider: AgentProvider,
        storeID: String,
        credentials: OAuthCredentials,
        usesAPIKey: Bool,
    ) -> String {
        if usesAPIKey || !isOAuthSubscription(provider) {
            return "key:\(keyDigestPrefix16(for: credentials.access))"
        }
        return "oauth:\(storeID)"
    }

    /// Normalized endpoint key (scheme + lowercased host + port + normalized path)
    /// used for 24h relay probe caching and endpoint circuit-breaking. Never includes
    /// userinfo, query parameters, or secrets.
    public static func normalizedEndpointKey(baseURL: String) -> String? {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        let rootPath = stripTrailingSlashAndV1(components.path)
        return "\(scheme)://\(host)\(port)\(rootPath)"
    }

    /// Removes any trailing `/` and trailing `/v1` segment for relay root probing.
    public static func stripTrailingSlashAndV1(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") {
            result.removeLast()
        }
        if result.lowercased().hasSuffix("/v1") {
            result.removeLast(3)
            while result.hasSuffix("/") {
                result.removeLast()
            }
        }
        return result
    }

    /// Removes trailing `/` and trailing `/v1` from a full base URL string.
    public static func normalizedRelayRootURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = stripTrailingSlashAndV1(components.path)
        return components.url
    }

    /// Fixed official billing / usage console URL for each provider.
    public static func billingURL(for provider: AgentProvider, baseURL: String? = nil) -> URL? {
        if let baseURL, let host = URLComponents(string: baseURL)?.host?.lowercased() {
            if host == "api.deepseek.com" {
                return URL(string: "https://platform.deepseek.com/usage")
            }
            if host == "api.moonshot.cn" {
                return URL(string: "https://platform.moonshot.cn/console/account")
            }
            if host == "api.moonshot.ai" {
                return URL(string: "https://platform.moonshot.ai/console/account")
            }
            if host == "api.siliconflow.cn" {
                return URL(string: "https://cloud.siliconflow.cn/account/ak")
            }
            if host == "api.siliconflow.com" {
                return URL(string: "https://cloud.siliconflow.com/account/ak")
            }
            if host == "openrouter.ai" {
                return URL(string: "https://openrouter.ai/settings/credits")
            }
        }
        switch provider {
        case .openAI:
            return URL(string: "https://platform.openai.com/settings/organization/billing/overview")
        case .anthropic:
            return URL(string: "https://console.anthropic.com/settings/billing")
        case .anthropicOAuth:
            return URL(string: "https://claude.ai/settings/usage")
        case .openAICodex:
            return URL(string: "https://chatgpt.com/codex/settings/usage")
        case .google:
            return URL(string: "https://aistudio.google.com/spend")
        case .deepSeek:
            return URL(string: "https://platform.deepseek.com/usage")
        case .openRouter:
            return URL(string: "https://openrouter.ai/settings/credits")
        case .githubCopilot:
            return URL(string: "https://github.com/settings/copilot")
        case .cursor:
            return URL(string: "https://cursor.com/dashboard?tab=billing")
        case .devin:
            return URL(string: "https://app.devin.ai/settings/billing")
        case .kiro:
            return URL(string: "https://app.kiro.dev/account")
        case .antigravity:
            return URL(string: "https://antigravity.google")
        case .qoder:
            return URL(string: "https://qoder.com/account")
        case .qoderCN:
            return URL(string: "https://qoder.cn/account")
        case .workBuddy:
            return URL(string: "https://copilot.tencent.com")
        case .workBuddyAI:
            return URL(string: "https://www.codebuddy.ai")
        case .trae:
            return URL(string: "https://www.trae.com.cn/account")
        case .traeIntl:
            return URL(string: "https://www.trae.ai/account")
        case .raccoon:
            return URL(string: "https://xiaohuanxiong.com")
        case .kimiCoding:
            return URL(string: "https://www.kimi.com/code/console")
        case .kimiCodingGlobal:
            return URL(string: "https://www.kimi.ai/code/console")
        case .xai:
            return URL(string: "https://console.x.ai")
        case .zai:
            return URL(string: "https://z.ai/manage-apikey/subscription")
        case .zaiCodingCN:
            return URL(string: "https://bigmodel.cn/usercenter/proj-mgmt/rate-limits")
        case .openCodeGo, .openCodeZen:
            return URL(string: "https://opencode.ai/auth")
        case .openAICompatible, .openAICompatibleEndpoint:
            return nil
        }
    }
}
