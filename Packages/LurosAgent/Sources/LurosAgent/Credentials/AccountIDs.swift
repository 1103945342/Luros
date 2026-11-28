import Foundation
import LurosProtocol

/// What an account is called on the wire (owner, 2026-11-28): its
/// credential's store id. A provider's first account keeps the store id it
/// always had, so every sign-in made before this still reads back; the ones
/// added after it are `<storeID>#2`, `<storeID>#3`, … in the order they were
/// added, and a number is not reused while that account is signed in.
public enum AccountIDs {
    public static let separator = "#"
    /// How many accounts of one provider may be signed in at once.
    public static let maximum = 9

    /// The store id an extra account of `provider` uses.
    public static func extra(_ provider: AgentProvider, _ number: Int) -> String {
        "\(provider.storeID)\(separator)\(number)"
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
        guard let index = accountID.lastIndex(of: Character(separator)) else { return nil }
        let suffix = accountID[accountID.index(after: index)...]
        guard let number = Int(suffix), (2 ... maximum).contains(number) else { return nil }
        return number
    }

    /// The provider's own store id an account belongs to: `anthropic#2` is
    /// `anthropic`, and an id with no number is itself.
    public static func base(of accountID: String) -> String {
        guard let number = number(of: accountID) else { return accountID }
        return String(accountID.dropLast(String(separator).count + String(number).count))
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
        guard taken.contains(provider.storeID) else { return provider.storeID }
        return (2 ... maximum).lazy
            .map { extra(provider, $0) }
            .first { !taken.contains($0) }
    }
}
