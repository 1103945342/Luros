import LurosProtocol
import Foundation
import KWWKAI

/// The same registration for account verification and conversation requests.
/// kwwk owns the transports; Luros adds DeepSeek's separate credential and
/// restores the catalog capabilities its generic Chat Completions login loses.
public enum ProviderRegistration {
    public static func resolve(
        storeID: String,
        manager: OAuthManager,
        modelOverride: String? = nil,
        parameters: AgentModelParameters? = nil,
        quotaStore: QuotaCacheStore? = nil,
    ) async throws -> ResolvedAuth? {
        guard let credentials = try await manager.credentials(for: storeID) else { return nil }
        if storeID == CredentialProviderID.deepSeek {
            let id = modelOverride ?? DeepSeekProvider.extra("defaultModel", in: credentials) ?? DeepSeekProvider.defaultModel
            let base = DeepSeekProvider.extra("baseUrl", in: credentials) ?? DeepSeekProvider.baseURL
            let fallback = Model(id: id, api: "openai-completions", provider: "deepseek", baseURL: base)
            let model = ModelResolver.resolving(
                DeepSeekProvider.applyingCatalog(to: fallback),
                catalogKey: "deepseek",
                parameters: parameters,
            )
            await APIRegistry.shared.register(OpenAICompletionsProvider(), scope: model.provider)
            return ResolvedAuth(model: model, modelLabel: "\(model.name) from DeepSeek", authResolver: { _, _ in
                ResolvedProviderAuth(token: credentials.access, scheme: .bearer)
            })
        }
        let registered: ResolvedAuth? = if CredentialProviderID.endpointNumber(storeID) != nil {
            // kwwk knows one OpenAI-compatible login, by its store id. A
            // further endpoint is registered as that login, from its own
            // credentials: the model carries its base URL, and the key is
            // bound to this resolution below.
            try await registerStored(
                storeId: CredentialProviderID.openAICompatible,
                manager: OAuthManager(
                    source: DeliveredCredentialSource([CredentialProviderID.openAICompatible: credentials]),
                ),
                modelOverride: modelOverride,
            )
        } else {
            try await registerStored(storeId: storeID, manager: manager, modelOverride: modelOverride)
        }
        guard let resolved = registered else { return nil }
        if let quotaStore {
            if storeID == CredentialProviderID.anthropicOAuth,
               let existing = await APIRegistry.shared.provider(scope: "anthropic", api: resolved.model.api) as? AnthropicProvider,
               !(existing.client is QuotaHeaderObservingHTTPClient)
            {
                let observingClient = QuotaHeaderObservingHTTPClient(
                    inner: existing.client,
                    storeID: storeID,
                    store: quotaStore,
                )
                let wrapped = AnthropicProvider(
                    api: existing.api,
                    client: observingClient,
                    defaultBaseURL: existing.defaultBaseURL,
                    defaultAPIKey: existing.defaultAPIKey,
                    apiVersion: existing.apiVersion,
                    extraHeaders: existing.extraHeaders,
                    authHeaderBuilder: existing.authHeaderBuilder,
                    systemPromptPrefix: existing.systemPromptPrefix,
                    maximumOutputTokens: existing.maximumOutputTokens,
                )
                await APIRegistry.shared.register(wrapped, scope: "anthropic")
            } else if storeID == "openai-codex",
                      let existing = await APIRegistry.shared.provider(scope: "chatgpt-codex", api: resolved.model.api) as? OpenAIResponsesProvider,
                      !(existing.client is QuotaHeaderObservingHTTPClient)
            {
                let observingClient = QuotaHeaderObservingHTTPClient(
                    inner: existing.client,
                    storeID: storeID,
                    store: quotaStore,
                )
                let wrapped = OpenAIResponsesProvider(
                    api: existing.api,
                    client: observingClient,
                    webSocketClient: existing.webSocketClient,
                    defaultBaseURL: existing.defaultBaseURL,
                    defaultAPIKey: existing.defaultAPIKey,
                    extraHeaders: existing.extraHeaders,
                    bodyOverrides: existing.bodyOverrides,
                    urlBuilder: existing.urlBuilder,
                    webSocketURLBuilder: existing.webSocketURLBuilder,
                    maxWebSocketFailures: existing.maxWebSocketFailures,
                    authHeaderBuilder: existing.authHeaderBuilder,
                    webSocketEndpoints: existing.webSocketEndpoints,
                )
                await APIRegistry.shared.register(wrapped, scope: "chatgpt-codex")
            }
        }
        // A model the endpoint's own record does not describe is read against
        // the catalogs: a relay's `cn:deepseek-v4.1-flash` is DeepSeek's model,
        // with its window, its ceiling and its images. An endpoint whose
        // figures are already the catalog's changes nothing here.
        let model = ModelResolver.resolving(
            DeepSeekProvider.isOfficial(credentials) ? DeepSeekProvider.applyingCatalog(to: resolved.model) : resolved.model,
            catalogKey: catalogKey(storeID: storeID),
            parameters: parameters,
        )
        // Nobody promised a hand-entered endpoint takes OpenAI's `developer`
        // role, and a reasoning model sends its system prompt under it: the
        // prompt goes as `system` instead, which every endpoint takes.
        let spoken = CredentialProviderID.isOpenAICompatible(storeID) ? model.keepingSystemRole : model
        guard !CredentialProviderID.isOpenAICompatible(storeID) else {
            return ResolvedAuth(
                model: spoken,
                modelLabel: resolved.modelLabel,
                authResolver: resolved.authResolver,
                providerSlots: resolved.providerSlots,
                authResolvers: resolved.authResolvers,
            )
        }
        // A request that names more than its key — Antigravity's Google Cloud
        // project, Qoder's account fields, Kiro's profile and region — finds
        // them only in kwwk's own resolver, which reads the extras the sign-in
        // stored and renews the token for the attempt that asks. That resolver
        // is kept whole: pinning the access token here alone sent every
        // Antigravity message without its project, and Code Assist answered
        // "the login names no Google Cloud project".
        if namesStoredExtras(storeID) {
            return ResolvedAuth(
                model: spoken,
                modelLabel: resolved.modelLabel,
                authResolver: resolved.authResolver,
                providerSlots: resolved.providerSlots,
                authResolvers: resolved.authResolvers,
            )
        }
        // The registry's transport is shared. Bind the key to this resolution
        // so another account verification cannot replace an in-flight key.
        return ResolvedAuth(
            model: spoken,
            modelLabel: resolved.modelLabel,
            authResolver: { _, _ in ResolvedProviderAuth(token: credentials.access, scheme: .bearer) },
            providerSlots: resolved.providerSlots,
            authResolvers: resolved.authResolvers,
        )
    }

    /// Store ids whose requests name what the sign-in stored beside the key,
    /// which only kwwk's own resolver builds (`antigravityAuthResolver`,
    /// `qoderResolver`, `kiroAuthResolver`): Antigravity's `projectId` and
    /// account tier, Qoder's `uid`/`machineId`, Kiro's `profileArn` and the
    /// region its address follows.
    static func namesStoredExtras(_ storeID: String) -> Bool {
        storeID == "antigravity" || storeID == "kiro"
            || storeID == QoderSite.global.id || storeID == QoderSite.cn.id
    }

    /// The catalog a store id's models are filed under, when the two names
    /// differ (a store id is `openai-api-key`, its catalog `openai`). Nil is an
    /// endpoint the catalogs do not key, read from every provider's copy.
    static func catalogKey(storeID: String) -> String? {
        switch storeID {
        case CredentialProviderID.openAICompatible: nil
        case "openai-api-key": "openai"
        case "anthropic-api-key": "anthropic"
        case "google-api-key": "google"
        case CredentialProviderID.deepSeek: "deepseek"
        default: storeID
        }
    }
}

public enum DeepSeekProvider {
    public static let baseURL = "https://api.deepseek.com"
    public static let defaultModel = "deepseek-flash"

    public static func isOfficial(_ credentials: OAuthCredentials) -> Bool {
        guard let base = extra("baseUrl", in: credentials) else { return false }
        return URLComponents(string: base)?.host?.lowercased() == "api.deepseek.com"
    }

    /// Only documented aliases inherit Flash's capabilities. Unknown IDs keep
    /// their original configuration, and the selected wire ID is never renamed.
    static func applyingCatalog(to original: Model) -> Model {
        let catalogID: String = switch original.id {
        case "deepseek-v4-flash", "deepseek-v4-flash-vision-exp": defaultModel
        default: original.id
        }
        guard var model = ModelsCatalog.model(provider: "deepseek", id: catalogID) else { return original }
        model.id = original.id
        model.api = original.api
        model.provider = original.provider
        model.baseURL = original.baseURL
        model.headers = original.headers
        return model
    }

    static func extra(_ key: String, in credentials: OAuthCredentials) -> String? {
        guard case let .string(value)? = credentials.extras[key], !value.isEmpty else { return nil }
        return value
    }
}
