//
//  DevicesPage.swift
//  vbcc-mac
//
//  设备页：状态条 + 配对数字 + 可折叠设备列表 + iMessage 风格语音气泡。
//

import SwiftUI
import Combine

struct DevicesPage: View {
    @EnvironmentObject private var server: VBCCServer
    @EnvironmentObject private var tokens: TokenStore
    @EnvironmentObject private var ax: AccessibilityStatus
    @EnvironmentObject private var transcripts: TranscriptStore

    @State private var devicesExpanded: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    statusCard

                    if !ax.isTrusted {
                        AccessibilityBanner()
                    }

                    if let pending = server.pendingPair {
                        PairNumberCard(pending: pending)
                    }

                    devicesDisclosure
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            TranscriptChatView()
                .frame(minHeight: 220)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: server.pendingPair)
        .animation(.easeInOut(duration: 0.25), value: ax.isTrusted)
        .navigationTitle("设备")
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

    // MARK: - 可折叠设备列表

    private var devicesDisclosure: some View {
        DisclosureGroup(isExpanded: $devicesExpanded) {
            VStack(alignment: .leading, spacing: 8) {
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
            .padding(.top, 8)
        } label: {
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
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
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
        .padding(.vertical, 6)
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
