//
//  vbcc_macApp.swift
//  vbcc-mac
//

import SwiftUI

@main
struct vbcc_macApp: App {
    @StateObject private var tokens: TokenStore
    @StateObject private var server: VBCCServer
    @StateObject private var polish: PolishPreferences
    @StateObject private var transcripts: TranscriptStore
    @StateObject private var ax = AccessibilityStatus()

    init() {
        let store = TokenStore()
        let polishPreferences = PolishPreferences()
        let transcriptStore = TranscriptStore()
        _tokens = StateObject(wrappedValue: store)
        _polish = StateObject(wrappedValue: polishPreferences)
        _transcripts = StateObject(wrappedValue: transcriptStore)
        _server = StateObject(wrappedValue: VBCCServer(
            tokens: store,
            polishPreferences: polishPreferences,
            transcripts: transcriptStore
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(server)
                .environmentObject(tokens)
                .environmentObject(polish)
                .environmentObject(transcripts)
                .environmentObject(ax)
                .onAppear { server.start() }
        }
        .defaultSize(width: 880, height: 640)
        .windowResizability(.contentMinSize)
    }
}
