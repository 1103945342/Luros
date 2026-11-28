import LurosAgent
@testable import LurosAgentWorker
import LurosCore
import LurosProtocol
import Foundation
import KWWKAI
import Testing

@Suite("AccountDesk provider quota integration", .serialized)
struct AccountDeskQuotaTests {
    private final class MockTransport: QuotaHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }

        func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            lock.withLock { calls += 1 }
            let body = """
            {"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "99.00"}]}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [:],
            )!
            return (response, Data(body.utf8))
        }
    }

    @Test
    func `AccountDesk deduplicates shared API keys and cleans cache on sign out`() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("luros-account-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = LurosDataRoot(home: home)

        let sharedKey = "sk-shared-deepseek-key-123456"
        let store = DeliveredCredentialSource([
            CredentialProviderID.deepSeek: OAuthCredentials(access: sharedKey, refresh: "", expires: .max),
            CredentialProviderID.openAICompatible: OAuthCredentials(
                access: sharedKey,
                refresh: "",
                expires: .max,
                extras: ["baseUrl": .string("https://api.deepseek.com")],
            ),
        ])
        let transport = MockTransport()
        let desk = AccountDesk(store: store, quotaTransport: transport)

        let listed = await desk.list(dataRoot: root)
        let deepSeekAccount = try #require(listed.accounts.first { $0.provider == .deepSeek })
        let compatAccount = try #require(listed.accounts.first { $0.provider == .openAICompatible })
        #expect(deepSeekAccount.poolID != nil)
        #expect(deepSeekAccount.poolID == compatAccount.poolID)

        let response = await desk.quotas(AgentProviderQuotaRequest(mode: .attentionGated), dataRoot: root)
        #expect(response.quotas.count == 2)
        #expect(Set(response.quotas.map(\.provider)) == [.deepSeek, .openAICompatible])
        // SingleFlight + shared SHA-256 pool key avoids querying twice concurrently.
        #expect(transport.callCount == 1)

        // Signing out of one keeps the shared pool while the second account still uses that key.
        try await desk.signOut(.openAICompatible, dataRoot: root)
        let cachedAfterFirst = await desk.quotas(AgentProviderQuotaRequest(mode: .cachedOnly), dataRoot: root)
        #expect(cachedAfterFirst.quotas.count == 1)
        #expect(cachedAfterFirst.quotas.first?.balances.first?.remaining == Decimal(string: "99.00"))

        // Signing out of the last account sharing the pool clears its disk entry.
        try await desk.signOut(.deepSeek, dataRoot: root)
        #expect(QuotaCacheStore(dataRoot: root).loadPools().isEmpty)
    }
}
