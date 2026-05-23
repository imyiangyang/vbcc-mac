//
//  AccessibilityStatus.swift
//  vbcc-mac
//
//  监控 Accessibility 权限。
//  系统对权限变化无通知，需要轮询；在 app 激活时立即复查。
//

import Foundation
import AppKit
import ApplicationServices
import Combine

final class AccessibilityStatus: ObservableObject {

    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    /// 触发系统权限弹窗（若未授权)。已授权时无副作用。
    func promptIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if trusted != isTrusted { isTrusted = trusted }
    }

    /// 跳转到 Accessibility 设置面板
    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func refresh() {
        let now = AXIsProcessTrusted()
        if now != isTrusted { isTrusted = now }
    }
}
