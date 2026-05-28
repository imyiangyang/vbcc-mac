//
//  TranscriptChatView.swift
//  vbcc-mac
//
//  iMessage 风格的语音转写气泡列表（左侧灰泡，按设备 token 区分气泡颜色）。
//

import SwiftUI

struct TranscriptChatView: View {
    @EnvironmentObject private var transcripts: TranscriptStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("语音消息", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(transcripts.transcripts.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !transcripts.transcripts.isEmpty {
                    Button("清空") { transcripts.clear() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if transcripts.transcripts.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("等待 iPhone 发来的语音文本…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(transcripts.transcripts) { transcript in
                                BubbleRow(transcript: transcript)
                                    .id(transcript.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: transcripts.transcripts.last?.id) { _, newId in
                        if let newId {
                            withAnimation { proxy.scrollTo(newId, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }
}

private struct BubbleRow: View {
    let transcript: Transcript

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(DeviceColor.color(for: transcript.deviceToken))
                .frame(width: 8, height: 8)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(transcript.deviceName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DeviceColor.color(for: transcript.deviceToken))
                    Text(transcript.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                bubble
            }

            Spacer(minLength: 40)
        }
    }

    private var bubble: some View {
        let bubbleColor = DeviceColor.color(for: transcript.deviceToken).opacity(0.18)
        let strokeColor = DeviceColor.color(for: transcript.deviceToken).opacity(0.35)

        return VStack(alignment: .leading, spacing: 6) {
            Text(transcript.displayText)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let polished = transcript.polishedText,
               !polished.isEmpty,
               polished != transcript.originalText {
                Divider().opacity(0.4)
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("原文：\(transcript.originalText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 16,
                bottomTrailingRadius: 16,
                topTrailingRadius: 16,
                style: .continuous
            )
            .fill(bubbleColor)
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 16,
                bottomTrailingRadius: 16,
                topTrailingRadius: 16,
                style: .continuous
            )
            .stroke(strokeColor, lineWidth: 0.5)
        )
    }
}

// MARK: - 设备颜色

enum DeviceColor {
    private static let palette: [Color] = [
        Color(red: 0.30, green: 0.55, blue: 0.95), // 蓝
        Color(red: 0.95, green: 0.45, blue: 0.55), // 粉红
        Color(red: 0.40, green: 0.75, blue: 0.55), // 绿
        Color(red: 0.95, green: 0.60, blue: 0.30), // 橙
        Color(red: 0.65, green: 0.45, blue: 0.85), // 紫
        Color(red: 0.30, green: 0.70, blue: 0.80), // 青
    ]

    static func color(for token: String) -> Color {
        guard !token.isEmpty else { return palette[0] }
        var hash: UInt64 = 1469598103934665603
        for byte in token.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
