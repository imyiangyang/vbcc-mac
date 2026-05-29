//
//  OllamaPolisher.swift
//  vbcc-mac
//
//  Ollama `/api/generate` 实现,无状态,接收连接参数构造。
//

import Foundation

nonisolated final class OllamaPolisher: TranscriptPolishing {
    struct GenerateRequest: Codable, Equatable {
        let model: String
        let system: String
        let prompt: String
        let think: Bool
        let stream: Bool
    }

    struct GenerateResponse: Codable, Equatable {
        let response: String
    }

    enum Error: Swift.Error, Equatable {
        case invalidConfiguration
        case invalidHTTPStatus(Int)
        case emptyResponse
        case modelNotFound(String)
    }

    private let endpoint: URL
    private let model: String
    private let timeout: TimeInterval
    private let session: URLSession

    init(endpoint: URL, model: String, timeout: TimeInterval, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.model = model
        self.timeout = timeout
        self.session = session
    }

    func polish(_ text: String, prompt: String) async throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty, !trimmedPrompt.isEmpty else {
            throw Error.invalidConfiguration
        }

        let payload = GenerateRequest(
            model: trimmedModel,
            system: "\(trimmedPrompt)\n\n\(polishGuardSuffix)",
            prompt: text,
            think: false,
            stream: false
        )

        var request = URLRequest(url: endpoint.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Error.invalidHTTPStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        let polished = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else { throw Error.emptyResponse }
        return polished
    }

    func testConnection() async throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { throw Error.invalidConfiguration }

        var request = URLRequest(url: endpoint.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": trimmedModel])

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 404 { throw Error.modelNotFound(trimmedModel) }
        if !(200...299).contains(http.statusCode) {
            throw Error.invalidHTTPStatus(http.statusCode)
        }
    }
}
