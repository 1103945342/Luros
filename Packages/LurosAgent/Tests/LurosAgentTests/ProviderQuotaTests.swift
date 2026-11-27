@testable import LurosAgent
import CryptoKit
import Foundation
import KWWKAI
import LurosProtocol
import Testing

@Suite("Provider quota subsystem", .serialized)
struct ProviderQuotaTests {
    // MARK: - Helpers

    private final class StubQuotaTransport: QuotaHTTPTransport, @unchecked Sendable {
        struct Recorded: Sendable {
            var url: URL
            var method: String
            var headers: [String: String]
        }

        private let lock = NSLock()
        private var recorded: [Recorded] = []
        private let responder: @Sendable (URLRequest) async throws -> (Int, [String: String], Data)

        init(_ responder: @escaping @Sendable (URLRequest) async throws -> (Int, [String: String], Data)) {
            self.responder = responder
        }

        var requests: [Recorded] {
            lock.withLock { recorded }
        }

        func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            let entry = Recorded(
                url: request.url!,
                method: request.httpMethod ?? "GET",
                headers: request.allHTTPHeaderFields ?? [:],
            )
            lock.withLock { recorded.append(entry) }
            let (status, headers, body) = try await responder(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers,
            )!
            return (response, body)
        }
    }

    private struct StubKWWKUsage: KWWKQuotaUsageProvider {
        let handler: @Sendable (String, OAuthCredentials) async throws -> [OAuthUsageWindow]?

        func usage(for storeID: String, credentials: OAuthCredentials) async throws -> [OAuthUsageWindow]? {
            try await handler(storeID, credentials)
        }
    }

    private final class MockHTTPClient: HTTPClient, @unchecked Sendable {
        let statusCode: Int
        let headers: [String: String]

        init(statusCode: Int, headers: [String: String]) {
            self.statusCode = statusCode
            self.headers = headers
        }

        func stream(
            url: URL,
            method _: String,
            headers _: [String: String],
            body _: Data?,
            cancellation _: CancellationHandle?,
        ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers,
            )!
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.finish()
            }
            return (response, stream)
        }
    }

    private func makeTempRoot() throws -> LurosDataRoot {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("luros-quota-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return LurosDataRoot(home: home)
    }

    // MARK: - Identity, Decimal & Sanitized Persistence

    @Test
    func `API keys deduplicate by SHA-256 prefix 16 and OAuth uses instance storeID`() {
        let secret = "sk-test-secret-value-12345"
        let expectedHash = SHA256.hash(data: Data(secret.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let prefix16 = String(expectedHash.prefix(16))

        let openAICompat = OAuthCredentials(access: secret, refresh: "", expires: .max)
        let deepSeek = OAuthCredentials(access: secret, refresh: "", expires: .max)
        let id1 = QuotaPoolIdentity.poolID(
            provider: .openAICompatible,
            storeID: CredentialProviderID.openAICompatible,
            credentials: openAICompat,
            usesAPIKey: true,
        )
        let id2 = QuotaPoolIdentity.poolID(
            provider: .deepSeek,
            storeID: CredentialProviderID.deepSeek,
            credentials: deepSeek,
            usesAPIKey: true,
        )
        #expect(id1 == "key:\(prefix16)")
        #expect(id1 == id2)

        let claude = OAuthCredentials(access: "oauth-token-1", refresh: "r", expires: .max)
        let oauthID = QuotaPoolIdentity.poolID(
            provider: .anthropicOAuth,
            storeID: CredentialProviderID.anthropicOAuth,
            credentials: claude,
            usesAPIKey: false,
        )
        #expect(oauthID == "oauth:anthropic")
    }

    @Test
    func `Decimal balances and percentages survive wire encoding without binary float drift`() throws {
        let balance = AgentQuotaBalance(
            id: "USD",
            currency: "USD",
            isAvailable: true,
            total: Decimal(string: "10.30"),
            granted: Decimal(string: "0.10"),
            toppedUp: Decimal(string: "10.20"),
            used: Decimal(string: "0.03"),
            remaining: Decimal(string: "10.27"),
        )
        let window = AgentQuotaWindow(
            id: "fiveHour",
            label: "5-Hour Window",
            usedPercent: Decimal(string: "33.33")!,
        )
        let snapshot = AgentQuotaSnapshot(
            poolID: "key:0123456789abcdef",
            provider: .deepSeek,
            kind: .balance,
            source: .activeAPI,
            status: .available,
            balances: [balance],
            windows: [window],
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AgentQuotaSnapshot.self, from: data)
        #expect(decoded.balances.first?.total == Decimal(string: "10.30"))
        #expect(decoded.balances.first?.granted == Decimal(string: "0.10"))
        #expect(decoded.balances.first?.toppedUp == Decimal(string: "10.20"))
        #expect(decoded.balances.first?.used == Decimal(string: "0.03"))
        #expect(decoded.windows.first?.usedPercent == Decimal(string: "33.33"))
        #expect(decoded.windows.first?.remainingPercent == Decimal(string: "66.67"))
    }

    @Test
    func `Cache store scrubs secrets and isolates unreadable files`() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root.home) }

        let store = QuotaCacheStore(dataRoot: root)
        let secretKey = "sk-super-secret-value-99999"
        let pool = PersistedQuotaPool(
            poolID: "key:1122334455667788",
            endpointKey: "https://api.deepseek.com",
            snapshot: AgentQuotaSnapshot(
                poolID: "key:1122334455667788",
                provider: .deepSeek,
                accountLabel: "api.deepseek.com",
                kind: .balance,
                source: .activeAPI,
                status: .cooldown,
                errorSummary: "Authorization: Bearer \(secretKey) failed",
            ),
        )
        store.upsertPool(pool, secretToScrub: secretKey)

        let diskPath = root.quota.appendingPathComponent("pools.json")
        let diskText = try String(contentsOf: diskPath, encoding: .utf8)
        #expect(!diskText.contains(secretKey))
        #expect(!diskText.contains("Bearer "))

        // Corrupt the cache file and verify it gets moved aside instead of crashing.
        try Data("not-json".utf8).write(to: diskPath)
        #expect(store.loadPools().isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.quota.path)
        #expect(files.contains { $0.hasPrefix("pools.json.unreadable-") })
    }

    // MARK: - Active Adapters

    @Test
    func `DeepSeek splits pools by currency with Decimal precision and is_available`() async throws {
        let transport = StubQuotaTransport { req in
            #expect(req.url?.absoluteString == "https://api.deepseek.com/user/balance")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer ds-secret")
            let body = """
            {
              "is_available": true,
              "balance_infos": [
                {"currency": "CNY", "total_balance": "12.50", "granted_balance": "2.50", "topped_up_balance": "10.00"},
                {"currency": "USD", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00"}
              ]
            }
            """
            return (200, [:], Data(body.utf8))
        }

        let res = try await QuotaAdapters.query(
            provider: .deepSeek,
            poolID: "key:ds",
            accountLabel: "api.deepseek.com",
            credentials: OAuthCredentials(access: "ds-secret", refresh: "", expires: .max),
            usesAPIKey: true,
            cachedRelayProbe: nil,
            transport: transport,
        )
        #expect(res.snapshot.status == .available)
        #expect(res.snapshot.balances.count == 2)
        #expect(res.snapshot.balances[0].currency == "CNY")
        #expect(res.snapshot.balances[0].total == Decimal(string: "12.50"))
        #expect(res.snapshot.balances[0].granted == Decimal(string: "2.50"))
        #expect(res.snapshot.balances[0].toppedUp == Decimal(string: "10.00"))
        #expect(res.snapshot.balances[0].isAvailable == true)
        #expect(res.snapshot.balances[1].currency == "USD")
        #expect(res.snapshot.balances[1].isAvailable == false)
    }

    @Test
    func `Moonshot maps .cn to CNY and .ai to USD`() async throws {
        for (base, expectedCurrency) in [
            ("https://api.moonshot.cn/v1", "CNY"),
            ("https://api.moonshot.ai/v1", "USD"),
        ] {
            let transport = StubQuotaTransport { req in
                #expect(req.url?.absoluteString.hasSuffix("/v1/users/me/balance") == true)
                let body = """
                {"data": {"available_balance": 42.75, "voucher_balance": 2.75, "cash_balance": 40.0}}
                """
                return (200, [:], Data(body.utf8))
            }
            let creds = OAuthCredentials(access: "ms-key", refresh: "", expires: .max, extras: ["baseUrl": .string(base)])
            let res = try await QuotaAdapters.query(
                provider: .openAICompatible,
                poolID: "key:ms",
                accountLabel: nil,
                credentials: creds,
                usesAPIKey: true,
                cachedRelayProbe: nil,
                transport: transport,
            )
            #expect(res.snapshot.balances.first?.currency == expectedCurrency)
            #expect(res.snapshot.balances.first?.remaining == Decimal(string: "42.75"))
        }
    }

    @Test
    func `SiliconFlow reads only balance fields and ignores user PII`() async throws {
        let transport = StubQuotaTransport { req in
            #expect(req.url?.absoluteString == "https://api.siliconflow.cn/v1/user/info")
            let body = """
            {
              "data": {
                "id": "user-999",
                "name": "Private Person",
                "email": "private@example.com",
                "phone": "+8613800138000",
                "balance": "1.25",
                "chargeBalance": "8.75",
                "totalBalance": "10.00"
              }
            }
            """
            return (200, [:], Data(body.utf8))
        }
        let creds = OAuthCredentials(
            access: "sf-key",
            refresh: "",
            expires: .max,
            extras: ["baseUrl": .string("https://api.siliconflow.cn/v1")],
        )
        let res = try await QuotaAdapters.query(
            provider: .openAICompatible,
            poolID: "key:sf",
            accountLabel: "api.siliconflow.cn",
            credentials: creds,
            usesAPIKey: true,
            cachedRelayProbe: nil,
            transport: transport,
        )
        let encoded = String(decoding: try JSONEncoder().encode(res.snapshot), as: UTF8.self)
        #expect(!encoded.contains("Private Person"))
        #expect(!encoded.contains("private@example.com"))
        #expect(!encoded.contains("13800138000"))
        #expect(res.snapshot.balances.first?.currency == "CNY")
        #expect(res.snapshot.balances.first?.remaining == Decimal(string: "10.00"))
    }

    @Test
    func `OpenRouter queries /key and /credits concurrently`() async throws {
        let transport = StubQuotaTransport { req in
            if req.url?.path == "/api/v1/key" {
                let body = """
                {"data": {"limit": 20.0, "limit_remaining": 15.5, "usage": 4.5, "is_free_tier": false}}
                """
                return (200, [:], Data(body.utf8))
            }
            if req.url?.path == "/api/v1/credits" {
                let body = """
                {"data": {"total_credits": 50.0, "total_usage": 12.25}}
                """
                return (200, [:], Data(body.utf8))
            }
            return (404, [:], Data())
        }
        let res = try await QuotaAdapters.query(
            provider: .openRouter,
            poolID: "key:or",
            accountLabel: "openrouter.ai",
            credentials: OAuthCredentials(access: "sk-or-v1-abc", refresh: "", expires: .max),
            usesAPIKey: true,
            cachedRelayProbe: nil,
            transport: transport,
        )
        #expect(transport.requests.count == 2)
        #expect(res.snapshot.balances.count == 2)
        #expect(res.snapshot.balances[0].remaining == Decimal(string: "37.75"))
        #expect(res.snapshot.balances[1].remaining == Decimal(string: "15.5"))
    }

    @Test
    func `Codex OAuth sends codex_cli_rs UA, Originator and ChatGPT-Account-Id`() async throws {
        let transport = StubQuotaTransport { req in
            #expect(req.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
            #expect(req.value(forHTTPHeaderField: "User-Agent") == "codex_cli_rs")
            #expect(req.value(forHTTPHeaderField: "Originator") == "codex_cli_rs")
            #expect(req.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-42")
            let body = """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {"used_percent": 18, "limit_window_seconds": 18000, "reset_at": 1800000000},
                "secondary_window": {"used_percent": 44, "limit_window_seconds": 604800, "reset_at": 1800500000}
              }
            }
            """
            return (200, [:], Data(body.utf8))
        }
        let creds = OAuthCredentials(
            access: "codex-jwt",
            refresh: "r",
            expires: .max,
            extras: ["accountId": .string("acct-42")],
        )
        let res = try await QuotaAdapters.query(
            provider: .openAICodex,
            poolID: "oauth:openai-codex",
            accountLabel: nil,
            credentials: creds,
            usesAPIKey: false,
            cachedRelayProbe: nil,
            transport: transport,
        )
        #expect(res.snapshot.planName == "pro")
        #expect(res.snapshot.windows.count == 2)
        #expect(res.snapshot.windows[0].id == "fiveHour")
        #expect(res.snapshot.windows[0].usedPercent == Decimal(18))
        #expect(res.snapshot.windows[1].id == "sevenDay")
        #expect(res.snapshot.windows[1].usedPercent == Decimal(44))
    }

    @Test
    func `Claude OAuth sends beta and CLI headers and keeps utilization in 0 to 100`() async throws {
        let transport = StubQuotaTransport { req in
            #expect(req.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
            #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
            #expect(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("claude-cli/") == true)
            #expect(req.value(forHTTPHeaderField: "x-app") == "cli")
            // utilization: 1 means 1%, NOT 100%.
            let body = """
            {
              "five_hour": {"utilization": 1, "resets_at": "2026-11-27T18:00:00Z"},
              "seven_day": {"utilization": 37.5, "resets_at": "2026-12-01T00:00:00Z"}
            }
            """
            return (200, [:], Data(body.utf8))
        }
        let res = try await QuotaAdapters.query(
            provider: .anthropicOAuth,
            poolID: "oauth:anthropic",
            accountLabel: nil,
            credentials: OAuthCredentials(access: "claude-tok", refresh: "r", expires: .max),
            usesAPIKey: false,
            cachedRelayProbe: nil,
            transport: transport,
        )
        #expect(res.snapshot.windows.count == 2)
        #expect(res.snapshot.windows[0].usedPercent == Decimal(1))
        #expect(res.snapshot.windows[1].usedPercent == Decimal(string: "37.5"))
    }

    @Test
    func `Kimi Code sends no spoofed User-Agent header`() async throws {
        let transport = StubQuotaTransport { req in
            #expect(req.url?.absoluteString == "https://api.kimi.ai/coding/v1/usages")
            #expect(req.value(forHTTPHeaderField: "User-Agent") == nil)
            let body = """
            {
              "limits": [
                {"window": {"duration": 5, "timeUnit": "HOUR"}, "detail": {"limit": 100, "used": 25, "reset_in": 3600}}
              ]
            }
            """
            return (200, [:], Data(body.utf8))
        }
        let res = try await QuotaAdapters.query(
            provider: .kimiCodingGlobal,
            poolID: "oauth:kimi-coding-ai",
            accountLabel: nil,
            credentials: OAuthCredentials(access: "kimi-tok", refresh: "r", expires: .max),
            usesAPIKey: false,
            cachedRelayProbe: nil,
            transport: transport,
        )
        #expect(res.snapshot.windows.first?.id == "fiveHour")
        #expect(res.snapshot.windows.first?.usedPercent == Decimal(25))
    }

    @Test
    func `Antigravity exposes model and pool windows via kwwk usage reader`() async throws {
        let stubKWWK = StubKWWKUsage { storeID, _ in
            #expect(storeID == "antigravity")
            return [
                OAuthUsageWindow(window: .fiveHour, usedPercent: 42, resetsAt: 1_800_000_000_000, windowSeconds: 18000, limitID: "claude-gpt", limitName: "Claude & GPT"),
                OAuthUsageWindow(window: .fiveHour, usedPercent: 15, resetsAt: 1_800_000_000_000, windowSeconds: 18000, limitID: "gemini", limitName: "Gemini"),
            ]
        }
        let res = try await QuotaAdapters.query(
            provider: .antigravity,
            poolID: "oauth:antigravity",
            accountLabel: nil,
            credentials: OAuthCredentials(access: "ag-tok", refresh: "r", expires: .max),
            usesAPIKey: false,
            cachedRelayProbe: nil,
            transport: StubQuotaTransport { _ in (404, [:], Data()) },
            kwwkUsage: stubKWWK,
        )
        #expect(res.snapshot.kind == .window)
        #expect(res.snapshot.windows.count == 2)
        #expect(res.snapshot.windows[0].usedPercent == Decimal(42))
        #expect(res.snapshot.windows[1].usedPercent == Decimal(15))
    }

    @Test
    func `Custom relay probes Sub2API, New API preserving quota unit, and OpenAI Billing with 1e8 unlimited`() async throws {
        // 1. Sub2API wins first
        let subTransport = StubQuotaTransport { req in
            #expect(req.url?.absoluteString == "https://relay.example.com/v1/usage")
            return (200, [:], Data(#"{"remaining": 8.5, "limit": 10.0, "plan_name": "Pro"}"#.utf8))
        }
        let creds = OAuthCredentials(access: "r-key", refresh: "", expires: .max, extras: ["baseUrl": .string("https://relay.example.com/v1/")])
        let subRes = try await QuotaAdapters.query(
            provider: .openAICompatible,
            poolID: "key:sub",
            accountLabel: "relay.example.com",
            credentials: creds,
            usesAPIKey: true,
            cachedRelayProbe: nil,
            transport: subTransport,
        )
        #expect(subRes.relayProbeKind == .sub2api)
        #expect(subRes.snapshot.balances.first?.remaining == Decimal(string: "8.5"))

        // 2. Falls through Sub2API (404) -> New API (keeps `quota` unit)
        let newApiTransport = StubQuotaTransport { req in
            if req.url?.path == "/v1/usage" { return (404, [:], Data()) }
            if req.url?.path == "/api/usage/token" {
                return (200, [:], Data(#"{"code": true, "data": {"total_available": 500000, "total_used": 125000, "unlimited_quota": false}}"#.utf8))
            }
            return (404, [:], Data())
        }
        let newApiRes = try await QuotaAdapters.query(
            provider: .openAICompatible,
            poolID: "key:newapi",
            accountLabel: "relay.example.com",
            credentials: creds,
            usesAPIKey: true,
            cachedRelayProbe: nil,
            transport: newApiTransport,
        )
        #expect(newApiRes.relayProbeKind == .newapi)
        #expect(newApiRes.snapshot.balances.first?.currency == nil)
        #expect(newApiRes.snapshot.balances.first?.unitLabel == "quota")
        #expect(newApiRes.snapshot.balances.first?.remaining == Decimal(500_000))

        // 3. Falls through to OpenAI Billing (cents -> USD, hard_limit_usd >= 1e8 -> unlimited)
        let billingTransport = StubQuotaTransport { req in
            switch req.url?.path {
            case "/v1/usage", "/api/usage/token":
                return (404, [:], Data())
            case "/v1/dashboard/billing/subscription":
                return (200, [:], Data(#"{"hard_limit_usd": 100000000}"#.utf8))
            case "/v1/dashboard/billing/usage":
                return (200, [:], Data(#"{"total_usage": 1234}"#.utf8))
            default:
                return (404, [:], Data())
            }
        }
        let billingRes = try await QuotaAdapters.query(
            provider: .openAICompatible,
            poolID: "key:oai-bill",
            accountLabel: "relay.example.com",
            credentials: creds,
            usesAPIKey: true,
            cachedRelayProbe: nil,
            transport: billingTransport,
        )
        #expect(billingRes.relayProbeKind == .openAIBilling)
        #expect(billingRes.snapshot.balances.first?.isUnlimited == true)
        #expect(billingRes.snapshot.balances.first?.used == Decimal(string: "12.34"))
    }

    // MARK: - Passive Response Headers

    @Test
    func `Passive Anthropic and Codex headers normalize percentages, handle 429, and reset cooldown`() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root.home) }
        let store = QuotaCacheStore(dataRoot: root)

        // Seed pool in cooldown
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.upsertPool(PersistedQuotaPool(
            poolID: "oauth:anthropic",
            snapshot: AgentQuotaSnapshot(
                poolID: "oauth:anthropic",
                provider: .anthropicOAuth,
                kind: .window,
                source: .activeAPI,
                status: .cooldown,
                cooldownUntil: now.addingTimeInterval(600),
            ),
            consecutiveFailures: 3,
            cooldownUntil: now.addingTimeInterval(600),
        ))

        let client = QuotaHeaderObservingHTTPClient(
            inner: MockHTTPClient(
                statusCode: 429,
                headers: [
                    "anthropic-ratelimit-unified-5h-utilization": "0.85",
                    "anthropic-ratelimit-unified-5h-status": "allowed_warning",
                    "anthropic-ratelimit-unified-7d-utilization": "42", // > 2 -> divide by 100 -> 42%
                    "anthropic-ratelimit-unified-7d-status": "rejected",
                    "anthropic-ratelimit-unified-status": "rejected",
                ],
            ),
            storeID: CredentialProviderID.anthropicOAuth,
            store: store,
        )
        _ = try await client.stream(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            method: "POST",
            headers: [:],
            body: nil,
            cancellation: nil,
        )
        // Wait briefly for detached non-blocking merge task
        for _ in 0 ..< 100 {
            if store.pool(for: "oauth:anthropic")?.snapshot.source == .passiveHeaders {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let updated = try #require(store.pool(for: "oauth:anthropic"))
        #expect(updated.consecutiveFailures == 0)
        #expect(updated.cooldownUntil == nil)
        #expect(updated.snapshot.source == .passiveHeaders)
        #expect(updated.snapshot.status == .exhausted)
        #expect(updated.snapshot.windows.first(where: { $0.id == "fiveHour" })?.usedPercent == Decimal(85))
        #expect(updated.snapshot.windows.first(where: { $0.id == "sevenDay" })?.usedPercent == Decimal(42))

        // Codex x-codex-* parsing
        let codexObs = PassiveQuotaHeaderParser.parse(
            storeID: "openai-codex",
            statusCode: 200,
            headers: [
                "x-codex-primary-used-percent": "27.5",
                "x-codex-primary-window-minutes": "300",
                "x-codex-primary-reset-after-seconds": "1200",
                "x-codex-plan-type": "plus",
                "x-codex-credits-has-credits": "true",
                "x-codex-credits-balance": "14.20",
            ],
            now: now,
        )
        #expect(codexObs?.planName == "plus")
        #expect(codexObs?.windows.first?.id == "fiveHour")
        #expect(codexObs?.windows.first?.usedPercent == Decimal(string: "27.5"))
        #expect(codexObs?.balances.first?.remaining == Decimal(string: "14.20"))
    }

    // MARK: - SingleFlight, Attention Gating, Debounce & 24h Circuit Breaker

    @Test
    func `Coordinator deduplicates concurrent SingleFlight calls and enforces gating, debounce and 24h circuit breaker`() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root.home) }
        let store = QuotaCacheStore(dataRoot: root)

        let clockBox = LockedDate(Date(timeIntervalSince1970: 1_800_000_000))
        let counter = LockedCounter()

        let transport = StubQuotaTransport { req in
            counter.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            if req.url?.host == "dead.relay.example" {
                return (404, [:], Data())
            }
            return (200, [:], Data(#"{"is_available": true, "balance_infos": [{"currency": "USD", "total_balance": "5.00"}]}"#.utf8))
        }

        let coordinator = QuotaCoordinator(store: store, transport: transport, clock: { clockBox.now })
        let account = QuotaAccountDescriptor(
            provider: .deepSeek,
            storeID: CredentialProviderID.deepSeek,
            accountLabel: "api.deepseek.com",
            credentials: OAuthCredentials(access: "ds-1", refresh: "", expires: .max),
            usesAPIKey: true,
        )

        // Concurrent calls -> 1 network request (SingleFlight)
        async let a = coordinator.snapshot(for: account, mode: .attentionGated, foreground: true, force: false)
        async let b = coordinator.snapshot(for: account, mode: .attentionGated, foreground: true, force: false)
        _ = await (a, b)
        #expect(counter.value == 1)

        // 5m later in foreground -> ordinary 10m gate prevents refetch
        clockBox.advance(by: 5 * 60)
        _ = await coordinator.snapshot(for: account, mode: .attentionGated, foreground: true, force: false)
        #expect(counter.value == 1)

        // Manual refresh -> succeeds, then 10s later is debounced (30s manual debounce)
        _ = await coordinator.snapshot(for: account, mode: .manualRefresh, foreground: true, force: false)
        #expect(counter.value == 2)
        clockBox.advance(by: 10)
        _ = await coordinator.snapshot(for: account, mode: .manualRefresh, foreground: true, force: false)
        #expect(counter.value == 2)

        // 404 on unsupported relay trips 24h circuit breaker
        let deadAccount = QuotaAccountDescriptor(
            provider: .openAICompatible,
            storeID: CredentialProviderID.openAICompatible,
            accountLabel: "dead.relay.example",
            credentials: OAuthCredentials(access: "k", refresh: "", expires: .max, extras: ["baseUrl": .string("https://dead.relay.example")]),
            usesAPIKey: true,
        )
        let deadSnap = await coordinator.snapshot(for: deadAccount, mode: .attentionGated, foreground: true, force: false)
        #expect(deadSnap.status == .circuitBroken)
        let countAfterTrip = counter.value
        clockBox.advance(by: 12 * 3600) // Still within 24h
        _ = await coordinator.snapshot(for: deadAccount, mode: .attentionGated, foreground: true, force: false)
        #expect(counter.value == countAfterTrip)
    }

    private final class LockedDate: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var now: Date { lock.withLock { date } }
        func advance(by seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }
}
