//
//  LogPage.swift
//  vbcc-mac
//
//  连接 / 调试日志页。
//

import SwiftUI

struct LogPage: View {
    @EnvironmentObject private var server: VBCCServer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("连接日志", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                Text("\(server.log.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

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
        .navigationTitle("日志")
    }
}
