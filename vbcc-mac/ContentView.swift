//
//  ContentView.swift
//  vbcc-mac
//
//  侧边栏布局：设备 / 日志 / Ollama 三个一级页面。
//

import SwiftUI
import Combine

enum SidebarItem: Hashable, CaseIterable, Identifiable {
    case devices
    case log
    case ollama

    var id: Self { self }

    var title: String {
        switch self {
        case .devices: return "设备"
        case .log:     return "日志"
        case .ollama:  return "Ollama"
        }
    }

    var systemImage: String {
        switch self {
        case .devices: return "iphone.gen3"
        case .log:     return "text.alignleft"
        case .ollama:  return "wand.and.sparkles"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .devices

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selection ?? .devices {
            case .devices: DevicesPage()
            case .log:     LogPage()
            case .ollama:  OllamaPage()
            }
        }
        .frame(minWidth: 820, minHeight: 600)
    }
}

#Preview {
    ContentView()
        .environmentObject(VBCCServer(tokens: TokenStore()))
        .environmentObject(TokenStore())
        .environmentObject(OllamaPreferences())
        .environmentObject(TranscriptStore())
        .environmentObject(AccessibilityStatus())
}
