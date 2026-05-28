//
//  DevicesPage.swift
//  vbcc-mac
//
//  设备页：状态条 + 配对数字 + 可折叠设备列表（在原位置悬浮展开） + iMessage 风格语音气泡。
//

import SwiftUI
import Combine

struct DevicesPage: View {
    @EnvironmentObject private var server: VBCCServer
    @EnvironmentObject private var tokens: TokenStore
    @EnvironmentObject private var ax: AccessibilityStatus
    @EnvironmentObject private var transcripts: TranscriptStore

    @State private var devicesExpanded: Bool = false
    @State private var barFrame: CGRect = .zero
    @State private var rowHeight: CGFloat = 0

    private let pageSpace = "DevicesPage"

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                headerStack

                Divider()

                TranscriptChatView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: pageSpace)

            // 点击空白关闭浮层
            if devicesExpanded {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { devicesExpanded = false }
                    .transition(.opacity)
                    .zIndex(1)

                // 悬浮卡片：精确盖在「已配对设备」按钮位置
                floatingDevicesPanel
                    .frame(width: barFrame.width)
                    .offset(x: barFrame.minX, y: barFrame.minY)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                        removal: .opacity
                    ))
                    .zIndex(2)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: server.pendingPair)
        .animation(.easeInOut(duration: 0.25), value: ax.isTrusted)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: devicesExpanded)
        .navigationTitle("设备")
    }

    // MARK: - 顶部 Header

    private var headerStack: some View {
        VStack(spacing: 12) {
            statusCard

            if !ax.isTrusted {
                AccessibilityBanner()
            }

            if let pending = server.pendingPair {
                PairNumberCard(pending: pending)
            }

            devicesHeaderBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 设备折叠条（始终可见，作为悬浮卡片的锚点）

    private var devicesHeaderBar: some View {
        Button {
            devicesExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(devicesExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                Text("已配对设备 (\(tokens.devices.count))")
                    .font(.headline)
                Spacer()
                Text(devicesExpanded ? "收起" : "展开")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: BarFrameKey.self,
                    value: geo.frame(in: .named(pageSpace))
                )
            }
        )
        .onPreferenceChange(BarFrameKey.self) { barFrame = $0 }
        // 浮层占据折叠条位置时，保留原位空间但隐藏内容
        .opacity(devicesExpanded ? 0 : 1)
    }

    // MARK: - 浮动设备列表（在 headerBar 原位置展开）

    /// 浮层 ScrollView 上限：最多 3 行 + 行间 Divider，未测量到时给一个保守上限
    private var scrollMaxHeight: CGFloat {
        guard rowHeight > 0 else { return 240 }
        let visible = min(tokens.devices.count, 3)
        let dividers = max(0, visible - 1)
        return rowHeight * CGFloat(visible) + CGFloat(dividers)
    }

    private var floatingDevicesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题条：和折叠条尺寸一致，点击可收起
            Button {
                devicesExpanded = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(90))
                        .foregroundStyle(.secondary)
                    Text("已配对设备 (\(tokens.devices.count))")
                        .font(.headline)
                    Spacer()
                    Text("收起")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().opacity(0.5)

            if tokens.devices.isEmpty {
                Text("还没有配对设备。在 iPhone 上发起配对，这里会显示一个配对数字。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(tokens.devices.enumerated()), id: \.element.id) { index, device in
                            DeviceRow(device: device) {
                                server.revoke(token: device.token)
                            }
                            .padding(.horizontal, 12)
                            .background(
                                // 用第一行测量单行高度
                                index == 0 ? GeometryReader { geo in
                                    Color.clear.preference(
                                        key: RowHeightKey.self,
                                        value: geo.size.height
                                    )
                                } : nil
                            )
                            if device.id != tokens.devices.last?.id {
                                Divider().opacity(0.4).padding(.leading, 12)
                            }
                        }
                    }
                }
                .frame(maxHeight: scrollMaxHeight)
                .onPreferenceChange(RowHeightKey.self) { rowHeight = $0 }

                Divider().opacity(0.5)

                HStack {
                    Spacer()
                    Button("全部吊销", role: .destructive) {
                        for d in tokens.devices {
                            server.revoke(token: d.token)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
    }

    // MARK: - 状态卡片

    private var statusCard: some View {
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
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
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
}

// MARK: - 折叠条 frame 测量

private struct BarFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - 单行设备行高度测量

private struct RowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
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
            Circle()
                .fill(DeviceColor.color(for: device.token))
                .frame(width: 10, height: 10)
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
        .padding(.vertical, 8)
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
