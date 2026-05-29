//
//  vbcc_macTests.swift
//  vbcc-macTests
//
//  Created by yang on 2026/5/19.
//

import Foundation
import Testing
@testable import vbcc_mac

@Suite(.serialized)
struct vbcc_macTests {

    @MainActor
    @Test func ollamaPolisherSendsGenerateRequestAndReturnsTrimmedResponse() async throws {
        let handler: URLProtocolMock.Handler = { request in
            #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/generate")
            #expect(request.httpMethod == "POST")

            guard let body = request.httpBody ?? request.httpBodyStream?.readAllData() else {
                Issue.record("Request body should be present")
                throw URLError(.badServerResponse)
            }
            let payload = try JSONDecoder().decode(OllamaPolisher.GenerateRequest.self, from: body)

            #expect(payload.model == "qwen3.5:0.8b")
            #expect(payload.think == false)
            #expect(payload.stream == false)
            #expect(payload.system.contains("修正错别字"))
            #expect(payload.prompt.contains("呃今天meetng改到三点"))

            let response = OllamaPolisher.GenerateResponse(response: "\n今天 meeting 改到三点。\n")
            let data = try JSONEncoder().encode(response)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let polisher = OllamaPolisher(
            endpoint: URL(string: "http://127.0.0.1:11434")!,
            model: "qwen3.5:0.8b",
            timeout: 5,
            session: URLProtocolMock.makeSession(handler: handler)
        )
        let output = try await polisher.polish("呃今天meetng改到三点", prompt: "修正错别字，保留中英双语表达。")

        #expect(output == "今天 meeting 改到三点。")
    }

    @MainActor
    @Test func ollamaPolisherRejectsEmptyModelBeforeNetworkCall() async throws {
        let polisher = OllamaPolisher(
            endpoint: URL(string: "http://127.0.0.1:11434")!,
            model: "   ",
            timeout: 5,
            session: URLSession(configuration: .ephemeral)
        )

        await #expect(throws: OllamaPolisher.Error.invalidConfiguration) {
            try await polisher.polish("原文", prompt: "整理文本")
        }
    }

    @MainActor
    @Test func keychainStoreSetGetDeleteRoundTrip() async throws {
        let testAccount = "vbcc.tests.keychain.\(UUID().uuidString)"
        defer { KeychainStore.set(nil, forAccount: testAccount) }

        KeychainStore.set("hello", forAccount: testAccount)
        #expect(KeychainStore.get(forAccount: testAccount) == "hello")

        KeychainStore.set("world", forAccount: testAccount)
        #expect(KeychainStore.get(forAccount: testAccount) == "world")

        KeychainStore.set(nil, forAccount: testAccount)
        #expect(KeychainStore.get(forAccount: testAccount) == nil)
    }

    @MainActor
    @Test func polishPreferencesDefaultsAndProviderPersistence() async throws {
        let suiteName = "vbcc.tests.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = PolishPreferences(defaults: defaults)
        #expect(prefs.isEnabled == false)
        #expect(prefs.providerKind == .ollama)
        #expect(prefs.ollamaEndpoint == "http://127.0.0.1:11434")
        #expect(prefs.ollamaModel == "qwen3.5:0.8b")
        #expect(prefs.arkBaseURL == "https://ark.cn-beijing.volces.com/api/v3")
        #expect(prefs.arkModel == "")
        #expect(prefs.timeout == 5)

        prefs.providerKind = .ark
        prefs.arkBaseURL = "https://example.com/api/v3/"
        prefs.arkModel = "doubao-test"

        let reloaded = PolishPreferences(defaults: defaults)
        #expect(reloaded.providerKind == .ark)
        #expect(reloaded.arkBaseURL == "https://example.com/api/v3/")
        #expect(reloaded.arkModel == "doubao-test")
    }

    @MainActor
    @Test func polishPreferencesReadsLegacyOllamaKeys() async throws {
        let suiteName = "vbcc.tests.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 模拟老用户已存的 Ollama 配置(老键名)
        defaults.set(true, forKey: "vbcc.ollama.enabled")
        defaults.set("http://localhost:11434", forKey: "vbcc.ollama.endpoint")
        defaults.set("custom-model", forKey: "vbcc.ollama.model")
        defaults.set("我的自定义 prompt", forKey: "vbcc.ollama.prompt")
        defaults.set(20.0, forKey: "vbcc.ollama.timeout")

        let prefs = PolishPreferences(defaults: defaults)
        #expect(prefs.isEnabled == true)
        #expect(prefs.providerKind == .ollama)
        #expect(prefs.ollamaEndpoint == "http://localhost:11434")
        #expect(prefs.ollamaModel == "custom-model")
        #expect(prefs.prompt == "我的自定义 prompt")
        #expect(prefs.timeout == 20.0)
    }

    @MainActor
    @Test func polishPreferencesArkConfigRequiresKeychainKey() async throws {
        let suiteName = "vbcc.tests.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let testAccount = "vbcc.tests.ark.key.\(UUID().uuidString)"
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            KeychainStore.set(nil, forAccount: testAccount)
        }

        let prefs = PolishPreferences(defaults: defaults, arkAPIKeyAccount: testAccount)
        prefs.providerKind = .ark
        prefs.arkBaseURL = "https://ark.cn-beijing.volces.com/api/v3"
        prefs.arkModel = "doubao-test"

        #expect(prefs.arkConfig == nil)

        KeychainStore.set("sk-test", forAccount: testAccount)
        let cfg = prefs.arkConfig
        #expect(cfg?.apiKey == "sk-test")
        #expect(cfg?.model == "doubao-test")
        #expect(cfg?.baseURL.absoluteString == "https://ark.cn-beijing.volces.com/api/v3")
        #expect(cfg?.timeout == 5)
    }

    @MainActor
    @Test func arkPolisherSendsBearerAuthAndOpenAICompatibleRequest() async throws {
        let handler: URLProtocolMock.Handler = { request in
            #expect(request.url?.absoluteString == "https://example.com/api/v3/chat/completions")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            guard let body = request.httpBody ?? request.httpBodyStream?.readAllData() else {
                Issue.record("Request body should be present")
                throw URLError(.badServerResponse)
            }
            let payload = try JSONDecoder().decode(ArkPolisher.ChatRequest.self, from: body)

            #expect(payload.model == "doubao-test")
            #expect(payload.stream == false)
            #expect(payload.messages.count == 2)
            #expect(payload.messages[0].role == "system")
            #expect(payload.messages[0].content.contains("整理文本"))
            #expect(payload.messages[0].content.contains("整理后的文本"))  // polishGuardSuffix 片段
            #expect(payload.messages[1].role == "user")
            #expect(payload.messages[1].content == "原文")

            let response = ArkPolisher.ChatResponse(
                choices: [.init(message: .init(role: "assistant", content: "  整理后的内容  "))]
            )
            let data = try JSONEncoder().encode(response)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let polisher = ArkPolisher(
            baseURL: URL(string: "https://example.com/api/v3/")!,  // 末尾 / 应被清掉
            apiKey: "sk-secret",
            model: "doubao-test",
            timeout: 5,
            session: URLProtocolMock.makeSession(handler: handler)
        )

        let output = try await polisher.polish("原文", prompt: "整理文本")
        #expect(output == "整理后的内容")
    }

    @MainActor
    @Test func arkPolisherMaps401ToUnauthorized() async throws {
        let handler: URLProtocolMock.Handler = { request in
            let body = "{\"error\":{\"message\":\"unauthorized\"}}".data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, body)
        }
        let polisher = ArkPolisher(
            baseURL: URL(string: "https://example.com/api/v3")!,
            apiKey: "bad",
            model: "doubao-test",
            timeout: 5,
            session: URLProtocolMock.makeSession(handler: handler)
        )

        await #expect(throws: ArkPolisher.Error.unauthorized) {
            try await polisher.polish("原文", prompt: "整理文本")
        }
    }

    @MainActor
    @Test func arkPolisherMaps404ToModelNotFound() async throws {
        let handler: URLProtocolMock.Handler = { request in
            let body = Data()
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, body)
        }
        let polisher = ArkPolisher(
            baseURL: URL(string: "https://example.com/api/v3")!,
            apiKey: "sk",
            model: "ghost-model",
            timeout: 5,
            session: URLProtocolMock.makeSession(handler: handler)
        )

        await #expect(throws: ArkPolisher.Error.modelNotFound("ghost-model")) {
            try await polisher.polish("原文", prompt: "整理文本")
        }
    }

    @MainActor
    @Test func arkPolisherRejectsEmptyConfigurationBeforeNetwork() async throws {
        let polisher = ArkPolisher(
            baseURL: URL(string: "https://example.com/api/v3")!,
            apiKey: "",
            model: "doubao-test",
            timeout: 5,
            session: URLSession(configuration: .ephemeral)
        )
        await #expect(throws: ArkPolisher.Error.invalidConfiguration) {
            try await polisher.polish("原文", prompt: "整理文本")
        }
    }

}

private final class URLProtocolMock: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?

    static func makeSession(handler: @escaping Handler) -> URLSession {
        Self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolMock.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension InputStream {
    func readAllData() -> Data {
        open()
        defer { close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while hasBytesAvailable {
            let count = read(buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}
