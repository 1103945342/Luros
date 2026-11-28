import LurosAgent
import LurosCore
import LurosProtocol
import Dispatch
import Foundation
import KWWKAI
import os

/// Where a sign-in's events go: the host's task, as `WorkerContext` sends
/// them. A test records them instead.
public struct SignInReporter: Sendable {
    public var emit: @Sendable (TaskID, String, LurosCore.JSONValue?) -> Void
    public var finish: @Sendable (TaskID, TaskState, String?) -> Void

    public init(
        emit: @escaping @Sendable (TaskID, String, LurosCore.JSONValue?) -> Void,
        finish: @escaping @Sendable (TaskID, TaskState, String?) -> Void,
    ) {
        self.emit = emit
        self.finish = finish
    }

    public init(context: WorkerContext) {
        self.init(
            emit: { context.emit($0, $1, $2) },
            finish: { context.finish($0, $1, message: $2) },
        )
    }
}

/// luros-agent's accounts: the `credential-import` instance signs in,
/// lists and signs out here, against the keychain the sessions read.
///
/// A sign-in is kwwk's own flow (`SignInLogin`), run in this process with
/// callbacks that turn what the user must see into task events — a device
/// code, a page to open, the fields of a key — and nothing else. What comes
/// back from the provider, and what the user types, goes into the store and
/// is never emitted or logged. Only the app's explicit configuration editor
/// can read a saved API key back through `apiConfiguration`. One sign-in runs at a time: a new
/// one ends the old one `cancelled` first, so a loopback port is free again.
public actor AccountDesk {
    private let store: any CredentialSource
    private let login: SignInLogin
    private let listener: OAuthLoopbackFactory
    private let timeoutSeconds: Double
    private let verifyKey: @Sendable (AgentProvider, OAuthCredentials, String?) async throws -> Void
    private let quotaTransport: any QuotaHTTPTransport
    private var quotaCoordinators: [URL: QuotaCoordinator] = [:]
    private var keyVerification: (run: SignInRun, task: Task<Void, Error>)?
    private var running: SignInRun?

    public init(
        store: any CredentialSource,
        login: @escaping SignInLogin = KWWKSignIn.login,
        listener: @escaping OAuthLoopbackFactory = AccountDesk.nioListener,
        timeoutSeconds: Double = Double(AgentSignInRequest.timeoutSeconds),
        verifyKey: @escaping @Sendable (AgentProvider, OAuthCredentials, String?) async throws -> Void = ProviderKeyVerification.verify,
        quotaTransport: any QuotaHTTPTransport = URLSessionQuotaTransport.shared,
    ) {
        self.store = store
        self.login = login
        self.listener = listener
        self.timeoutSeconds = timeoutSeconds
        self.verifyKey = verifyKey
        self.quotaTransport = quotaTransport
    }

    /// kwwk's NIO listener with Luros's own pages.
    public static let nioListener: OAuthLoopbackFactory = { host, port, path in
        try OAuthCallbackServer(
            port: port,
            path: path,
            successHTML: PasteableLoopback.successPage,
            errorHTML: PasteableLoopback.errorPage,
            redirectHost: host,
            surfacesProviderErrors: true,
        )
    }

    // MARK: - Accounts

    /// Says in the device log what an account list cost, per account and in
    /// all. Store ids, counts and milliseconds only: never a credential, never
    /// an endpoint's key.
    private static let log = Logger(subsystem: "com.fluoxetine.luros", category: "Accounts")

    /// Whole milliseconds since a `DispatchTime.now().uptimeNanoseconds` stamp.
    static func milliseconds(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }

    /// Every provider, in kwwk's order.
    ///
    /// `onlyExtraModels` is a narrower list for a picker: each signed-in
    /// account answers with the models it was asked for and nothing else, so
    /// the composer does not carry every provider's whole catalogue. What it
    /// was asked for is what it answers — the app's own list is where a live
    /// provider's models come from (WorkBuddy's config, a relay's endpoint),
    /// and those include models no bundled catalog names — so nothing is cut
    /// against a catalog here, and an account asked for no model carries none
    /// and reads no catalog at all: its levels, tiers and capabilities are
    /// trimmed to the models it names, not left holding the whole catalogue's.
    /// Absent or false keeps the whole list, exactly as before, which is what
    /// Settings and onboarding draw.
    public func list(
        extraModels: [String: [String]] = [:],
        onlyExtraModels: Bool = false,
        dataRoot: LurosDataRoot? = nil,
    ) async -> AgentAccountListResponse {
        let started = DispatchTime.now().uptimeNanoseconds
        let stored = await Set(store.providerIds())
        var accounts: [AgentAccount] = []
        accounts.reserveCapacity(AgentProvider.signInOrder.count)
        for listedProvider in AgentProvider.signInOrder {
            for provider in Self.listed(listedProvider, stored: stored) {
                let requested = extraModels[provider.rawValue] ?? []
                let others = Array(provider.signInMethods.dropFirst())
                let ids = Self.accountIDs(of: provider, stored: stored)
                guard !ids.isEmpty else {
                    accounts.append(AgentAccount(
                        provider: provider,
                        method: provider.signInMethod,
                        alternativeMethods: others.isEmpty ? nil : others,
                        signedIn: false,
                        storeID: provider.storeID,
                    ))
                    continue
                }
                // Every account the provider has, its first included: one row
                // each, told apart by the account id (owner, 2026-11-28).
                for id in ids {
                let accountStarted = DispatchTime.now().uptimeNanoseconds
                var account = AgentAccount(
                    provider: provider,
                    method: provider.signInMethod,
                    alternativeMethods: others.isEmpty ? nil : others,
                    signedIn: true,
                    storeID: id,
                )
                // An item that does not decode is still signed in: Sign Out is
                // how it goes away, and the account names no model.
                if let credentials = try? await store.credentials(for: id) {
                    account.account = Self.accountLabel(provider, credentials)
                    account.expiresAt = Self.lapses(credentials)
                    let models = onlyExtraModels
                        ? Self.narrowed(requested)
                        : Self.widened(requested, provider: provider, credentials: credentials)
                    account.models = models
                    // A narrower account with no model leaves the catalogs nothing
                    // to name, and reading them for it costs a file check apiece.
                    // The whole list keeps every field it always carried, empty
                    // model list or not, so nothing else changes for it.
                    if !models.isEmpty || !onlyExtraModels {
                        let facts = ProviderModels.catalogFacts(
                            provider,
                            credentials: credentials,
                            models: models,
                            dataRoot: dataRoot,
                        )
                        let tiers = ProviderModels.serviceTiers(provider, credentials: credentials)
                        if onlyExtraModels {
                            let asked = Set(models)
                            account.reasoningEfforts = facts.reasoningEfforts.filter { asked.contains($0.key) }
                            account.serviceTiers = tiers.filter { asked.contains($0.key) }
                            account.capabilities = facts.capabilities
                        } else {
                            account.reasoningEfforts = facts.reasoningEfforts
                            account.serviceTiers = tiers
                            account.capabilities = facts.capabilities
                        }
                    }
                    let usesAPIKey = ProviderModels.usesAPIKey(provider, credentials: credentials)
                    account.usesAPIKey = usesAPIKey ? true : nil
                    account.poolID = QuotaPoolIdentity.poolID(
                        provider: provider,
                        storeID: id,
                        credentials: credentials,
                        usesAPIKey: usesAPIKey,
                    )
                }
                accounts.append(account)
                Self.log.notice(
                    "listed \(id, privacy: .public) in \(Self.milliseconds(since: accountStarted), privacy: .public) ms, \(account.models?.count ?? 0, privacy: .public) models",
                )
                }
            }
        }
        Self.log.notice(
            "listed \(accounts.count, privacy: .public) providers in \(Self.milliseconds(since: started), privacy: .public) ms, \(onlyExtraModels ? "named" : "all", privacy: .public) models",
        )
        return AgentAccountListResponse(accounts: accounts)
    }

    /// The account ids one provider row stands for: its own when signed in,
    /// then `#2`, `#3` … for the accounts added after it (owner, 2026-11-28).
    static func accountIDs(of provider: AgentProvider, stored: Set<String>) -> [String] {
        var ids: [String] = []
        if stored.contains(provider.storeID) {
            ids.append(provider.storeID)
        }
        for number in 2 ... AccountIDs.maximum where stored.contains(AccountIDs.extra(provider, number)) {
            ids.append(AccountIDs.extra(provider, number))
        }
        return ids
    }

    /// The whole list with the caller's own models added: what every account
    /// list answered before there was a narrower one.
    static func widened(
        _ extraModels: [String],
        provider: AgentProvider,
        credentials: OAuthCredentials,
    ) -> [String] {
        var models = ProviderModels.list(provider, credentials: credentials)
        var known = Set(models)
        for id in extraModels where known.insert(id).inserted {
            models.append(id)
        }
        return models
    }

    /// Only the caller's own models, in its order, once each: what a picker
    /// asks for is what it gets, including a model no bundled catalog knows —
    /// a live provider's own list is the app's to name, not this worker's to
    /// second-guess.
    static func narrowed(_ extraModels: [String]) -> [String] {
        var seen: Set<String> = []
        return extraModels.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// What the list shows for `provider`: itself, and for the
    /// OpenAI-compatible login every endpoint signed in to, in number
    /// order, then one more that is not, so there is always one to add
    /// (#60). The one to add is the first endpoint while that is free,
    /// else the lowest number no endpoint has.
    static func listed(_ provider: AgentProvider, stored: Set<String>) -> [AgentProvider] {
        guard provider == .openAICompatible else { return [provider] }
        let numbers = stored.compactMap(CredentialProviderID.endpointNumber).sorted()
        var endpoints = numbers.map(AgentProvider.openAICompatibleEndpoint)
        if stored.contains(provider.storeID) {
            endpoints.insert(provider, at: 0)
            if let free = AgentProvider.endpointNumbers.first(where: { !numbers.contains($0) }) {
                endpoints.append(.openAICompatibleEndpoint(free))
            }
        } else {
            endpoints.append(provider)
        }
        return endpoints
    }

    /// The explicit app-only editor reads the saved key directly; no task is
    /// created and neither account listings nor sign-in events expose it.
    public func apiConfiguration(
        for provider: AgentProvider,
        accountID: String? = nil,
    ) async throws -> AgentAPIConfigurationResponse {
        let accountID = AccountIDs.resolved(accountID, for: provider)
        guard let credentials = try await store.credentials(for: accountID) else {
            throw LurosError(.notFound, "No saved API configuration was found. Sign in to the provider first.")
        }
        guard ProviderModels.usesAPIKey(provider, credentials: credentials) else {
            throw LurosError(.denied, "This account does not use an editable API key.")
        }
        var values: [String: String] = [:]
        for field in provider.keyFields {
            if field.field == .apiKey {
                values[field.field.rawValue] = credentials.access
            } else if case let .string(value)? = credentials.extras[field.field.rawValue] {
                values[field.field.rawValue] = value
            } else if let value = field.defaultValue {
                values[field.field.rawValue] = value
            }
        }
        return AgentAPIConfigurationResponse(values: values)
    }

    /// Forgets one account, or with no `accountID` every account the provider
    /// has, its first included (owner, 2026-11-28).
    public func signOut(
        _ provider: AgentProvider,
        accountID: String? = nil,
        dataRoot: LurosDataRoot? = nil,
    ) async throws {
        if let accountID, !accountID.isEmpty,
           !AccountIDs.belongs(accountID, to: provider)
        {
            throw LurosError(.badRequest, "\(accountID) is not an account of \(provider.rawValue).")
        }
        let ids = accountID.map { [$0] }
            ?? ([provider.storeID] + (2 ... AccountIDs.maximum).map { AccountIDs.extra(provider, $0) })
        let existingCredentials = try? await store.credentials(for: ids[0])
        for id in ids {
            if (try? await store.credentials(for: id)) == nil { continue }
            do {
                try await store.remove(id)
            } catch {
                throw LurosError(
                    .internal,
                    "Unable to remove the saved sign-in: \(error.localizedDescription). Try again.",
                )
            }
        }
        if let dataRoot, let existingCredentials {
            let usesAPIKey = ProviderModels.usesAPIKey(provider, credentials: existingCredentials)
            let poolID = QuotaPoolIdentity.poolID(
                provider: provider,
                storeID: ids[0],
                credentials: existingCredentials,
                usesAPIKey: usesAPIKey,
            )
            // Keep deduplicated key pool if another signed-in account still shares the same key digest.
            let remainingIDs = await store.providerIds()
            var sharedElsewhere = false
            if poolID.hasPrefix("key:") {
                for otherID in remainingIDs {
                    if let otherCreds = try? await store.credentials(for: otherID),
                       "key:\(QuotaPoolIdentity.keyDigestPrefix16(for: otherCreds.access))" == poolID
                    {
                        sharedElsewhere = true
                        break
                    }
                }
            }
            if !sharedElsewhere {
                QuotaCacheStore(dataRoot: dataRoot).clearPool(poolID: poolID)
            }
        }
    }

    // MARK: - Provider Quota

    private func quotaCoordinator(for dataRoot: LurosDataRoot) -> QuotaCoordinator {
        if let existing = quotaCoordinators[dataRoot.url] {
            return existing
        }
        let coordinator = QuotaCoordinator(
            store: QuotaCacheStore(dataRoot: dataRoot),
            transport: quotaTransport,
        )
        quotaCoordinators[dataRoot.url] = coordinator
        return coordinator
    }

    public func quotas(
        _ request: AgentProviderQuotaRequest,
        dataRoot: LurosDataRoot,
    ) async -> AgentProviderQuotaResponse {
        let stored = await Set(store.providerIds())
        var targets: [(provider: AgentProvider, accountID: String)] = []
        if let single = request.provider {
            targets = Self.accountIDs(of: single, stored: stored).map { (single, $0) }
        } else {
            for listedProvider in AgentProvider.signInOrder {
                for provider in Self.listed(listedProvider, stored: stored) {
                    targets += Self.accountIDs(of: provider, stored: stored).map { (provider, $0) }
                }
            }
        }

        var descriptors: [QuotaAccountDescriptor] = []
        for target in targets {
            let provider = target.provider
            let accountID = target.accountID
            guard var credentials = try? await store.credentials(for: accountID) else { continue }
            let usesAPIKey = ProviderModels.usesAPIKey(provider, credentials: credentials)
            if request.mode != .cachedOnly,
               !usesAPIKey,
               credentials.isExpired,
               !credentials.refresh.isEmpty
            {
                let refreshers: [any OAuthProvider] = if let site = KimiSite.site(id: provider.storeID) {
                    OAuthSubscriptions.refresher(
                        providerId: site.id,
                        kimiIdentity: KimiIdentity.identity(recordedIn: credentials),
                    ).map { [$0] } ?? []
                } else {
                    KimiIdentity.refreshers(for: provider.storeID)
                }
                let manager = OAuthManager(
                    source: store,
                    providers: Self.scoped(refreshers, accountID: accountID, provider: provider),
                )
                if let freshAccess = try? await manager.apiKey(for: accountID), !freshAccess.isEmpty {
                    credentials = (try? await manager.credentials(for: accountID)) ?? credentials
                    credentials.access = freshAccess
                    try? await store.store(credentials, for: accountID)
                }
            }
            descriptors.append(QuotaAccountDescriptor(
                provider: provider,
                storeID: accountID,
                accountLabel: Self.accountLabel(provider, credentials),
                credentials: credentials,
                usesAPIKey: usesAPIKey,
            ))
        }

        let coordinator = quotaCoordinator(for: dataRoot)
        let snapshots = await coordinator.snapshots(
            for: descriptors,
            mode: request.mode,
            foreground: request.foreground,
            force: request.force,
        )
        return AgentProviderQuotaResponse(quotas: snapshots)
    }

    /// A typed key's endpoint host — the one it was given, else its form's
    /// default — which tells two keys apart and is no secret. A
    /// subscription carries no account name kwwk keeps, and a key a browser
    /// sign-in minted (OpenRouter's, Z.ai's) names no endpoint.
    /// The provider's refreshers, answering under the account's own store id
    /// when it is not the provider's first, so a second sign-in of one
    /// provider refreshes through its flow and keeps its own credential
    /// (owner, 2026-11-28).
    static func scoped(
        _ refreshers: [any OAuthProvider],
        accountID: String,
        provider: AgentProvider,
    ) -> [any OAuthProvider] {
        guard accountID != provider.storeID else { return refreshers }
        return refreshers.map { AccountRefresher(base: $0, id: accountID) }
    }

    static func accountLabel(_ provider: AgentProvider, _ credentials: OAuthCredentials) -> String? {
        if case let .string(base)? = credentials.extras[AgentSignInField.baseURL.rawValue] {
            return URLComponents(string: base)?.host
        }
        guard provider.signInMethod == .apiKey,
              let base = provider.keyFields.first(where: { $0.field == .baseURL })?.defaultValue
        else { return nil }
        return URLComponents(string: base)?.host
    }

    /// Only a sign-in that cannot renew itself lapses for the user: a
    /// refresh token renews it, and an API key is stored as never expiring.
    static func lapses(_ credentials: OAuthCredentials) -> Date? {
        guard credentials.refresh.isEmpty, credentials.expires != .max else { return nil }
        return Date(timeIntervalSince1970: Double(credentials.expires) / 1000)
    }

    // MARK: - Signing in

    /// Accepts the task and starts the flow; its events and final `state`
    /// follow the reply. A method the provider does not offer is refused
    /// before anything starts, and the sign-in still running goes on.
    public func start(_ request: AgentSignInRequest, taskID: TaskID, reporter: SignInReporter) async throws {
        let method = request.method ?? request.provider.signInMethod
        guard request.provider.signInMethods.contains(method) else {
            throw LurosError(
                .badRequest,
                "\(request.provider.rawValue) does not support \(method.rawValue) sign-in. Choose another method.",
            )
        }
        let accountID = AccountIDs.resolved(request.accountID, for: request.provider)
        guard AccountIDs.belongs(accountID, to: request.provider) else {
            throw LurosError(
                .badRequest,
                "\(accountID) is not an account of \(request.provider.rawValue).",
            )
        }
        await stopRunning()
        let run = SignInRun(taskID: taskID, provider: request.provider, accountID: accountID, method: method)
        running = run
        run.work = Task { [weak self] in
            await self?.perform(run, reporter: reporter)
        }
    }

    public func cancel(_ taskID: TaskID) -> Bool {
        guard let running, running.taskID == taskID else { return false }
        keyVerification?.task.cancel()
        running.cancel()
        return true
    }

    /// What the user supplied, for the sign-in that asked for it. A value
    /// that will not do is refused naming the field; the flow goes on
    /// waiting for a better one.
    public func respond(_ request: AgentSignInRespondRequest) async throws {
        guard let run = running, run.taskID == request.taskID else {
            throw LurosError(
                .notFound,
                "Sign-in \(request.taskID) is no longer waiting for a response. Start signing in again.",
            )
        }
        var values: [AgentSignInField: String] = [:]
        for (key, value) in request.values {
            guard let field = AgentSignInField(rawValue: key) else {
                throw LurosError(.badRequest, "\(key) is not a sign-in field")
            }
            values[field] = value
        }
        switch run.method {
        case .deviceCode:
            throw LurosError(
                .badRequest,
                "Complete sign-in on the provider’s website. No response is needed in Luros.",
            )
        case .browser:
            guard values.count == 1, let text = values[.callbackURL] else {
                throw LurosError(.badRequest, "a browser sign-in takes only \(AgentSignInField.callbackURL.rawValue)")
            }
            guard let loopback = run.loopback else {
                throw LurosError(.conflict, "\(run.provider.rawValue) is not waiting for a pasted address")
            }
            try loopback.paste(text)
        case .apiKey:
            guard keyVerification == nil else {
                throw LurosError(.conflict, "Provider verification is already running.")
            }
            let accepted = try Self.validated(
                values,
                for: run.provider,
                requiresDefaultModel: request.verifyModel != false,
            )
            guard request.verifyModel != false else {
                try run.deliver(accepted)
                return
            }
            let credentials = Self.apiKeyCredentials(accepted)
            let work = Task { try await verifyKey(run.provider, credentials, nil) }
            keyVerification = (run, work)
            defer {
                if keyVerification?.run === run {
                    keyVerification = nil
                }
            }
            try await work.value
            guard running === run, !run.isCancelled else { throw CancellationError() }
            try run.deliver(accepted)
        }
    }

    /// The models the provider lists and, for an API-key account, the
    /// limits each of them and of `limitsFor` has when the user sets none.
    public func models(
        for provider: AgentProvider,
        accountID: String? = nil,
        limitsFor asked: [String] = [],
    ) async throws -> AgentModelListResponse {
        let accountID = AccountIDs.resolved(accountID, for: provider)
        guard let credentials = try await store.credentials(for: accountID) else {
            throw LurosError(.notFound, "Sign in to the provider first.")
        }
        let models = try await ProviderModels.fetch(provider, credentials: credentials)
        guard ProviderModels.usesAPIKey(provider, credentials: credentials) else {
            return AgentModelListResponse(models: models)
        }
        let limits = await ProviderModels.automaticLimits(
            provider,
            credentials: credentials,
            models: models + asked.prefix(AgentModelListRequest.maximumLimitsAsked),
        )
        return AgentModelListResponse(models: models, limits: limits)
    }

    public func activateModels(
        _ request: AgentModelActivateRequest,
        taskID: TaskID,
        reporter: SignInReporter,
    ) async throws {
        guard !request.models.isEmpty, request.models.count <= 64,
              request.models.allSatisfy({ !$0.isEmpty && $0.count <= 256 && !$0.contains(where: \.isNewline) })
        else { throw LurosError(.badRequest, "Select between 1 and 64 valid model IDs.") }
        let accountID = AccountIDs.resolved(request.accountID, for: request.provider)
        guard let credentials = try await store.credentials(for: accountID) else {
            throw LurosError(.notFound, "Sign in to the provider first.")
        }
        let usesAPIKey = ProviderModels.usesAPIKey(request.provider, credentials: credentials)
        guard usesAPIKey || request.provider == .githubCopilot else {
            throw LurosError(.badRequest, "This OAuth provider does not require model verification.")
        }
        await stopRunning()
        let run = SignInRun(taskID: taskID, provider: request.provider, accountID: accountID, method: .apiKey)
        running = run
        run.work = Task { [weak self, verifyKey] in
            var currentModel = ""
            do {
                for model in request.models {
                    currentModel = model
                    try Task.checkCancellation()
                    if usesAPIKey {
                        try await verifyKey(request.provider, credentials, model)
                    } else {
                        try await KWWKSignIn.enableCopilotModels(credentials, models: [model])
                    }
                    try Task.checkCancellation()
                    reporter.emit(taskID, "modelVerified", .object(["model": .string(model)]))
                }
                reporter.finish(taskID, .succeeded, nil)
            } catch {
                reporter.finish(
                    taskID,
                    run.isCancelled ? .cancelled : .failed,
                    run.isCancelled ? nil : "Unable to verify model \(currentModel). Check the model ID and provider access, then try again.",
                )
            }
            await self?.clear(run)
        }
    }

    private func clear(_ run: SignInRun) {
        if running === run {
            running = nil
        }
    }

    private func stopRunning() async {
        guard let previous = running else { return }
        previous.cancel()
        if let verification = keyVerification {
            verification.task.cancel()
            _ = await verification.task.result
        }
        await previous.work?.value
    }

    /// The key and its extras, each checked on its own and refused by name
    /// alone: an error never quotes what was typed.
    static func validated(
        _ values: [AgentSignInField: String],
        for provider: AgentProvider,
        requiresDefaultModel: Bool = true,
    ) throws -> [AgentSignInField: String] {
        let fields = provider.keyFields
        for field in values.keys where !fields.contains(where: { $0.field == field }) {
            throw LurosError(.badRequest, "\(provider.rawValue) does not ask for \(field.rawValue)")
        }
        var accepted: [AgentSignInField: String] = [:]
        for field in fields {
            let value = (values[field.field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                if field.required, field.field != .defaultModel || requiresDefaultModel {
                    throw LurosError(.badRequest, Self.missing(field.field))
                }
                continue
            }
            switch field.field {
            case .apiKey:
                guard value.count <= 4096, !value.unicodeScalars.contains(where: Self.isSpaceOrControl) else {
                    throw LurosError(.badRequest, "Enter a valid API key without spaces or line breaks.")
                }
            case .baseURL:
                guard value.count <= 2048, let url = URLComponents(string: value),
                      let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                      url.host?.isEmpty == false, url.user == nil, url.password == nil,
                      url.query == nil, url.fragment == nil
                else {
                    throw LurosError(.badRequest, "Enter a valid HTTP or HTTPS address.")
                }
            case .defaultModel:
                guard value.count <= 256, !value.unicodeScalars.contains(where: Self.isSpaceOrControl) else {
                    throw LurosError(.badRequest, "Enter a valid model ID without spaces or line breaks.")
                }
            case .callbackURL:
                throw LurosError(.badRequest, "\(provider.rawValue) does not ask for \(field.field.rawValue)")
            }
            accepted[field.field] = value
        }
        return accepted
    }

    /// The refusal for an empty required field, which names it.
    private static func missing(_ field: AgentSignInField) -> String {
        switch field {
        case .apiKey: "Enter an API key."
        case .baseURL: "Enter the endpoint address."
        case .defaultModel: "Enter a model ID."
        case .callbackURL: "Paste the address the browser opened."
        }
    }

    private static func isSpaceOrControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
    }

    /// kwwk's API-key shape (KWWKCli's `apiKeyCredentials`): the key as
    /// `access`, no refresh token, never expiring, the rest as extras.
    static func apiKeyCredentials(_ values: [AgentSignInField: String]) -> OAuthCredentials {
        var credentials = OAuthCredentials(access: values[.apiKey] ?? "", refresh: "", expires: .max)
        for field in [AgentSignInField.baseURL, .defaultModel] {
            if let value = values[field] {
                credentials.extras[field.rawValue] = .string(value)
            }
        }
        return credentials
    }

    /// What kwwk's login gets beside its callbacks: for Kimi, either site,
    /// the device id that site's stored sign-in recorded, so signing in
    /// again keeps the device Kimi knows (`KimiIdentity`).
    private func options(for run: SignInRun) async -> SignInOptions {
        guard run.provider == .kimiCoding || run.provider == .kimiCodingGlobal else { return SignInOptions() }
        let previous = try? await store.credentials(for: run.accountID)
        return SignInOptions(kimiIdentity: KimiIdentity.identity(recordedIn: previous))
    }

    private func perform(_ run: SignInRun, reporter: SignInReporter) async {
        let taskID = run.taskID
        do {
            let options = await options(for: run)
            // Not named `credentials`: Swift 6.2 reads the call in the closure
            // as the variable it initialises.
            var signedIn = try await Self.withDeadline(timeoutSeconds) { [self] in
                try await credentials(for: run, options: options, reporter: reporter)
            }
            if run.provider == .openRouter, run.method == .apiKey {
                signedIn.extras[ProviderModels.signInMethodExtra] = .string(run.method.rawValue)
            }
            try Task.checkCancellation()
            do {
                try await store.store(signedIn, for: run.accountID)
            } catch {
                // A store error names a status, never the secret.
                throw LurosError(.internal, "Unable to save your sign-in: \(error.localizedDescription). Try again.")
            }
            reporter.finish(taskID, .succeeded, "You are signed in.")
        } catch {
            reporter.finish(taskID, run.isCancelled ? .cancelled : Self.state(of: error), Self.message(error))
        }
        clear(run)
    }

    /// A cancel — the app's, a newer sign-in's, the user's "deny" on the
    /// provider's page — ends `cancelled`; everything else `failed`.
    static func state(of error: Error) -> TaskState {
        switch error {
        case is CancellationError: .cancelled
        case let error as OAuthLoginError where error == .cancelled: .cancelled
        default: .failed
        }
    }

    /// What the user reads: kwwk's own words for what went wrong, cut short
    /// — a provider's error body names the failure, and a failed exchange
    /// has no token to show.
    static func message(_ error: Error) -> String {
        switch error {
        case is CancellationError: return "Sign-in was cancelled."
        case let error as OAuthLoginError where error == .cancelled: return "Sign-in was declined or cancelled."
        case OAuthLoginError.timedOut, SignInDeadline.passed:
            return "Sign-in timed out. Try again."
        case let error as LurosError: return error.message
        default: break
        }
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    private nonisolated func credentials(
        for run: SignInRun,
        options: SignInOptions,
        reporter: SignInReporter,
    ) async throws -> OAuthCredentials {
        let taskID = run.taskID
        switch run.method {
        case .apiKey:
            reporter.emit(taskID, "input", .object(["fields": .array(run.provider.keyFields.map { field in
                var entry: [String: LurosCore.JSONValue] = [
                    "key": .string(field.field.rawValue),
                    "required": .bool(field.required),
                    "secure": .bool(field.secure),
                ]
                if let value = field.defaultValue {
                    entry["defaultValue"] = .string(value)
                }
                if let value = field.placeholder {
                    entry["placeholder"] = .string(value)
                }
                return .object(entry)
            })]))
            return try await Self.apiKeyCredentials(run.waitForKeys())
        case .deviceCode, .browser:
            let listener = listener
            let callbacks = OAuthLogin.Callbacks(
                onDeviceCode: { code in
                    run.announcedDeviceCode()
                    reporter.emit(taskID, "deviceCode", .object([
                        "code": .string(code.code),
                        "verificationURL": .string(code.verificationURL.absoluteString),
                        "pageHoldsCode": .bool(code.pageHoldsCode),
                    ]))
                },
                browser: SignInPresenter(signIn: run, reporter: reporter),
                loopback: { host, port, path in
                    let loopback = try PasteableLoopback(inner: listener(host, port, path))
                    run.loopback = loopback
                    return loopback
                },
            )
            return try await login(run.provider, callbacks, options)
        }
    }

    /// Runs `body` for at most `seconds`; past that it throws
    /// `SignInDeadline.passed`. The clock's child answers whether it fired
    /// (nil), so a clock cancelled because the work ended is never read as
    /// the deadline.
    static func withDeadline<T: Sendable>(
        _ seconds: Double,
        _ body: @escaping @Sendable () async throws -> T,
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            guard let value = first else { throw SignInDeadline.passed }
            return value
        }
    }
}

enum SignInDeadline: Error {
    case passed
}

/// kwwk's page presenter: says what to open, once, and lets the flow's own
/// waiting run. A device flow has said it already, code and page together.
/// A flow that polls the provider (Cursor, Qoder, WorkBuddy, Z.ai) or binds
/// its own listener (Kiro) has no loopback of Luros's, so nothing pasted
/// can stand in for its redirect.
private struct SignInPresenter: OAuthBrowserPresenter {
    let signIn: SignInRun
    let reporter: SignInReporter

    func run<Outcome: Sendable>(
        _ url: URL,
        while work: @escaping @Sendable () async throws -> Outcome,
    ) async throws -> Outcome {
        if !signIn.hasAnnouncedDeviceCode {
            reporter.emit(signIn.taskID, "authorize", .object([
                "url": .string(url.absoluteString),
                "acceptsCallbackURL": .bool(signIn.loopback != nil),
            ]))
        }
        return try await work()
    }
}

/// One sign-in in flight: its flow, the loopback it opened and, for a key,
/// what the user typed once it has been accepted.
final class SignInRun: @unchecked Sendable {
    let taskID: TaskID
    let provider: AgentProvider
    /// The credential's store id: the provider's own for its first account,
    /// `provider#2` and up for the ones added after it (owner, 2026-11-28).
    let accountID: String
    let method: AgentSignInMethod
    var work: Task<Void, Never>?

    private let lock = NSLock()
    private var keyWaiter: CheckedContinuation<[AgentSignInField: String], Error>?
    private var keys: [AgentSignInField: String]?
    @objc private dynamic var cancelled = false
    @objc private dynamic var deviceCode = false
    private var listener: PasteableLoopback?

    init(taskID: TaskID, provider: AgentProvider, accountID: String, method: AgentSignInMethod) {
        self.taskID = taskID
        self.provider = provider
        self.accountID = accountID
        self.method = method
    }

    var loopback: PasteableLoopback? {
        get { lock.withLock { listener } }
        set { lock.withLock { listener = newValue } }
    }

    @objc dynamic var hasAnnouncedDeviceCode: Bool {
        lock.withLock { deviceCode }
    }

    @objc dynamic var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    @objc dynamic func announcedDeviceCode() {
        lock.withLock { deviceCode = true }
    }

    @objc dynamic func cancel() {
        let waiter = lock.withLock { () -> CheckedContinuation<[AgentSignInField: String], Error>? in
            cancelled = true
            defer { keyWaiter = nil }
            return keyWaiter
        }
        waiter?.resume(throwing: CancellationError())
        loopback?.stop()
        work?.cancel()
    }

    /// Hands the accepted key to the flow, once.
    func deliver(_ values: [AgentSignInField: String]) throws {
        let waiter = try lock.withLock { () throws -> CheckedContinuation<[AgentSignInField: String], Error>? in
            guard keys == nil, !cancelled else { throw LurosError(.conflict, "the sign-in has its key already") }
            keys = values
            defer { keyWaiter = nil }
            return keyWaiter
        }
        waiter?.resume(returning: values)
    }

    func waitForKeys() async throws -> [AgentSignInField: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[AgentSignInField: String], Error>) in
                let early = lock.withLock { () -> Result<[AgentSignInField: String], Error>? in
                    if let keys {
                        return .success(keys)
                    }
                    if cancelled || Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    keyWaiter = continuation
                    return nil
                }
                if let early {
                    continuation.resume(with: early)
                }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<[AgentSignInField: String], Error>? in
                defer { keyWaiter = nil }
                return keyWaiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
