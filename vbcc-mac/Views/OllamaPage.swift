//
//  OllamaPage.swift
//  vbcc-mac
//
//  Ollama 本地整理：地址 / 模型 / 超时 / 测试 / 自定义 Prompt。
//

import SwiftUI

struct OllamaPage: View {
    @EnvironmentObject private var ollama: OllamaPreferences
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case running
        case success
        case failure(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if ollama.isEnabled {
                    connectionCard
                    promptCard
                } else {
                    disabledHint
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Ollama")
        .animation(.easeInOut(duration: 0.2), value: ollama.isEnabled)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Label("Ollama 本地整理", systemImage: "wand.and.sparkles")
                .font(.title3.weight(.semibold))
            Spacer()
            Toggle("启用", isOn: $ollama.isEnabled)
                .toggleStyle(.switch)
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("地址")
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    TextField("http://127.0.0.1:11434", text: $ollama.endpointText)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("模型")
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    HStack(spacing: 8) {
                        TextField("qwen3.5:0.8b", text: $ollama.model)
                            .textFieldStyle(.roundedBorder)
                        Button(action: runConnectionTest) {
                            if testState == .running {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 14, height: 14)
                            } else {
                                Text("测试")
                            }
                        }
                        .disabled(testState == .running)
                    }
                }
                GridRow {
                    Text("超时")
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    HStack {
                        Slider(value: $ollama.timeout, in: 5...60, step: 1)
                        Text("\(Int(ollama.timeout)) 秒")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }

            if let message = testStatusMessage {
                HStack(spacing: 6) {
                    Image(systemName: testStatusIcon)
                        .foregroundStyle(testStatusColor)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(testStatusColor)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自定义 Prompt")
                    .font(.headline)
                Spacer()
                Button("恢复默认") {
                    ollama.prompt = OllamaPreferences.defaultPrompt
                }
                .controlSize(.small)
            }
            Text("用于指导 Ollama 整理 iPhone 发来的语音转写文本。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $ollama.prompt)
                .font(.system(.body, design: .default))
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var disabledHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Ollama 整理已关闭。开启后，iPhone 发来的语音文字会先经本地 Ollama 模型整理，再写入当前焦点输入框。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var testStatusMessage: String? {
        switch testState {
        case .idle: return nil
        case .running: return "正在连接 Ollama…"
        case .success: return "连接成功，模型可用。"
        case .failure(let reason): return reason
        }
    }

    private var testStatusIcon: String {
        switch testState {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        default: return "info.circle"
        }
    }

    private var testStatusColor: Color {
        switch testState {
        case .success: return .green
        case .failure: return .red
        default: return .secondary
        }
    }

    private func runConnectionTest() {
        guard let configuration = ollama.configuration else {
            testState = .failure("地址无效，请检查后重试。")
            return
        }
        testState = .running
        Task {
            let polisher = OllamaTextPolisher()
            do {
                try await polisher.testConnection(configuration: configuration)
                await MainActor.run { testState = .success }
            } catch {
                let reason = Self.describe(error: error)
                await MainActor.run { testState = .failure(reason) }
            }
        }
    }

    private static func describe(error: Swift.Error) -> String {
        if let polishError = error as? OllamaTextPolisher.Error {
            switch polishError {
            case .invalidConfiguration: return "模型名称为空。"
            case .modelNotFound(let model): return "模型「\(model)」不存在，请先 ollama pull。"
            case .invalidHTTPStatus(let code): return "服务返回 HTTP \(code)。"
            case .emptyResponse: return "服务返回了空响应。"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "连接超时，请检查地址或调高超时时间。"
            case .cannotConnectToHost, .cannotFindHost:
                return "无法连接到 Ollama 服务，请确认已启动。"
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
