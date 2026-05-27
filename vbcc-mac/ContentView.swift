//
//  ContentView.swift
//  vbcc-mac
//
//  V1 第 2 阶段：状态条 + 配对数字大显示 + 已配对设备列表 + 日志。
//

import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject private var server: VBCCServer
    @EnvironmentObject private var tokens: TokenStore
    @EnvironmentObject private var ax: AccessibilityStatus

    var body: some View {
        VStack(spacing: 0) {
            statusBar
                .padding(12)
            Divider()

            if !ax.isTrusted {
                AccessibilityBanner()
                    .padding(16)
                    .transition(.opacity)
                Divider()
            }

            if let pending = server.pendingPair {
                PairNumberCard(pending: pending)
                    .padding(16)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                Divider()
            }

            devicesSection
            Divider()
            OllamaSettingsSection()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            logView
        }
        .frame(minWidth: 620, minHeight: 680)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: server.pendingPair)
        .animation(.easeInOut(duration: 0.25), value: ax.isTrusted)
    }

    // MARK: - 状态条

    private var statusBar: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText).font(.headline)
                Text(VBCC.bonjourServiceType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("端口 \(server.port.map(String.init) ?? "-")")
                    .font(.system(.body, design: .monospaced))
                Text("活动连接 \(server.connectedClients)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .running:  return .green
        case .starting: return .yellow
        case .stopped:  return .gray
        case .failed:   return .red
        }
    }

    private var statusText: String {
        switch server.status {
        case .stopped:           return "未启动"
        case .starting:          return "启动中…"
        case .running:           return "运行中"
        case .failed(let msg):   return "失败：\(msg)"
        }
    }

    // MARK: - 已配对设备

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已配对设备 (\(tokens.devices.count))")
                    .font(.headline)
                Spacer()
                if !tokens.devices.isEmpty {
                    Button("全部吊销", role: .destructive) {
                        for d in tokens.devices {
                            server.revoke(token: d.token)
                        }
                    }
                    .controlSize(.small)
                }
            }
            if tokens.devices.isEmpty {
                Text("还没有配对设备。在 iPhone 上发起配对，这里会显示一个配对数字。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(tokens.devices) { device in
                    DeviceRow(device: device) {
                        server.revoke(token: device.token)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 日志

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(server.log) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 1)
                        .id(entry.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: server.log.last?.id) { _, newId in
                if let newId { withAnimation { proxy.scrollTo(newId, anchor: .bottom) } }
            }
        }
    }
}

// MARK: - 配对数字卡片

private struct PairNumberCard: View {
    let pending: VBCCServer.PendingPair

    @State private var now: Date = .now
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var remaining: Int {
        max(0, Int(pending.expiresAt.timeIntervalSince(now).rounded(.down)))
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("配对数字")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(VBCC.pairNumberText(pending.number))
                .font(.system(size: 72, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 168, minHeight: 104)
                .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
            VStack(spacing: 4) {
                Text(pending.deviceName)
                    .font(.callout)
                Text("\(remaining) 秒内在 iPhone 上选出这个数字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .onReceive(timer) { now = $0 }
    }
}

// MARK: - 设备行

private struct DeviceRow: View {
    let device: PairedDevice
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName).font(.body)
                Text("\(device.model) · iOS \(device.iosVersion) · \(device.pairedAt, format: .dateTime.year().month().day().hour().minute())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("吊销", role: .destructive, action: onRevoke)
                .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Ollama 设置

private struct OllamaSettingsSection: View {
    @EnvironmentObject private var ollama: OllamaPreferences
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case running
        case success
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Ollama 本地整理", systemImage: "wand.and.sparkles")
                    .font(.headline)
                Spacer()
                Toggle("启用", isOn: $ollama.isEnabled)
                    .toggleStyle(.switch)
            }

            if ollama.isEnabled {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("地址")
                            .foregroundStyle(.secondary)
                        TextField("http://127.0.0.1:11434", text: $ollama.endpointText)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("模型")
                            .foregroundStyle(.secondary)
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("自定义 Prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $ollama.prompt)
                        .font(.system(.body, design: .default))
                        .frame(minHeight: 92)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: ollama.isEnabled)
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

// MARK: - 权限横幅

private struct AccessibilityBanner: View {
    @EnvironmentObject private var ax: AccessibilityStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("需要辅助功能权限")
                    .font(.headline)
                Text("vbcc-mac 需要「辅助功能」权限才能把 iPhone 发来的文字写入当前焦点输入框。授权后此横幅会自动消失。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Button("打开系统设置") { ax.openSettings() }
                    .buttonStyle(.borderedProminent)
                Button("请求授权") { ax.promptIfNeeded() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(VBCCServer(tokens: TokenStore()))
        .environmentObject(TokenStore())
        .environmentObject(OllamaPreferences())
        .environmentObject(AccessibilityStatus())
}
