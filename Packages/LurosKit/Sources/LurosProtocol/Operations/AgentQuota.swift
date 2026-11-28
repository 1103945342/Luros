import Foundation

/// Exact `Decimal` wire coding so monetary balances and percentages never lose
/// precision when serialized through JSON or `JSONValue`.
public enum QuotaDecimalCoding {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    public static func encode(_ value: Decimal) -> String {
        var copy = value
        return NSDecimalString(&copy, posixLocale)
    }

    public static func decode(from decoder: any Decoder) throws -> Decimal {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self),
           let decimal = parse(text)
        {
            return decimal
        }
        if let decimal = try? container.decode(Decimal.self) {
            return decimal
        }
        if let number = try? container.decode(Double.self), number.isFinite {
            return Decimal(number)
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid decimal quota value")
    }

    public static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let decimal = Decimal(string: trimmed, locale: posixLocale),
              !decimal.isNaN
        else { return nil }
        return decimal
    }
}

/// How an account's quota is modeled for display.
public enum AgentQuotaPoolKind: String, Codable, Sendable, Equatable {
    /// Currency or unit-based balance pools (DeepSeek, Moonshot, SiliconFlow, OpenRouter, relays).
    case balance
    /// Rolling rate-limit / subscription windows (Claude, Codex, Kimi Code).
    case window
    /// Provider has no public quota API; exposes its official billing console link.
    case billingLink
}

/// Where the latest snapshot came from.
public enum AgentQuotaSource: String, Codable, Sendable, Equatable {
    case activeAPI
    case passiveHeaders
    case probedRelay
    case billingLink
}

/// Effective availability state of the quota pool.
public enum AgentQuotaStatus: String, Codable, Sendable, Equatable {
    case available
    case exhausted
    case cooldown
    case circuitBroken
    case unsupported
    case error
}

/// One currency or raw-unit balance pool.
public struct AgentQuotaBalance: Codable, Sendable, Equatable, Hashable {
    public var id: String
    /// ISO currency code (`"USD"`, `"CNY"`) or nil when unit is raw relay `quota`.
    public var currency: String?
    /// Unit suffix when `currency == nil` (e.g. `"quota"` for New API).
    public var unitLabel: String?
    public var isAvailable: Bool
    public var total: Decimal?
    public var granted: Decimal?
    public var toppedUp: Decimal?
    public var used: Decimal?
    public var remaining: Decimal?
    public var isUnlimited: Bool

    public init(
        id: String,
        currency: String? = nil,
        unitLabel: String? = nil,
        isAvailable: Bool = true,
        total: Decimal? = nil,
        granted: Decimal? = nil,
        toppedUp: Decimal? = nil,
        used: Decimal? = nil,
        remaining: Decimal? = nil,
        isUnlimited: Bool = false,
    ) {
        self.id = id
        self.currency = currency
        self.unitLabel = unitLabel
        self.isAvailable = isAvailable
        self.total = total
        self.granted = granted
        self.toppedUp = toppedUp
        self.used = used
        self.remaining = remaining
        self.isUnlimited = isUnlimited
    }

    private enum CodingKeys: String, CodingKey {
        case id, currency, unitLabel, isAvailable, total, granted, toppedUp, used, remaining, isUnlimited
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        unitLabel = try c.decodeIfPresent(String.self, forKey: .unitLabel)
        isAvailable = try c.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        total = try Self.decodeOptionalDecimal(c, forKey: .total)
        granted = try Self.decodeOptionalDecimal(c, forKey: .granted)
        toppedUp = try Self.decodeOptionalDecimal(c, forKey: .toppedUp)
        used = try Self.decodeOptionalDecimal(c, forKey: .used)
        remaining = try Self.decodeOptionalDecimal(c, forKey: .remaining)
        isUnlimited = try c.decodeIfPresent(Bool.self, forKey: .isUnlimited) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(currency, forKey: .currency)
        try c.encodeIfPresent(unitLabel, forKey: .unitLabel)
        try c.encode(isAvailable, forKey: .isAvailable)
        try c.encodeIfPresent(total.map(QuotaDecimalCoding.encode), forKey: .total)
        try c.encodeIfPresent(granted.map(QuotaDecimalCoding.encode), forKey: .granted)
        try c.encodeIfPresent(toppedUp.map(QuotaDecimalCoding.encode), forKey: .toppedUp)
        try c.encodeIfPresent(used.map(QuotaDecimalCoding.encode), forKey: .used)
        try c.encodeIfPresent(remaining.map(QuotaDecimalCoding.encode), forKey: .remaining)
        try c.encode(isUnlimited, forKey: .isUnlimited)
    }

    private static func decodeOptionalDecimal(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
    ) throws -> Decimal? {
        guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
        let nested = try c.superDecoder(forKey: key)
        return try QuotaDecimalCoding.decode(from: nested)
    }
}

/// One rolling rate/subscription window normalized to `0...100` percent.
public struct AgentQuotaWindow: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var label: String
    /// Percentage used in `0...100`.
    public var usedPercent: Decimal
    public var windowSeconds: Int?
    public var resetsAt: Date?
    public var status: String?

    public var remainingPercent: Decimal {
        max(0, min(100, 100 - usedPercent))
    }

    public init(
        id: String,
        label: String,
        usedPercent: Decimal,
        windowSeconds: Int? = nil,
        resetsAt: Date? = nil,
        status: String? = nil,
    ) {
        self.id = id
        self.label = label
        self.usedPercent = max(0, min(100, usedPercent))
        self.windowSeconds = windowSeconds
        self.resetsAt = resetsAt
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, usedPercent, windowSeconds, resetsAt, status
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        let rawUsed = try QuotaDecimalCoding.decode(from: c.superDecoder(forKey: .usedPercent))
        usedPercent = max(0, min(100, rawUsed))
        windowSeconds = try c.decodeIfPresent(Int.self, forKey: .windowSeconds)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(QuotaDecimalCoding.encode(usedPercent), forKey: .usedPercent)
        try c.encodeIfPresent(windowSeconds, forKey: .windowSeconds)
        try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try c.encodeIfPresent(status, forKey: .status)
    }
}

/// Sanitized quota snapshot for one signed-in provider account.
/// Contains no API keys, authorization headers, or raw provider payloads.
public struct AgentQuotaSnapshot: Codable, Sendable, Equatable {
    /// Deduplication identifier (`key:<sha256_prefix16>` or `oauth:<storeID>`).
    public var poolID: String
    public var provider: AgentProvider
    public var accountLabel: String?
    public var kind: AgentQuotaPoolKind
    public var source: AgentQuotaSource
    public var status: AgentQuotaStatus
    public var balances: [AgentQuotaBalance]
    public var windows: [AgentQuotaWindow]
    public var planName: String?
    public var relayKind: String?
    public var billingURL: URL?
    public var updatedAt: Date?
    public var nextAllowedAt: Date?
    public var manualDebounceUntil: Date?
    public var cooldownUntil: Date?
    public var circuitBrokenUntil: Date?
    public var errorSummary: String?

    public init(
        poolID: String,
        provider: AgentProvider,
        accountLabel: String? = nil,
        kind: AgentQuotaPoolKind,
        source: AgentQuotaSource,
        status: AgentQuotaStatus,
        balances: [AgentQuotaBalance] = [],
        windows: [AgentQuotaWindow] = [],
        planName: String? = nil,
        relayKind: String? = nil,
        billingURL: URL? = nil,
        updatedAt: Date? = nil,
        nextAllowedAt: Date? = nil,
        manualDebounceUntil: Date? = nil,
        cooldownUntil: Date? = nil,
        circuitBrokenUntil: Date? = nil,
        errorSummary: String? = nil,
    ) {
        self.poolID = poolID
        self.provider = provider
        self.accountLabel = accountLabel
        self.kind = kind
        self.source = source
        self.status = status
        self.balances = balances
        self.windows = windows
        self.planName = planName
        self.relayKind = relayKind
        self.billingURL = billingURL
        self.updatedAt = updatedAt
        self.nextAllowedAt = nextAllowedAt
        self.manualDebounceUntil = manualDebounceUntil
        self.cooldownUntil = cooldownUntil
        self.circuitBrokenUntil = circuitBrokenUntil
        self.errorSummary = errorSummary
    }
}

/// How the quota coordinator should apply attention/debounce gating.
public enum AgentQuotaFetchMode: String, Codable, Sendable, Equatable {
    /// Return sanitized cached state without hitting the network.
    case cachedOnly
    /// Refresh only pools whose foreground/background staleness gate elapsed.
    case attentionGated
    /// User-triggered refresh (subject to 30s manual debounce unless `force` is true).
    case manualRefresh
}

/// App-only operation served by luros-agent's `credential-import` worker.
public struct AgentProviderQuotaRequest: OperationRequest {
    public typealias Response = AgentProviderQuotaResponse
    public static let operation = AppOperation.agentProviderQuota

    /// Target provider, or nil to query all signed-in providers.
    public var provider: AgentProvider?
    public var mode: AgentQuotaFetchMode
    /// True when the Settings view is currently in the foreground (5m/10m gate vs 1h background gate).
    public var foreground: Bool
    /// Bypasses manual debounce / cooldown when explicitly requested.
    public var force: Bool

    public init(
        provider: AgentProvider? = nil,
        mode: AgentQuotaFetchMode = .attentionGated,
        foreground: Bool = true,
        force: Bool = false,
    ) {
        self.provider = provider
        self.mode = mode
        self.foreground = foreground
        self.force = force
    }
}

public struct AgentProviderQuotaResponse: Codable, Sendable, Equatable {
    public var quotas: [AgentQuotaSnapshot]

    public init(quotas: [AgentQuotaSnapshot] = []) {
        self.quotas = quotas
    }
}

public extension LurosService {
    func agentProviderQuota(
        provider: AgentProvider? = nil,
        mode: AgentQuotaFetchMode = .attentionGated,
        foreground: Bool = true,
        force: Bool = false,
    ) async throws -> AgentProviderQuotaResponse {
        try await send(AgentProviderQuotaRequest(
            provider: provider,
            mode: mode,
            foreground: foreground,
            force: force,
        ))
    }
}
