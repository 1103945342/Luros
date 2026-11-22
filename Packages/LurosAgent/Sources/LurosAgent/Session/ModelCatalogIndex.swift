import LurosCore
import LurosProtocol
import Dispatch
import Foundation
import KWWKAI
import os

/// The catalogs Luros reads a model against, and the one lookup that answers
/// what a model is.
///
/// Two copies are read: the catalog kwwk ships (which describes the models of
/// the providers it signs in to) and models.dev's, trimmed to the fields a
/// conversation uses and kept on the device (`ModelDataSnapshot`). A provider's
/// own copy is asked first — `deepseek`'s entry for `deepseek-v4.1-flash`
/// before the same name under a reseller — and then every copy of every
/// provider, so a relay's model is read as itself even when the relay is not
/// one the catalog keys.
public struct ModelCatalogIndex: Sendable {
    /// One model as a catalog lists it.
    public struct Entry: Sendable, Hashable {
        /// The model's name in the catalog.
        public var id: String
        /// The provider the catalog files it under.
        public var provider: String
        /// Its display name.
        public var name: String
        /// Tokens a conversation may take.
        public var contextWindow: Int
        /// The most a reply may be.
        public var maxTokens: Int
        /// Whether it takes images.
        public var acceptsImages: Bool
        /// Whether it thinks before it answers.
        public var reasoning: Bool
        /// The levels it takes, in the catalog's own words (`low`, `high`).
        public var efforts: [String]
        /// What each level is called on the wire. Absent leaves the provider's
        /// own defaults.
        public var thinkingLevelMap: [String: String?]?
        /// Read from models.dev's copy rather than the one kwwk ships.
        public var fromSnapshot: Bool

        /// The catalog to name on screen.
        public var source: String { fromSnapshot ? "models.dev" : "catalog" }
    }

    /// What this index reads. Built once and shared; one that is rebuilt (the
    /// app wrote a newer copy, or deleted it) replaces the other.
    private static let shared = SharedIndex()

    public init() {}

    /// The entry for a model, or nil when no catalog knows it.
    ///
    /// `catalogKey` is the provider key to ask first — kwwk's own
    /// (`deepseek`, `anthropic`, `openai`), or nil for an endpoint the
    /// catalogs do not key, which is read from every provider's copy.
    ///
    /// A name is tried as a model id first, then as the name a catalog gives
    /// the model it files differently: `deepseek-flash` is what kwwk calls the
    /// model it names "DeepSeek V4.1 Flash", so a relay serving
    /// `cn:deepseek-v4.1-flash` finds it through that name and no other way.
    public func entry(for id: String, catalogKey: String? = nil) -> Entry? {
        Self.entry(
            for: id,
            catalogKey: catalogKey,
            bundled: Self.shared.bundled,
            snapshot: Self.shared.snapshot(),
        )
    }

    /// The lookup over two tables, so the rules are read without a device's
    /// files behind them.
    static func entry(for id: String, catalogKey: String?, bundled: Table, snapshot: Table) -> Entry? {
        let candidates = ModelIdentity.candidates(id)
        guard !candidates.isEmpty else { return nil }
        if let key = catalogKey?.lowercased(), !key.isEmpty {
            if let entry = best(in: bundled.byProvider[key] ?? [:], for: candidates)
                ?? bestByName(in: bundled.byProviderName[key] ?? [:], for: candidates)
                ?? best(in: snapshot.byProvider[key] ?? [:], for: candidates)
                ?? bestByName(in: snapshot.byProviderName[key] ?? [:], for: candidates) {
                return entry
            }
        }
        if let entry = best(in: bundled.byID, for: candidates)
            ?? bestByName(in: bundled.byName, for: candidates) {
            return entry
        }
        return best(in: snapshot.byID, for: candidates)
            ?? bestByName(in: snapshot.byName, for: candidates)
    }

    /// The entries of several models at once, over one read of each table.
    ///
    /// Each model is read exactly as `entry(for:catalogKey:)` reads it — a
    /// provider's own catalog first (its bundled copy, then models.dev's),
    /// then every copy of every provider — so a batch and a single lookup can
    /// never disagree. What a batch saves is the work around the rules: the
    /// file check behind models.dev's copy, and the walk over the tables, once
    /// for the whole list instead of once per model.
    public func entries(for ids: [String], catalogKey: String? = nil) -> [String: Entry] {
        Self.entries(
            for: ids,
            catalogKey: catalogKey,
            bundled: Self.shared.bundled,
            snapshot: Self.shared.snapshot(),
        )
    }

    /// The same batch over two tables, so the rules are read without a
    /// device's files behind them.
    static func entries(
        for ids: [String],
        catalogKey: String?,
        bundled: Table,
        snapshot: Table,
    ) -> [String: Entry] {
        var found: [String: Entry] = [:]
        for id in ids where found[id] == nil {
            if let entry = entry(for: id, catalogKey: catalogKey, bundled: bundled, snapshot: snapshot) {
                found[id] = entry
            }
        }
        return found
    }

    /// Every model a catalog keys under `catalogKey`, as that catalog names
    /// them the provider's own list does not.
    public func entries(catalogKey: String) -> [Entry] {
        let key = catalogKey.lowercased()
        let bundled = Self.shared.bundled.byProvider[key] ?? [:]
        return bundled.values.sorted { $0.id < $1.id }
    }

    /// The levels each of several models is offered, from the first copy that
    /// names any.
    ///
    /// A name is read exactly as `entry(for:catalogKey:)` reads it — the
    /// provider's own copy first, then every copy of every provider — and a
    /// copy that says a model reasons without saying at which levels is
    /// stepped over instead of answering with nothing. kwwk's catalog names an
    /// OpenAI model and no level for it; models.dev's copy of the same name
    /// names the levels, and they are the whole answer a relay's
    /// `gpt-6.2-astra` has.
    public func reasoningEfforts(for ids: [String], catalogKey: String? = nil) -> [String: [AgentReasoningEffort]] {
        Self.reasoningEfforts(
            for: ids,
            catalogKey: catalogKey,
            bundled: Self.shared.bundled,
            snapshot: Self.shared.snapshot(),
        )
    }

    public func reasoningEfforts(for id: String, catalogKey: String? = nil) -> [AgentReasoningEffort] {
        reasoningEfforts(for: [id], catalogKey: catalogKey)[id] ?? []
    }

    /// The same batch over two tables, so the rules are read without a
    /// device's files behind them.
    static func reasoningEfforts(
        for ids: [String],
        catalogKey: String?,
        bundled: Table,
        snapshot: Table,
    ) -> [String: [AgentReasoningEffort]] {
        var found: [String: [AgentReasoningEffort]] = [:]
        for id in ids where found[id] == nil {
            let candidates = ModelIdentity.candidates(id)
            guard !candidates.isEmpty else { continue }
            let levels = levels(for: candidates, catalogKey: catalogKey, bundled: bundled, snapshot: snapshot)
            guard !levels.isEmpty else { continue }
            found[id] = levels
        }
        return found
    }

    /// One name's levels, the provider's own copy asked first: the first copy
    /// of it that names any answers, and `[]` when none does.
    private static func levels(
        for candidates: [String],
        catalogKey: String?,
        bundled: Table,
        snapshot: Table,
    ) -> [AgentReasoningEffort] {
        let namesAny: (Entry) -> Bool = { !$0.reasoningEfforts.isEmpty }
        var copies: [[AgentReasoningEffort]] = []
        if let key = catalogKey?.lowercased(), !key.isEmpty {
            copies.append(answer(best(in: bundled.byProvider[key] ?? [:], for: candidates, where: namesAny)))
            copies.append(answer(bestByName(in: bundled.byProviderName[key] ?? [:], for: candidates, where: namesAny)))
            copies.append(answer(best(in: snapshot.byProvider[key] ?? [:], for: candidates, where: namesAny)))
            copies.append(answer(bestByName(in: snapshot.byProviderName[key] ?? [:], for: candidates, where: namesAny)))
        }
        copies.append(answer(best(in: bundled.byID, for: candidates, where: namesAny)))
        copies.append(answer(bestByName(in: bundled.byName, for: candidates, where: namesAny)))
        copies.append(answer(best(in: snapshot.byID, for: candidates, where: namesAny)))
        copies.append(answer(bestByName(in: snapshot.byName, for: candidates, where: namesAny)))
        for copy in copies where !copy.isEmpty {
            return copy
        }
        return []
    }

    private static func answer(_ entry: Entry?) -> [AgentReasoningEffort] {
        entry?.reasoningEfforts ?? []
    }

    // MARK: - Lookup

    /// The first candidate that answers, longest stretch of it first.
    private static func best(
        in rows: [String: Entry],
        for candidates: [String],
        where matches: (Entry) -> Bool = { _ in true },
    ) -> Entry? {
        for candidate in candidates {
            for stretch in ModelIdentity.stretches(candidate) {
                if let entry = rows[stretch], matches(entry) { return entry }
            }
        }
        return nil
    }

    /// The best of several providers' copies of one name: the provider the name
    /// itself mentions (`deepseek-v4.1-flash` is DeepSeek's), then the first by
    /// provider key, so the choice never depends on a dictionary's order.
    private static func best(
        in rows: [String: [Entry]],
        for candidates: [String],
        where matches: (Entry) -> Bool = { _ in true },
    ) -> Entry? {
        for candidate in candidates {
            for stretch in ModelIdentity.stretches(candidate) {
                if let entries = rows[stretch], let entry = entries.first(where: matches) { return entry }
            }
        }
        return nil
    }

    /// The one entry a provider files under a name, read the same way as an id.
    private static func bestByName(
        in rows: [String: Entry],
        for candidates: [String],
        where matches: (Entry) -> Bool = { _ in true },
    ) -> Entry? {
        for candidate in candidates {
            for stretch in ModelIdentity.stretches(ModelIdentity.normalized(candidate)) {
                if let entry = rows[stretch], matches(entry) { return entry }
            }
        }
        return nil
    }

    /// The best of several providers' copies of one name.
    private static func bestByName(
        in rows: [String: [Entry]],
        for candidates: [String],
        where matches: (Entry) -> Bool = { _ in true },
    ) -> Entry? {
        for candidate in candidates {
            for stretch in ModelIdentity.stretches(ModelIdentity.normalized(candidate)) {
                if let entries = rows[stretch], let entry = entries.first(where: matches) { return entry }
            }
        }
        return nil
    }

    // MARK: - The tables

    struct Table: Sendable {
        /// Provider key → lowercased model id → entry.
        var byProvider: [String: [String: Entry]] = [:]
        /// Lowercased model id → every provider's entry, best first.
        var byID: [String: [Entry]] = [:]
        /// Provider key → normalized display name → entry, for the models a
        /// catalog files under an id of its own.
        var byProviderName: [String: [String: Entry]] = [:]
        /// Normalized display name → every provider's entry, best first.
        var byName: [String: [Entry]] = [:]

        /// Files each entry under its name, once, with every provider's copies
        /// of a name ordered: the provider the name mentions first, then by
        /// provider key.
        mutating func indexByID() {
            var byID: [String: [Entry]] = [:]
            var byName: [String: [Entry]] = [:]
            for (_, rows) in byProvider {
                for (key, entry) in rows {
                    byID[key, default: []].append(entry)
                    let name = ModelIdentity.normalized(entry.name)
                    if name.count >= ModelIdentity.minimumLength {
                        byName[name, default: []].append(entry)
                    }
                }
            }
            for key in byID.keys {
                byID[key]?.sort { left, right in
                    let named = key.contains(left.provider.lowercased())
                    let otherNamed = key.contains(right.provider.lowercased())
                    if named != otherNamed { return named }
                    return left.provider < right.provider
                }
            }
            for key in byName.keys {
                byName[key]?.sort { left, right in
                    let named = key.contains(left.provider.lowercased())
                    let otherNamed = key.contains(right.provider.lowercased())
                    if named != otherNamed { return named }
                    return left.provider < right.provider
                }
            }
            self.byID = byID
            self.byName = byName
        }
    }

    /// Builds the table over whatever a caller hands it, so the same rules file
    /// kwwk's catalog and models.dev's copy alike.
    static func table(_ providers: [(provider: String, models: [(id: String, entry: Entry)])]) -> Table {
        var table = Table()
        for row in providers {
            var rows: [String: Entry] = [:]
            var names: [String: Entry] = [:]
            let provider = row.provider.lowercased()
            for model in row.models {
                rows[model.id.lowercased()] = model.entry
                // One name per provider: the first of two models calling
                // themselves DeepSeek V4.1 Flash is the one a relay means.
                let name = ModelIdentity.normalized(model.entry.name)
                if name.count >= ModelIdentity.minimumLength, names[name] == nil {
                    names[name] = model.entry
                }
            }
            if !rows.isEmpty {
                table.byProvider[provider] = rows
                table.byProviderName[provider] = names
            }
        }
        table.indexByID()
        return table
    }

    /// kwwk's bundled catalog, as entries.
    static func bundledTable() -> Table {
        var providers: [(provider: String, models: [(id: String, entry: Entry)])] = []
        for provider in ModelsCatalog.providers {
            let models = ModelsCatalog.models(for: provider).map { model in
                (id: model.id, entry: entry(for: model, provider: provider))
            }
            providers.append((provider: provider, models: models))
        }
        return table(providers)
    }

    private static func entry(for model: Model, provider: String) -> Entry {
        Entry(
            id: model.id,
            provider: provider,
            name: model.name,
            contextWindow: model.contextWindow,
            maxTokens: model.maxTokens,
            acceptsImages: model.input.contains(.image),
            reasoning: model.reasoning,
            efforts: supportedThinkingLevels(model).map(\.rawValue),
            thinkingLevelMap: model.thinkingLevelMap,
            fromSnapshot: false,
        )
    }

    /// models.dev's copy, as entries.
    static func snapshotTable(_ snapshot: ModelDataSnapshot) -> Table {
        var providers: [(provider: String, models: [(id: String, entry: Entry)])] = []
        for (provider, models) in snapshot.models {
            let rows = models.map { id, model in
                (id: id, entry: Entry(
                    id: id,
                    provider: provider,
                    name: model.name ?? id,
                    contextWindow: model.context ?? 0,
                    maxTokens: model.output ?? 0,
                    acceptsImages: (model.input ?? []).contains { $0.lowercased() == "image" },
                    reasoning: model.reasoning ?? false,
                    efforts: model.efforts ?? [],
                    thinkingLevelMap: nil,
                    fromSnapshot: true,
                ))
            }
            providers.append((provider: provider, models: rows))
        }
        return table(providers)
    }
}

// MARK: - The shared copy

/// The bundled table and the one read from `ModelData/models.json`, held
/// together so a lookup allocates nothing but its candidates.
private final class SharedIndex: @unchecked Sendable {
    /// Says in the device log how long a catalogue costs to build. The names
    /// are the whole content: no model, no account, no secret.
    private static let log = Logger(subsystem: "com.fluoxetine.luros", category: "ModelCatalog")

    /// kwwk's catalog: a constant of the build, read once.
    let bundled: ModelCatalogIndex.Table

    private let lock = NSLock()
    private var signature: String?
    private var table = ModelCatalogIndex.Table()

    /// Whole milliseconds since a `DispatchTime.now().uptimeNanoseconds` stamp.
    static func milliseconds(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }

    init() {
        let start = DispatchTime.now().uptimeNanoseconds
        let built = ModelCatalogIndex.bundledTable()
        bundled = built
        Self.log.notice(
            "built kwwk's catalog in \(Self.milliseconds(since: start), privacy: .public) ms, \(built.byProvider.count, privacy: .public) providers, \(built.byID.count, privacy: .public) models",
        )
    }

    /// models.dev's copy at `ModelData/models.json`, re-read only when the file
    /// it was read from changed. A file that does not read is no copy at all:
    /// a conversation falls back to the catalog kwwk ships rather than fail.
    func snapshot() -> ModelCatalogIndex.Table {
        let url = LurosDataRoot.current.modelDataFile
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let signature = [
            String(attributes?[.size] as? Int ?? -1),
            String((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1),
        ].joined(separator: "-")
        lock.lock()
        defer { lock.unlock() }
        if signature == self.signature {
            return table
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let read = ModelDataSnapshot.read(url)
        let built = read.map(ModelCatalogIndex.snapshotTable) ?? ModelCatalogIndex.Table()
        let elapsed = Self.milliseconds(since: start)
        self.signature = signature
        self.table = built
        Self.log.notice(
            "built models.dev's catalog in \(elapsed, privacy: .public) ms, \(built.byProvider.count, privacy: .public) providers, \(built.byID.count, privacy: .public) models, \(read == nil ? 0 : 1, privacy: .public) file",
        )
        return built
    }
}
