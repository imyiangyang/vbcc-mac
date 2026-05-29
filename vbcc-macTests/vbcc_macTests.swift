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
