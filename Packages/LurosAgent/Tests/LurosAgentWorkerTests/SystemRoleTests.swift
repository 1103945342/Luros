import LurosAgent
@testable import LurosAgentWorker
import LurosCore
import LurosProtocol
import Foundation
import KWWKAI
import Testing

/// Which role the system prompt goes under on a hand-entered endpoint.
///
/// kwwk writes a reasoning model's system prompt as `developer` whenever it
/// reads an endpoint as standard OpenAI, and DashScope's compatible mode
/// refuses that role ("developer is not one of ['system', 'assistant',
/// 'user', 'tool', 'function']"), so the whole turn failed while the model
/// test — which sends no system prompt — answered normally.
@Suite("System prompt role")
struct SystemRoleTests {
    private func endpoint(_ key: String, _ host: String, _ model: String) -> OAuthCredentials {
        OAuthCredentials(access: key, refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://\(host)/v1"),
            "defaultModel": .string(model),
        ])
    }

    @Test
    func `a hand-entered endpoint speaks the system prompt as system`() async throws {
        let manager = OAuthManager(source: DeliveredCredentialSource([
            "openai-compatible": endpoint("sk-qwen", "dashscope.aliyuncs.com/compatible-mode", "qwen3-max"),
        ]))
        let resolved = try #require(try await ProviderRegistration.resolve(
            storeID: "openai-compatible",
            manager: manager,
        ))
        #expect(resolved.model.compat?.supportsDeveloperRole == false)
    }

    @Test
    func `a login kwwk ships keeps its own choice`() async throws {
        let manager = OAuthManager(source: DeliveredCredentialSource([
            "openai-api-key": endpoint("sk-openai", "api.openai.com", "gpt-5"),
        ]))
        let resolved = try #require(try await ProviderRegistration.resolve(
            storeID: "openai-api-key",
            manager: manager,
        ))
        #expect(resolved.model.compat?.supportsDeveloperRole != false)
    }

    @Test
    func `a compat that states the role is kept`() {
        var stated = ModelCompat()
        stated.supportsDeveloperRole = true
        let model = Model(id: "m", api: "openai-completions", provider: "openai", compat: stated)
        #expect(model.keepingSystemRole.compat?.supportsDeveloperRole == true)

        let silent = Model(id: "m", api: "openai-completions", provider: "openai")
        #expect(silent.keepingSystemRole.compat?.supportsDeveloperRole == false)
    }
}
