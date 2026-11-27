import Foundation
import KWWKAI

/// Non-blocking `HTTPClient` wrapper that extracts rate-limit headers from
/// Anthropic/Codex OAuth HTTP responses (including 429) and merges them into
/// the shared `QuotaCacheStore` while resetting cooldown/backoff.
public final class QuotaHeaderObservingHTTPClient: HTTPClient, @unchecked Sendable {
    public let inner: any HTTPClient
    public let storeID: String
    public let store: QuotaCacheStore

    public init(inner: any HTTPClient = URLSessionHTTPClient.shared, storeID: String, store: QuotaCacheStore) {
        self.inner = inner
        self.storeID = storeID
        self.store = store
    }

    public func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?,
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let result = try await inner.stream(
            url: url,
            method: method,
            headers: headers,
            body: body,
            cancellation: cancellation,
        )
        observeNonBlocking(response: result.0)
        return result
    }

    public func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?,
        timeoutSeconds: TimeInterval,
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let result = try await inner.stream(
            url: url,
            method: method,
            headers: headers,
            body: body,
            cancellation: cancellation,
            timeoutSeconds: timeoutSeconds,
        )
        observeNonBlocking(response: result.0)
        return result
    }

    @objc private dynamic func observeNonBlocking(response: HTTPURLResponse) {
        let extracted = PassiveQuotaHeaderParser.lowercasedHeaders(from: response)
        guard !extracted.isEmpty else { return }
        let statusCode = response.statusCode
        let storeID = storeID
        let store = store
        Task.detached(priority: .utility) {
            let now = Date()
            guard let observation = PassiveQuotaHeaderParser.parse(
                storeID: storeID,
                statusCode: statusCode,
                headers: extracted,
                now: now,
            ) else { return }
            store.mergePassiveUpdate(
                poolID: "oauth:\(observation.storeID)",
                provider: observation.provider,
                accountLabel: nil,
                windows: observation.windows,
                balances: observation.balances,
                planName: observation.planName,
                isExhausted: observation.isExhausted,
                now: now,
            )
        }
    }
}
