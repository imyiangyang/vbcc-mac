//
//  OllamaTextPolisher.swift
//  vbcc-mac
//
//  Local Ollama integration for cleaning iOS speech transcripts before injection.
//

import Foundation

nonisolated struct OllamaConfiguration: Equatable {
    var enabled: Bool
    var endpoint: URL
    var model: String
    var prompt: String
    var timeout: TimeInterval
}

nonisolated final class OllamaTextPolisher {
    struct GenerateRequest: Codable, Equatable {
        let model: String
        let prompt: String
        let stream: Bool
    }

    struct GenerateResponse: Codable, Equatable {
        let response: String
    }

    enum Error: Swift.Error, Equatable {
        case invalidConfiguration
        case invalidHTTPStatus(Int)
        case emptyResponse
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func polish(_ text: String, configuration: OllamaConfiguration) async throws -> String {
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = configuration.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !systemPrompt.isEmpty else {
            throw Error.invalidConfiguration
        }

        let requestPayload = GenerateRequest(
            model: model,
            prompt: Self.composePrompt(systemPrompt: systemPrompt, transcript: text),
            stream: false
        )

        var request = URLRequest(url: configuration.endpoint.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestPayload)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Error.invalidHTTPStatus(http.statusCode)
        }

        let payload = try JSONDecoder().decode(GenerateResponse.self, from: data)
        let polished = payload.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else { throw Error.emptyResponse }
        return polished
    }

    private static func composePrompt(systemPrompt: String, transcript: String) -> String {
        """
        \(systemPrompt)

        要处理的语音转写文本如下。只输出调整后的文本，不要解释，不要加引号，不要使用 Markdown 代码块。

        \(transcript)
        """
    }
}
