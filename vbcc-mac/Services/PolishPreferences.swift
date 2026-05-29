//
//  PolishPreferences.swift
//  vbcc-mac
//
//  统一的润色偏好:总开关 / provider 切换 / 共享 prompt+timeout / 各 provider 子配置。
//  老 UserDefaults 键名复用,实现零迁移升级。
//

import Foundation
import Combine

nonisolated struct OllamaConfiguration: Equatable {
    var endpoint: URL
    var model: String
    var prompt: String
    var timeout: TimeInterval
}

nonisolated struct ArkConfiguration: Equatable {
    var baseURL: URL
    var apiKey: String
    var model: String
    var prompt: String
    var timeout: TimeInterval
}

final class PolishPreferences: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    @Published var providerKind: PolishProviderKind {
        didSet { defaults.set(providerKind.rawValue, forKey: Keys.providerKind) }
    }

    @Published var prompt: String {
        didSet { defaults.set(prompt, forKey: Keys.prompt) }
    }

    @Published var timeout: Double {
        didSet { defaults.set(timeout, forKey: Keys.timeout) }
    }

    @Published var ollamaEndpoint: String {
        didSet { defaults.set(ollamaEndpoint, forKey: Keys.ollamaEndpoint) }
    }

    @Published var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: Keys.ollamaModel) }
    }

    @Published var arkBaseURL: String {
        didSet { defaults.set(arkBaseURL, forKey: Keys.arkBaseURL) }
    }

    @Published var arkModel: String {
        didSet { defaults.set(arkModel, forKey: Keys.arkModel) }
    }

    /// API key 不进 @Published,通过专用 getter/setter 走 Keychain。
    var arkAPIKey: String {
        get { KeychainStore.get(forAccount: arkAPIKeyAccount) ?? "" }
        set { KeychainStore.set(newValue.isEmpty ? nil : newValue, forAccount: arkAPIKeyAccount) }
    }

    private let defaults: UserDefaults
    private let arkAPIKeyAccount: String

    init(defaults: UserDefaults = .standard, arkAPIKeyAccount: String = "vbcc.ark.apiKey") {
        self.defaults = defaults
        self.arkAPIKeyAccount = arkAPIKeyAccount

        self.isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? false

        if let raw = defaults.string(forKey: Keys.providerKind),
           let kind = PolishProviderKind(rawValue: raw) {
            self.providerKind = kind
        } else {
            self.providerKind = .ollama
        }

        self.prompt = defaults.string(forKey: Keys.prompt) ?? Self.defaultPrompt
        let storedTimeout = defaults.double(forKey: Keys.timeout)
        self.timeout = storedTimeout > 0 ? storedTimeout : 5

        self.ollamaEndpoint = defaults.string(forKey: Keys.ollamaEndpoint) ?? "http://127.0.0.1:11434"
        self.ollamaModel = defaults.string(forKey: Keys.ollamaModel) ?? "qwen3.5:0.8b"

        self.arkBaseURL = defaults.string(forKey: Keys.arkBaseURL) ?? "https://ark.cn-beijing.volces.com/api/v3"
        self.arkModel = defaults.string(forKey: Keys.arkModel) ?? ""
    }

    /// 当前选定 provider 是否处于"配置可用"状态(总开关已开 + 必填齐全)。
    var isReady: Bool {
        guard isEnabled else { return false }
        switch providerKind {
        case .ollama: return ollamaConfig != nil
        case .ark:    return arkConfig != nil
        }
    }

    var ollamaConfig: OllamaConfiguration? {
        let trimmedEndpoint = ollamaEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty,
              let url = URL(string: trimmedEndpoint) else { return nil }
        return OllamaConfiguration(
            endpoint: url,
            model: trimmedModel,
            prompt: prompt,
            timeout: timeout
        )
    }

    var arkConfig: ArkConfiguration? {
        let trimmedBase = arkBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = arkModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = arkAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty, !key.isEmpty,
              let url = URL(string: trimmedBase) else { return nil }
        return ArkConfiguration(
            baseURL: url,
            apiKey: key,
            model: trimmedModel,
            prompt: prompt,
            timeout: timeout
        )
    }

    static let defaultPrompt = """
    你是语音转写文本整理助手。请将 iOS 端发来的语音文字整理为可直接发送或粘贴的文本:
    - 修正明显错别字、同音词、英文单词识别错误和中英双语夹杂错误。
    - 去除"嗯、啊、呃、就是、那个"等口语化语气词。
    - 在不改变原意的前提下整理标点、空格、大小写和段落格式。
    - 保留用户原本想表达的语言风格,不扩写,不补充事实。
    """

    private enum Keys {
        // 沿用老键,实现零迁移
        static let isEnabled = "vbcc.ollama.enabled"
        static let prompt = "vbcc.ollama.prompt"
        static let timeout = "vbcc.ollama.timeout"
        static let ollamaEndpoint = "vbcc.ollama.endpoint"
        static let ollamaModel = "vbcc.ollama.model"

        // 新增键
        static let providerKind = "vbcc.polish.provider"
        static let arkBaseURL = "vbcc.ark.baseURL"
        static let arkModel = "vbcc.ark.model"
    }
}
