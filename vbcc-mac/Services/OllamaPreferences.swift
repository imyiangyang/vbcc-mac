//
//  OllamaPreferences.swift
//  vbcc-mac
//
//  UserDefaults-backed settings for local Ollama transcript polishing.
//

import Foundation
import Combine

final class OllamaPreferences: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    @Published var endpointText: String {
        didSet { defaults.set(endpointText, forKey: Keys.endpointText) }
    }

    @Published var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }

    @Published var prompt: String {
        didSet { defaults.set(prompt, forKey: Keys.prompt) }
    }

    @Published var timeout: Double {
        didSet { defaults.set(timeout, forKey: Keys.timeout) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? false
        self.endpointText = defaults.string(forKey: Keys.endpointText) ?? "http://127.0.0.1:11434"
        self.model = defaults.string(forKey: Keys.model) ?? "qwen3.5:0.8b"
        self.prompt = defaults.string(forKey: Keys.prompt) ?? Self.defaultPrompt
        let storedTimeout = defaults.double(forKey: Keys.timeout)
        self.timeout = storedTimeout > 0 ? storedTimeout : 5
    }

    var configuration: OllamaConfiguration? {
        guard let endpoint = URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return OllamaConfiguration(
            enabled: isEnabled,
            endpoint: endpoint,
            model: model,
            prompt: prompt,
            timeout: timeout
        )
    }

    static let defaultPrompt = """
    你是语音转写文本整理助手。请将 iOS 端发来的语音文字整理为可直接发送或粘贴的文本：
    - 修正明显错别字、同音词、英文单词识别错误和中英双语夹杂错误。
    - 去除“嗯、啊、呃、就是、那个”等口语化语气词。
    - 在不改变原意的前提下整理标点、空格、大小写和段落格式。
    - 保留用户原本想表达的语言风格，不扩写，不补充事实。
    """

    private enum Keys {
        static let isEnabled = "vbcc.ollama.enabled"
        static let endpointText = "vbcc.ollama.endpoint"
        static let model = "vbcc.ollama.model"
        static let prompt = "vbcc.ollama.prompt"
        static let timeout = "vbcc.ollama.timeout"
    }
}
