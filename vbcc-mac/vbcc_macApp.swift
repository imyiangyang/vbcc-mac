//
//  vbcc_macApp.swift
//  vbcc-mac
//

import SwiftUI

@main
struct vbcc_macApp: App {
    @StateObject private var tokens: TokenStore
    @StateObject private var server: VBCCServer
    @StateObject private var ax = AccessibilityStatus()

    init() {
        let store = TokenStore()
        _tokens = StateObject(wrappedValue: store)
        _server = StateObject(wrappedValue: VBCCServer(tokens: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(server)
                .environmentObject(tokens)
                .environmentObject(ax)
                .onAppear { server.start() }
        }
        .defaultSize(width: 560, height: 520)
    }
}
