import Foundation
import KWWKAI
import LurosProtocol

/// What an account is called on the wire (owner, 2026-11-28): its
/// credential's store id. A provider's first account keeps the store id it
/// always had, so every sign-in made before this still reads back; the ones
/// added after it are `<storeID>#2`, `<storeID>#3`, … in the order they were
/// added, and a number is not reused while that account is signed in.
public enum AccountIDs {
    /// How many accounts of one provider may be signed in at once.
    public static let maximum = AgentAccountID.maximum

    /// The store id an extra account of `provider` uses.
    public static func extra(_ provider: AgentProvider, _ number: Int) -> String {
        AgentAccountID.extra(provider.storeID, number)
    }

    /// The store id an account's credential lives under: `accountID`, or the
    /// provider's own when the caller names none.
    public static func resolved(_ accountID: String?, for provider: AgentProvider) -> String {
        guard let accountID, !accountID.isEmpty else { return provider.storeID }
        return accountID
    }

    /// The number of an extra account (`#2`, `#3`), nil for a first one and
    /// for an id that is not shaped like an account.
    public static func number(of accountID: String) -> Int? {
        AgentAccountID.number(of: accountID)
    }

    /// The provider's own store id an account belongs to: `anthropic#2` is
    /// `anthropic`, and an id with no number is itself.
    public static func base(of accountID: String) -> String {
        AgentAccountID.base(of: accountID)
    }

    /// Whether `accountID` is an account of `provider`, its first included.
    public static func belongs(_ accountID: String, to provider: AgentProvider) -> Bool {
        base(of: accountID) == provider.storeID
    }

    /// The provider an account id belongs to, among the providers this build
    /// knows, its first account included.
    public static func provider(of accountID: String, among providers: [AgentProvider]) -> AgentProvider? {
        let base = base(of: accountID)
        return providers.first { $0.storeID == base }
    }

    /// The next account id a provider can be signed in to, given the ones it
    /// already has: its own first, then the lowest free number.
    public static func next(for provider: AgentProvider, taken: Set<String>) -> String? {
        AgentAccountID.next(base: provider.storeID, taken: taken)
    }
}

/// kwwk's refresher for a provider, answering under an account's own store id
/// (owner, 2026-11-28): the flow is the provider's, the credential is that
/// account's.
public struct AccountRefresher: OAuthProvider {
    public let base: any OAuthProvider
    public let id: String

    public var name: String { base.name }

    public init(base: any OAuthProvider, id: String) {
        self.base = base
        self.id = id
    }

    public func refresh(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials {
        try await base.refresh(credentials, using: client)
    }

    public func apiKey(from credentials: OAuthCredentials, using client: HTTPClient) async throws -> String {
        try await base.apiKey(from: credentials, using: client)
    }
}
