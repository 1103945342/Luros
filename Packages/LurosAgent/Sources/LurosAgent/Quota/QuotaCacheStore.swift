import Foundation
import LurosCore
import LurosProtocol

public enum RelayProbeKind: String, Codable, Sendable, Equatable {
    case sub2api
    case newapi
    case openAIBilling
    case unsupported
}

public struct PersistedRelayProbe: Codable, Sendable, Equatable {
    public var endpointKey: String
    public var kind: RelayProbeKind
    public var probedAt: Date

    public init(endpointKey: String, kind: RelayProbeKind, probedAt: Date) {
        self.endpointKey = endpointKey
        self.kind = kind
        self.probedAt = probedAt
    }
}

public struct PersistedQuotaPool: Codable, Sendable, Equatable {
    public var poolID: String
    public var endpointKey: String?
    public var snapshot: AgentQuotaSnapshot
    public var lastForegroundFetchAt: Date?
    public var lastBackgroundFetchAt: Date?
    public var lastManualRefreshAt: Date?
    public var consecutiveFailures: Int
    public var cooldownUntil: Date?
    public var circuitBrokenUntil: Date?

    public init(
        poolID: String,
        endpointKey: String? = nil,
        snapshot: AgentQuotaSnapshot,
        lastForegroundFetchAt: Date? = nil,
        lastBackgroundFetchAt: Date? = nil,
        lastManualRefreshAt: Date? = nil,
        consecutiveFailures: Int = 0,
        cooldownUntil: Date? = nil,
        circuitBrokenUntil: Date? = nil,
    ) {
        self.poolID = poolID
        self.endpointKey = endpointKey
        self.snapshot = snapshot
        self.lastForegroundFetchAt = lastForegroundFetchAt
        self.lastBackgroundFetchAt = lastBackgroundFetchAt
        self.lastManualRefreshAt = lastManualRefreshAt
        self.consecutiveFailures = consecutiveFailures
        self.cooldownUntil = cooldownUntil
        self.circuitBrokenUntil = circuitBrokenUntil
    }
}

/// Sanitized local cache for quota pools and 24h relay probe results.
/// Never stores raw API keys, authorization headers, or raw HTTP response bodies.
public final class QuotaCacheStore: @unchecked Sendable {
    public static let probeCacheTTL: TimeInterval = 24 * 60 * 60

    private let dataRoot: LurosDataRoot
    private let lock = NSLock()
    private let redaction: LogRedaction

    public init(dataRoot: LurosDataRoot) {
        self.dataRoot = dataRoot
        redaction = LogRedaction(home: dataRoot.home.path, installRoot: nil)
    }

    private var poolsFile: URL {
        dataRoot.quota.appendingPathComponent("pools.json")
    }

    private var probesFile: URL {
        dataRoot.quota.appendingPathComponent("probes.json")
    }

    // MARK: - Pools

    public func loadPools() -> [PersistedQuotaPool] {
        lock.withLock {
            readPreservedList(at: poolsFile).items
        }
    }

    public func pool(for poolID: String) -> PersistedQuotaPool? {
        loadPools().first { $0.poolID == poolID }
    }

    public func upsertPool(_ entry: PersistedQuotaPool, secretToScrub: String? = nil) {
        let cleaned = sanitizePool(entry, secretToScrub: secretToScrub)
        lock.withLock {
            var list = readPreservedList(at: poolsFile) as PreservedList<PersistedQuotaPool>
            if let index = list.items.firstIndex(where: { $0.poolID == cleaned.poolID }) {
                list.items[index] = cleaned
            } else {
                list.items.append(cleaned)
            }
            writePreservedList(list, to: poolsFile)
        }
    }

    /// Merges passively observed headers into an existing pool (or creates one)
    /// and resets failure backoff / cooldown timers.
    @discardableResult
    public func mergePassiveUpdate(
        poolID: String,
        provider: AgentProvider,
        accountLabel: String?,
        kind: AgentQuotaPoolKind? = nil,
        windows: [AgentQuotaWindow],
        balances: [AgentQuotaBalance],
        planName: String?,
        isExhausted: Bool,
        now: Date = Date(),
    ) -> PersistedQuotaPool {
        lock.withLock {
            var list = readPreservedList(at: poolsFile) as PreservedList<PersistedQuotaPool>
            let existing = list.items.first { $0.poolID == poolID }
            var mergedWindows = existing?.snapshot.windows ?? []
            for incoming in windows {
                if let index = mergedWindows.firstIndex(where: { $0.id == incoming.id }) {
                    mergedWindows[index] = incoming
                } else {
                    mergedWindows.append(incoming)
                }
            }
            var mergedBalances = existing?.snapshot.balances ?? []
            for incoming in balances {
                if let index = mergedBalances.firstIndex(where: { $0.id == incoming.id }) {
                    mergedBalances[index] = incoming
                } else {
                    mergedBalances.append(incoming)
                }
            }
            let effectiveKind = kind ?? existing?.snapshot.kind ?? (!mergedWindows.isEmpty ? .window : .balance)
            let effectiveStatus: AgentQuotaStatus = isExhausted
                ? .exhausted
                : (mergedWindows.contains { $0.usedPercent >= 100 && $0.id != "overage" } ? .exhausted : .available)
            let snapshot = AgentQuotaSnapshot(
                poolID: poolID,
                provider: provider,
                accountLabel: accountLabel ?? existing?.snapshot.accountLabel,
                kind: effectiveKind,
                source: .passiveHeaders,
                status: effectiveStatus,
                balances: mergedBalances,
                windows: mergedWindows,
                planName: planName ?? existing?.snapshot.planName,
                relayKind: existing?.snapshot.relayKind,
                billingURL: QuotaPoolIdentity.billingURL(for: provider),
                updatedAt: now,
                nextAllowedAt: nil,
                manualDebounceUntil: existing?.snapshot.manualDebounceUntil,
                cooldownUntil: nil,
                circuitBrokenUntil: nil,
                errorSummary: nil,
            )
            let updated = PersistedQuotaPool(
                poolID: poolID,
                endpointKey: existing?.endpointKey,
                snapshot: sanitizeSnapshot(snapshot, secretToScrub: nil),
                lastForegroundFetchAt: existing?.lastForegroundFetchAt,
                lastBackgroundFetchAt: existing?.lastBackgroundFetchAt,
                lastManualRefreshAt: existing?.lastManualRefreshAt,
                consecutiveFailures: 0,
                cooldownUntil: nil,
                circuitBrokenUntil: nil,
            )
            if let index = list.items.firstIndex(where: { $0.poolID == poolID }) {
                list.items[index] = updated
            } else {
                list.items.append(updated)
            }
            writePreservedList(list, to: poolsFile)
            return updated
        }
    }

    public func clearPool(poolID: String) {
        lock.withLock {
            var list = readPreservedList(at: poolsFile) as PreservedList<PersistedQuotaPool>
            list.items.removeAll { $0.poolID == poolID }
            writePreservedList(list, to: poolsFile)
        }
    }

    // MARK: - Relay probe cache (24h TTL)

    public func cachedRelayProbe(for endpointKey: String, now: Date = Date()) -> RelayProbeKind? {
        lock.withLock {
            let list = readPreservedList(at: probesFile) as PreservedList<PersistedRelayProbe>
            guard let entry = list.items.first(where: { $0.endpointKey == endpointKey }) else {
                return nil
            }
            let age = now.timeIntervalSince(entry.probedAt)
            guard age >= 0, age < Self.probeCacheTTL else { return nil }
            return entry.kind
        }
    }

    public func storeRelayProbe(endpointKey: String, kind: RelayProbeKind, now: Date = Date()) {
        lock.withLock {
            var list = readPreservedList(at: probesFile) as PreservedList<PersistedRelayProbe>
            let record = PersistedRelayProbe(endpointKey: endpointKey, kind: kind, probedAt: now)
            if let index = list.items.firstIndex(where: { $0.endpointKey == endpointKey }) {
                list.items[index] = record
            } else {
                list.items.append(record)
            }
            writePreservedList(list, to: probesFile)
        }
    }

    // MARK: - Sanitization

    private func sanitizePool(_ pool: PersistedQuotaPool, secretToScrub: String?) -> PersistedQuotaPool {
        var copy = pool
        copy.snapshot = sanitizeSnapshot(pool.snapshot, secretToScrub: secretToScrub)
        return copy
    }

    public func sanitizeSnapshot(_ snapshot: AgentQuotaSnapshot, secretToScrub: String?) -> AgentQuotaSnapshot {
        var copy = snapshot
        copy.accountLabel = snapshot.accountLabel.map { scrub($0, secret: secretToScrub, limit: 160) }
        copy.planName = snapshot.planName.map { scrub($0, secret: secretToScrub, limit: 120) }
        copy.errorSummary = snapshot.errorSummary.map { scrub($0, secret: secretToScrub, limit: 240) }
        return copy
    }

    private func scrub(_ text: String, secret: String?, limit: Int) -> String {
        var value = text
        if let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), secret.count >= 4 {
            value = value.replacingOccurrences(of: secret, with: LogRedaction.redacted)
        }
        return redaction.text(value, limit: limit)
    }

    // MARK: - Safe PreservedList I/O

    private func readPreservedList<Element: Codable>(at url: URL) -> PreservedList<Element> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PreservedList<Element>()
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return PreservedList<Element>()
        }
        do {
            return try JSONCoding.decode(PreservedList<Element>.self, from: data)
        } catch {
            // Never overwrite an unreadable file with empty data (issue #33).
            UnreadableFile.setAside(url)
            return PreservedList<Element>()
        }
    }

    private func writePreservedList<Element: Codable>(_ list: PreservedList<Element>, to url: URL) {
        do {
            try DataFolder(root: dataRoot.url).makeLevels(to: dataRoot.quota)
            let data = try JSONCoding.encode(list)
            try data.write(to: url, options: .atomic)
        } catch {
            // Cache failure never breaks provider queries or conversations.
        }
    }
}
