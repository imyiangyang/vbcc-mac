//
//  PolishPage.swift
//  vbcc-mac
//
//  模型配置页:provider 切换(Ollama / 豆包)、连接配置、共享 prompt。
//

import SwiftUI

struct PolishPage: View {
    @EnvironmentObject private var polish: PolishPreferences
    @State private var testState: TestState = .idle
    @State private var arkAPIKey: String = ""
    @State private var showAPIKey: Bool = false
    @State private var apiKeyDebounceTask: Task<Void, Never>?

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

                if polish.isEnabled {
                    providerCard
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
        .navigationTitle("模型配置")
        .animation(.easeInOut(duration: 0.2), value: polish.isEnabled)
        .animation(.easeInOut(duration: 0.2), value: polish.providerKind)
        .onAppear { arkAPIKey = polish.arkAPIKey }
        .onChange(of: polish.providerKind) { _, _ in
            testState = .idle
        }
        .onChange(of: arkAPIKey) { _, newValue in
            apiKeyDebounceTask?.cancel()
            apiKeyDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if !Task.isCancelled {
                    await MainActor.run { polish.arkAPIKey = newValue }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Label("模型配置", systemImage: "wand.and.sparkles")
                .font(.title3.weight(.semibold))
            Spacer()
            Toggle("启用", isOn: $polish.isEnabled)
                .toggleStyle(.switch)
        }
    }

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("提供方")
                .font(.headline)
            Picker("提供方", selection: $polish.providerKind) {
                ForEach(PolishProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接")
                .font(.headline)

            switch polish.providerKind {
            case .ollama: ollamaFields
            case .ark:    arkFields
            }

            timeoutRow

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

    private var ollamaFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("地址").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                TextField("http://127.0.0.1:11434", text: $polish.ollamaEndpoint)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("模型").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                HStack(spacing: 8) {
                    TextField("qwen3.5:0.8b", text: $polish.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                    testButton(disabled: polish.ollamaConfig == nil)
                }
            }
        }
    }

    private var arkFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Base URL").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                TextField("https://ark.cn-beijing.volces.com/api/v3", text: $polish.arkBaseURL)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("API Key").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                HStack(spacing: 8) {
                    if showAPIKey {
                        TextField("sk-...", text: $arkAPIKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("sk-...", text: $arkAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(action: { showAPIKey.toggle() }) {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showAPIKey ? "隐藏" : "显示")
                }
            }
            GridRow {
                Text("模型").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                HStack(spacing: 8) {
                    TextField("doubao-... 或 endpoint id", text: $polish.arkModel)
                        .textFieldStyle(.roundedBorder)
                    testButton(disabled: polish.arkConfig == nil)
                }
            }
        }
    }

    private var timeoutRow: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("超时").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                HStack {
                    Slider(value: $polish.timeout, in: 5...60, step: 1)
                    Text("\(Int(polish.timeout)) 秒")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    private func testButton(disabled: Bool) -> some View {
        Button(action: runConnectionTest) {
            if testState == .running {
                ProgressView().controlSize(.small).frame(width: 14, height: 14)
            } else {
                Text("测试")
            }
        }
        .disabled(testState == .running || disabled)
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自定义 Prompt")
                    .font(.headline)
                Spacer()
                Button("恢复默认") {
                    polish.prompt = PolishPreferences.defaultPrompt
                }
                .controlSize(.small)
            }
            Text("用于指导模型整理 iPhone 发来的语音转写文本。两个 provider 共用同一份 prompt。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $polish.prompt)
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
            Text("模型整理已关闭。开启后,iPhone 发来的语音文字会先经选定的模型整理,再写入当前焦点输入框。")
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
        case .running: return "正在连接…"
        case .success: return "连接成功,模型可用。"
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
        testState = .running
        Task {
            let polisher: TranscriptPolishing?
            switch polish.providerKind {
            case .ollama:
                if let cfg = polish.ollamaConfig {
                    polisher = OllamaPolisher(endpoint: cfg.endpoint, model: cfg.model, timeout: cfg.timeout)
                } else { polisher = nil }
            case .ark:
                if let cfg = polish.arkConfig {
                    polisher = ArkPolisher(baseURL: cfg.baseURL, apiKey: cfg.apiKey, model: cfg.model, timeout: cfg.timeout)
                } else { polisher = nil }
            }

            guard let polisher else {
                await MainActor.run { testState = .failure("配置不完整,请检查必填项。") }
                return
            }

            do {
                try await polisher.testConnection()
                await MainActor.run { testState = .success }
            } catch {
                let reason = Self.describe(error: error)
                await MainActor.run { testState = .failure(reason) }
            }
        }
    }

    private static func describe(error: Swift.Error) -> String {
        if let e = error as? OllamaPolisher.Error {
            switch e {
            case .invalidConfiguration: return "配置不完整,请检查必填项。"
            case .modelNotFound(let m):  return "模型「\(m)」不存在,请先 ollama pull。"
            case .invalidHTTPStatus(let c): return "服务返回 HTTP \(c)。"
            case .emptyResponse: return "服务返回了空响应。"
            }
        }
        if let e = error as? ArkPolisher.Error {
            switch e {
            case .invalidConfiguration: return "配置不完整,请检查必填项。"
            case .unauthorized: return "API Key 无效或已过期。"
            case .modelNotFound(let m): return "模型「\(m)」不存在或 endpoint id 错误。"
            case .invalidHTTPStatus(let c): return "豆包服务返回 HTTP \(c)。"
            case .emptyResponse: return "服务返回了空响应。"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "连接超时,请检查地址或调高超时时间。"
            case .cannotConnectToHost, .cannotFindHost:
                return "无法连接到服务,请确认地址正确。"
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
