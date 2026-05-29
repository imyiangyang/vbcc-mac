//
//  ArkPolisher.swift
//  vbcc-mac
//
//  豆包(ByteDance ARK)实现:OpenAI 兼容 chat/completions + Bearer 认证。
//

import Foundation

nonisolated final class ArkPolisher: TranscriptPolishing {
    struct Message: Codable, Equatable {
        let role: String
        let content: String
    }

    struct ChatRequest: Codable, Equatable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let max_tokens: Int?
    }

    struct Choice: Codable, Equatable {
        let message: Message
    }

    struct ChatResponse: Codable, Equatable {
        let choices: [Choice]
    }

    enum Error: Swift.Error, Equatable {
        case invalidConfiguration
        case unauthorized
        case modelNotFound(String)
        case invalidHTTPStatus(Int)
        case emptyResponse
    }

    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let timeout: TimeInterval
    private let session: URLSession

    init(baseURL: URL, apiKey: String, model: String, timeout: TimeInterval, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.session = session
    }

    func polish(_ text: String, prompt: String) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedModel.isEmpty, !trimmedPrompt.isEmpty else {
            throw Error.invalidConfiguration
        }

        let payload = ChatRequest(
            model: trimmedModel,
            messages: [
                Message(role: "system", content: "\(trimmedPrompt)\n\n\(polishGuardSuffix)"),
                Message(role: "user", content: text)
            ],
            stream: false,
            max_tokens: nil
        )

        let request = try buildRequest(body: try JSONEncoder().encode(payload))
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, model: trimmedModel)

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = decoded.choices.first?.message.content ?? ""
        let polished = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else { throw Error.emptyResponse }
        return polished
    }

    func testConnection() async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedModel.isEmpty else {
            throw Error.invalidConfiguration
        }

        let payload = ChatRequest(
            model: trimmedModel,
            messages: [Message(role: "user", content: "ping")],
            stream: false,
            max_tokens: 1
        )

        let request = try buildRequest(body: try JSONEncoder().encode(payload))
        let (_, response) = try await session.data(for: request)
        try Self.validate(response: response, model: trimmedModel)
    }

    private func buildRequest(body: Data) throws -> URLRequest {
        let normalized = Self.endpointURL(baseURL: baseURL)
        var request = URLRequest(url: normalized)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    /// 规范化 baseURL,去掉尾部 `/`,然后拼 `/chat/completions`。
    static func endpointURL(baseURL: URL) -> URL {
        var raw = baseURL.absoluteString
        while raw.hasSuffix("/") { raw.removeLast() }
        return URL(string: raw + "/chat/completions") ?? baseURL.appendingPathComponent("chat/completions")
    }

    private static func validate(response: URLResponse, model: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if (200...299).contains(http.statusCode) { return }
        switch http.statusCode {
        case 401: throw Error.unauthorized
        case 404: throw Error.modelNotFound(model)
        default:  throw Error.invalidHTTPStatus(http.statusCode)
        }
    }
}
