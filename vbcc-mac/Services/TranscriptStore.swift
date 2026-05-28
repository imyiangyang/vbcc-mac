//
//  TranscriptStore.swift
//  vbcc-mac
//
//  内存缓存 + 文件持久化的语音转写气泡列表。
//

import Foundation
import Combine

struct Transcript: Codable, Identifiable, Equatable {
    let id: UUID
    let deviceToken: String
    let deviceName: String
    let originalText: String
    let polishedText: String?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        deviceToken: String,
        deviceName: String,
        originalText: String,
        polishedText: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.deviceToken = deviceToken
        self.deviceName = deviceName
        self.originalText = originalText
        self.polishedText = polishedText
        self.timestamp = timestamp
    }

    /// 显示用的最终文本（优先整理后，无则使用原文）
    var displayText: String {
        if let polished = polishedText, !polished.isEmpty { return polished }
        return originalText
    }
}

@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var transcripts: [Transcript] = []

    private let maxCount: Int
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(maxCount: Int = 200) {
        self.maxCount = maxCount
        self.fileURL = Self.defaultFileURL()
        load()
    }

    func append(_ transcript: Transcript) {
        transcripts.append(transcript)
        if transcripts.count > maxCount {
            transcripts.removeFirst(transcripts.count - maxCount)
        }
        scheduleSave()
    }

    func clear() {
        transcripts.removeAll()
        scheduleSave()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let list = try? JSONDecoder.iso8601.decode([Transcript].self, from: data) else { return }
        if list.count > maxCount {
            transcripts = Array(list.suffix(maxCount))
        } else {
            transcripts = list
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = transcripts
        let target = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            Self.write(snapshot, to: target)
        }
    }

    nonisolated private static func write(_ list: [Transcript], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.iso8601.encode(list)
            try data.write(to: url, options: .atomic)
        } catch {
            // 持久化失败不影响主流程
        }
    }

    private static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        return base
            .appendingPathComponent("vbcc-mac", isDirectory: true)
            .appendingPathComponent("transcripts.json")
    }
}

private extension JSONEncoder {
    nonisolated static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    nonisolated static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
