import Foundation
import KWWKAI
import LurosProtocol

public struct QuotaAccountDescriptor: Sendable {
    public var provider: AgentProvider
    public var storeID: String
    public var accountLabel: String?
    public var credentials: OAuthCredentials
    public var usesAPIKey: Bool

    public init(
        provider: AgentProvider,
        storeID: String,
        accountLabel: String?,
        credentials: OAuthCredentials,
        usesAPIKey: Bool,
    ) {
        self.provider = provider
        self.storeID = storeID
        self.accountLabel = accountLabel
        self.credentials = credentials
        self.usesAPIKey = usesAPIKey
    }
}

/// Coordinates quota refreshes with SingleFlight deduplication, attention-based
/// gating (10m foreground / 5m subscription / 1h background), 30s manual debounce,
/// exponential failure backoff, and 24h endpoint circuit breaking.
public actor QuotaCoordinator {
    public static let foregroundOrdinaryInterval: TimeInterval = 10 * 60
    public static let foregroundSubscriptionInterval: TimeInterval = 5 * 60
    public static let backgroundInterval: TimeInterval = 60 * 60
    public static let manualDebounceInterval: TimeInterval = 30
    public static let circuitBreakerDuration: TimeInterval = 24 * 60 * 60
    public static let baseBackoffSeconds: TimeInterval = 60
    public static let maxBackoffSeconds: TimeInterval = 30 * 60

    private let store: QuotaCacheStore
    private let transport: any QuotaHTTPTransport
    private let kwwkUsage: any KWWKQuotaUsageProvider
    private let clock: @Sendable () -> Date
    private var inFlight: [String: Task<AgentQuotaSnapshot, Never>] = [:]

    public init(
        store: QuotaCacheStore,
        transport: any QuotaHTTPTransport = URLSessionQuotaTransport.shared,
        kwwkUsage: any KWWKQuotaUsageProvider = DefaultKWWKQuotaUsageProvider(),
        clock: @escaping @Sendable () -> Date = Date.init,
    ) {
        self.store = store
        self.transport = transport
        self.kwwkUsage = kwwkUsage
        self.clock = clock
    }

    public func snapshots(
        for accounts: [QuotaAccountDescriptor],
        mode: AgentQuotaFetchMode,
        foreground: Bool,
        force: Bool,
    ) async -> [AgentQuotaSnapshot] {
        await withTaskGroup(of: (Int, AgentQuotaSnapshot).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    let snapshot = await self.snapshot(
                        for: account,
                        mode: mode,
                        foreground: foreground,
                        force: force,
                    )
                    return (index, snapshot)
                }
            }
            var ordered = Array<AgentQuotaSnapshot?>(repeating: nil, count: accounts.count)
            for await (index, snapshot) in group {
                ordered[index] = snapshot
            }
            return ordered.compactMap { $0 }
        }
    }

    public func snapshot(
        for account: QuotaAccountDescriptor,
        mode: AgentQuotaFetchMode,
        foreground: Bool,
        force: Bool,
    ) async -> AgentQuotaSnapshot {
        let now = clock()
        let poolID = QuotaPoolIdentity.poolID(
            provider: account.provider,
            storeID: account.storeID,
            credentials: account.credentials,
            usesAPIKey: account.usesAPIKey,
        )
        let baseURL = QuotaAdapters.resolvedBaseURL(for: account.provider, credentials: account.credentials)
        let endpointKey = baseURL.flatMap(QuotaPoolIdentity.normalizedEndpointKey(baseURL:))
        let existing = store.pool(for: poolID)
        let endpointChanged = existing?.endpointKey != nil && endpointKey != nil && existing?.endpointKey != endpointKey

        // Return cached state immediately without hitting network.
        if mode == .cachedOnly {
            return projectedSnapshot(
                existing: existing,
                account: account,
                poolID: poolID,
                baseURL: baseURL,
                now: now,
            )
        }

        // Providers with no public API never hit network.
        if !supportsNetworkQuery(account: account, baseURL: baseURL) {
            let billing = QuotaAdapters.billingOnlySnapshot(
                poolID: poolID,
                provider: account.provider,
                accountLabel: account.accountLabel,
                baseURL: baseURL,
                now: now,
            )
            store.upsertPool(
                PersistedQuotaPool(
                    poolID: poolID,
                    endpointKey: endpointKey,
                    snapshot: billing,
                ),
                secretToScrub: account.credentials.access,
            )
            return billing
        }

        // Gating checks (only when endpoint didn't change)
        if !endpointChanged, let existing {
            if mode == .manualRefresh {
                if !force,
                   let lastManual = existing.lastManualRefreshAt,
                   now.timeIntervalSince(lastManual) < Self.manualDebounceInterval
                {
                    let nextAllowed = lastManual.addingTimeInterval(Self.manualDebounceInterval)
                    return projectedSnapshot(
                        existing: existing,
                        account: account,
                        poolID: poolID,
                        baseURL: baseURL,
                        nextAllowedOverride: nextAllowed,
                        now: now,
                    )
                }
            } else {
                // Attention-gated background/foreground checks
                if let brokenUntil = existing.circuitBrokenUntil, now < brokenUntil {
                    return projectedSnapshot(
                        existing: existing,
                        account: account,
                        poolID: poolID,
                        baseURL: baseURL,
                        nextAllowedOverride: brokenUntil,
                        now: now,
                    )
                }
                if let cooldownUntil = existing.cooldownUntil, now < cooldownUntil {
                    return projectedSnapshot(
                        existing: existing,
                        account: account,
                        poolID: poolID,
                        baseURL: baseURL,
                        nextAllowedOverride: cooldownUntil,
                        now: now,
                    )
                }
                let isSubscription = QuotaPoolIdentity.isOAuthSubscription(account.provider) && !account.usesAPIKey
                let stalenessInterval: TimeInterval = if !foreground {
                    Self.backgroundInterval
                } else if isSubscription {
                    Self.foregroundSubscriptionInterval
                } else {
                    Self.foregroundOrdinaryInterval
                }
                let lastFetch = foreground
                    ? (existing.lastForegroundFetchAt ?? existing.snapshot.updatedAt)
                    : (existing.lastBackgroundFetchAt ?? existing.lastForegroundFetchAt ?? existing.snapshot.updatedAt)
                if let lastFetch, now.timeIntervalSince(lastFetch) < stalenessInterval {
                    return projectedSnapshot(
                        existing: existing,
                        account: account,
                        poolID: poolID,
                        baseURL: baseURL,
                        nextAllowedOverride: lastFetch.addingTimeInterval(stalenessInterval),
                        now: now,
                    )
                }
            }

            // Bulk/non-forced refresh respects 24h circuit breaker even on manualRefresh if !force,
            // unless user explicitly forces a re-probe (e.g. from detail page).
            if mode == .manualRefresh, !force,
               let brokenUntil = existing.circuitBrokenUntil, now < brokenUntil
            {
                return projectedSnapshot(
                    existing: existing,
                    account: account,
                    poolID: poolID,
                    baseURL: baseURL,
                    nextAllowedOverride: brokenUntil,
                    now: now,
                )
            }
        }

        // SingleFlight deduplication by poolID
        if let running = inFlight[poolID] {
            return await running.value
        }

        let task = Task<AgentQuotaSnapshot, Never> { [store, transport, kwwkUsage, clock] in
            await Self.executeQuery(
                account: account,
                poolID: poolID,
                baseURL: baseURL,
                endpointKey: endpointKey,
                existing: endpointChanged ? nil : existing,
                mode: mode,
                foreground: foreground,
                force: force,
                store: store,
                transport: transport,
                kwwkUsage: kwwkUsage,
                now: clock(),
            )
        }
        inFlight[poolID] = task
        let result = await task.value
        inFlight[poolID] = nil
        return result
    }

    private func supportsNetworkQuery(account: QuotaAccountDescriptor, baseURL: String?) -> Bool {
        let host = baseURL.flatMap { URLComponents(string: $0)?.host?.lowercased() }
        if !account.usesAPIKey {
            switch account.provider {
            case .anthropicOAuth, .openAICodex, .kimiCoding, .kimiCodingGlobal, .openRouter,
                 .githubCopilot, .antigravity, .cursor, .kiro, .qoder, .qoderCN,
                 .workBuddy, .workBuddyAI, .xai:
                return true
            default:
                return false
            }
        }
        if account.provider == .deepSeek || account.provider == .openRouter {
            return true
        }
        if let host, [
            "api.deepseek.com",
            "api.moonshot.cn", "api.moonshot.ai",
            "api.siliconflow.cn", "api.siliconflow.com",
            "openrouter.ai",
        ].contains(host) {
            return true
        }
        switch account.provider.kind {
        case .openAICompatible:
            return baseURL.flatMap(QuotaPoolIdentity.normalizedRelayRootURL(from:)) != nil
        case .openAI:
            return host != nil && host != "api.openai.com" && baseURL.flatMap(QuotaPoolIdentity.normalizedRelayRootURL(from:)) != nil
        case .anthropic:
            return host != nil && host != "api.anthropic.com" && baseURL.flatMap(QuotaPoolIdentity.normalizedRelayRootURL(from:)) != nil
        default:
            return false
        }
    }

    private func projectedSnapshot(
        existing: PersistedQuotaPool?,
        account: QuotaAccountDescriptor,
        poolID: String,
        baseURL: String?,
        nextAllowedOverride: Date? = nil,
        now: Date,
    ) -> AgentQuotaSnapshot {
        guard var snap = existing?.snapshot else {
            return QuotaAdapters.billingOnlySnapshot(
                poolID: poolID,
                provider: account.provider,
                accountLabel: account.accountLabel,
                baseURL: baseURL,
                now: now,
            )
        }
        snap.provider = account.provider
        snap.accountLabel = account.accountLabel ?? snap.accountLabel
        snap.nextAllowedAt = nextAllowedOverride ?? snap.nextAllowedAt
        if let brokenUntil = existing?.circuitBrokenUntil, now < brokenUntil {
            snap.status = .circuitBroken
            snap.circuitBrokenUntil = brokenUntil
        } else if let cooldownUntil = existing?.cooldownUntil, now < cooldownUntil {
            snap.status = .cooldown
            snap.cooldownUntil = cooldownUntil
        }
        return snap
    }

    private static func executeQuery(
        account: QuotaAccountDescriptor,
        poolID: String,
        baseURL: String?,
        endpointKey: String?,
        existing: PersistedQuotaPool?,
        mode: AgentQuotaFetchMode,
        foreground: Bool,
        force: Bool,
        store: QuotaCacheStore,
        transport: any QuotaHTTPTransport,
        kwwkUsage: any KWWKQuotaUsageProvider,
        now: Date,
    ) async -> AgentQuotaSnapshot {
        let cachedProbe: RelayProbeKind? = (!force ? endpointKey.flatMap { store.cachedRelayProbe(for: $0, now: now) } : nil)
        do {
            let result = try await QuotaAdapters.query(
                provider: account.provider,
                poolID: poolID,
                accountLabel: account.accountLabel,
                credentials: account.credentials,
                usesAPIKey: account.usesAPIKey,
                cachedRelayProbe: cachedProbe,
                transport: transport,
                kwwkUsage: kwwkUsage,
                now: now,
            )
            if let key = result.endpointKey, let probeKind = result.relayProbeKind {
                store.storeRelayProbe(endpointKey: key, kind: probeKind, now: now)
            }
            var snap = result.snapshot
            snap.nextAllowedAt = mode == .manualRefresh ? now.addingTimeInterval(Self.manualDebounceInterval) : nil
            let pool = PersistedQuotaPool(
                poolID: poolID,
                endpointKey: result.endpointKey ?? endpointKey,
                snapshot: snap,
                lastForegroundFetchAt: foreground ? now : existing?.lastForegroundFetchAt,
                lastBackgroundFetchAt: foreground ? existing?.lastBackgroundFetchAt : now,
                lastManualRefreshAt: mode == .manualRefresh ? now : existing?.lastManualRefreshAt,
                consecutiveFailures: 0,
                cooldownUntil: nil,
                circuitBrokenUntil: nil,
            )
            store.upsertPool(pool, secretToScrub: account.credentials.access)
            return store.pool(for: poolID)?.snapshot ?? snap
        } catch let error as QuotaAdapterError {
            if case .relayProbeExhausted = error, let endpointKey {
                store.storeRelayProbe(endpointKey: endpointKey, kind: .unsupported, now: now)
            }
            let failures = (existing?.consecutiveFailures ?? 0) + 1
            let isPermanent = error.isPermanentEndpointFailure
            let circuitBrokenUntil: Date? = isPermanent ? now.addingTimeInterval(Self.circuitBreakerDuration) : nil
            let cooldownUntil: Date?
            if isPermanent {
                cooldownUntil = nil
            } else if case let .rateLimited(retryAfter) = error, let retryAfter, retryAfter > 0 {
                cooldownUntil = now.addingTimeInterval(TimeInterval(retryAfter))
            } else {
                let exponent = min(5, max(0, failures - 1))
                let delay = min(Self.maxBackoffSeconds, Self.baseBackoffSeconds * pow(2.0, Double(exponent)))
                cooldownUntil = now.addingTimeInterval(delay)
            }

            let status: AgentQuotaStatus = isPermanent ? .circuitBroken : .cooldown
            let summary = errorSummary(for: error)
            let fallbackKind: AgentQuotaPoolKind = QuotaPoolIdentity.isOAuthSubscription(account.provider) && !account.usesAPIKey
                ? .window
                : .balance
            let snap = AgentQuotaSnapshot(
                poolID: poolID,
                provider: account.provider,
                accountLabel: account.accountLabel,
                kind: existing?.snapshot.kind ?? fallbackKind,
                source: existing?.snapshot.source ?? .activeAPI,
                status: status,
                balances: existing?.snapshot.balances ?? [],
                windows: existing?.snapshot.windows ?? [],
                planName: existing?.snapshot.planName,
                relayKind: existing?.snapshot.relayKind,
                billingURL: existing?.snapshot.billingURL ?? QuotaPoolIdentity.billingURL(for: account.provider, baseURL: baseURL),
                updatedAt: existing?.snapshot.updatedAt ?? now,
                nextAllowedAt: circuitBrokenUntil ?? cooldownUntil,
                cooldownUntil: cooldownUntil,
                circuitBrokenUntil: circuitBrokenUntil,
                errorSummary: summary,
            )
            let pool = PersistedQuotaPool(
                poolID: poolID,
                endpointKey: endpointKey,
                snapshot: snap,
                lastForegroundFetchAt: existing?.lastForegroundFetchAt,
                lastBackgroundFetchAt: existing?.lastBackgroundFetchAt,
                lastManualRefreshAt: mode == .manualRefresh ? now : existing?.lastManualRefreshAt,
                consecutiveFailures: failures,
                cooldownUntil: cooldownUntil,
                circuitBrokenUntil: circuitBrokenUntil,
            )
            store.upsertPool(pool, secretToScrub: account.credentials.access)
            return store.pool(for: poolID)?.snapshot ?? snap
        } catch {
            let failures = (existing?.consecutiveFailures ?? 0) + 1
            let exponent = min(5, max(0, failures - 1))
            let delay = min(Self.maxBackoffSeconds, Self.baseBackoffSeconds * pow(2.0, Double(exponent)))
            let cooldownUntil = now.addingTimeInterval(delay)
            let fallbackKind: AgentQuotaPoolKind = QuotaPoolIdentity.isOAuthSubscription(account.provider) && !account.usesAPIKey
                ? .window
                : .balance
            let snap = AgentQuotaSnapshot(
                poolID: poolID,
                provider: account.provider,
                accountLabel: account.accountLabel,
                kind: existing?.snapshot.kind ?? fallbackKind,
                source: existing?.snapshot.source ?? .activeAPI,
                status: .error,
                balances: existing?.snapshot.balances ?? [],
                windows: existing?.snapshot.windows ?? [],
                planName: existing?.snapshot.planName,
                relayKind: existing?.snapshot.relayKind,
                billingURL: existing?.snapshot.billingURL ?? QuotaPoolIdentity.billingURL(for: account.provider, baseURL: baseURL),
                updatedAt: existing?.snapshot.updatedAt ?? now,
                nextAllowedAt: cooldownUntil,
                cooldownUntil: cooldownUntil,
                errorSummary: "Network error while checking quota.",
            )
            let pool = PersistedQuotaPool(
                poolID: poolID,
                endpointKey: endpointKey,
                snapshot: snap,
                lastForegroundFetchAt: existing?.lastForegroundFetchAt,
                lastBackgroundFetchAt: existing?.lastBackgroundFetchAt,
                lastManualRefreshAt: mode == .manualRefresh ? now : existing?.lastManualRefreshAt,
                consecutiveFailures: failures,
                cooldownUntil: cooldownUntil,
                circuitBrokenUntil: nil,
            )
            store.upsertPool(pool, secretToScrub: account.credentials.access)
            return store.pool(for: poolID)?.snapshot ?? snap
        }
    }

    private static func errorSummary(for error: QuotaAdapterError) -> String {
        switch error {
        case .invalidResponse: "Invalid HTTP response from provider."
        case .unauthorized: "Authentication rejected (401/403)."
        case let .rateLimited(seconds):
            seconds.map { "Rate limited (retry after \($0)s)." } ?? "Rate limited (429)."
        case let .endpointUnsupported(status): "Endpoint unsupported (HTTP \(status)); paused for 24h."
        case let .httpStatus(_, summary): summary
        case .undecodable: "Response format could not be parsed."
        case .missingAccountIdentifier: "Missing ChatGPT account identifier."
        case .relayProbeExhausted: "No supported billing/usage endpoint detected; paused for 24h."
        }
    }
}
