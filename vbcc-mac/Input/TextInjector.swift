//
//  TextInjector.swift
//  vbcc-mac
//
//  把 iPhone 发来的文本 / 按键注入到当前焦点窗口。
//  方案：CGEvent + keyboardSetUnicodeString + .cgAnnotatedSessionEventTap
//   - .cgAnnotatedSessionEventTap 在 IME 下游注入，绕过中文输入法截获
//   - 文本按 grapheme cluster 分块，避免切坏组合 emoji
//   - flags 清空，避免被物理修饰键污染
//   - 块间小延迟，避免高速 post 导致顺序错乱
//   - actor 串行化：多设备并发时按到达顺序逐条注入
//

import Foundation
import CoreGraphics
import ApplicationServices

actor TextInjector {

    /// 单次 keyboardSetUnicodeString 的 UTF-16 上限（实测安全值）
    private let maxUTF16PerChunk: Int = 20
    /// 块间间隔
    private let interChunkDelayNanos: UInt64 = 2_000_000  // 2ms

    /// 注入文本到当前焦点输入框。失败仅在权限缺失时返回 false。
    func inject(_ text: String, sendEnter: Bool) async -> Bool {
        guard ensureAccessibility() else { return false }
        guard !text.isEmpty else {
            if sendEnter { postKey(code: Self.keyCode(for: .returnKey), action: .tap) }
            return true
        }

        for chunk in chunkByGraphemes(text, maxUTF16: maxUTF16PerChunk) {
            postUnicode(chunk)
            try? await Task.sleep(nanoseconds: interChunkDelayNanos)
        }

        if sendEnter { postKey(code: Self.keyCode(for: .returnKey), action: .tap) }
        return true
    }

    /// 注入单个按键（方向键、回车、Esc、左右修饰键、Fn 等）。
    /// 失败仅在权限缺失时返回 false。
    func injectKey(_ key: KeyName, action: KeyAction = .tap) async -> Bool {
        guard ensureAccessibility() else { return false }
        let code = Self.keyCode(for: key)
        if let flag = Self.modifierFlag(for: key) {
            postModifier(code: code, flag: flag, action: action)
        } else {
            postKey(code: code, action: action)
        }
        return true
    }

    // MARK: - 权限

    /// 当前进程是否拥有 Accessibility 权限。无 prompt（避免在错误时机弹窗）。
    nonisolated func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func ensureAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Post：文本

    private func postUnicode(_ chunk: String) {
        let utf16 = Array(chunk.utf16)
        guard !utf16.isEmpty else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.flags = []
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down?.post(tap: .cgAnnotatedSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.flags = []
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Post：普通按键

    /// 普通键（非修饰键）：标准 keyDown / keyUp 事件。
    private func postKey(code: CGKeyCode, action: KeyAction) {
        if action == .tap || action == .down {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
            down?.flags = []
            down?.post(tap: .cgAnnotatedSessionEventTap)
        }
        if action == .tap || action == .up {
            let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
            up?.flags = []
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    // MARK: - Post：修饰键

    /// 修饰键（Command / Shift / Option / Fn）：必须以 .flagsChanged 事件下发，
    /// 普通 keyDown/keyUp 多数应用不会识别为修饰键状态变化。
    /// - down：flags 置为该修饰键掩码；up：flags 清空。
    private func postModifier(code: CGKeyCode, flag: CGEventFlags, action: KeyAction) {
        if action == .tap || action == .down {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
            down?.type = .flagsChanged
            down?.flags = flag
            down?.post(tap: .cgAnnotatedSessionEventTap)
        }
        if action == .tap || action == .up {
            let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
            up?.type = .flagsChanged
            up?.flags = []
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    // MARK: - 键位映射

    /// KeyName → macOS 虚拟键码（Carbon kVK_*）。
    private static func keyCode(for key: KeyName) -> CGKeyCode {
        switch key {
        case .up:           return 0x7E   // kVK_UpArrow
        case .down:         return 0x7D   // kVK_DownArrow
        case .left:         return 0x7B   // kVK_LeftArrow
        case .right:        return 0x7C   // kVK_RightArrow
        case .returnKey:    return 0x24   // kVK_Return（主键盘回车）
        case .enter:        return 0x4C   // kVK_ANSI_KeypadEnter（小键盘回车）
        case .escape:       return 0x35   // kVK_Escape
        case .commandLeft:  return 0x37   // kVK_Command
        case .commandRight: return 0x36   // kVK_RightCommand
        case .shiftLeft:    return 0x38   // kVK_Shift
        case .shiftRight:   return 0x3C   // kVK_RightShift
        case .optionLeft:   return 0x3A   // kVK_Option
        case .optionRight:  return 0x3D   // kVK_RightOption
        case .fn:           return 0x3F   // kVK_Function
        }
    }

    /// 若 KeyName 是修饰键，返回其对应的 CGEventFlags 掩码；否则 nil。
    private static func modifierFlag(for key: KeyName) -> CGEventFlags? {
        switch key {
        case .commandLeft, .commandRight: return .maskCommand
        case .shiftLeft, .shiftRight:     return .maskShift
        case .optionLeft, .optionRight:   return .maskAlternate
        case .fn:                         return .maskSecondaryFn
        default:                          return nil
        }
    }

    // MARK: - 分块

    /// 按 grapheme cluster 累加，单块 UTF-16 长度不超过 max。
    /// 不会切碎组合 emoji（👨‍👩‍👧 整体进同一块或单独成块）。
    private func chunkByGraphemes(_ s: String, maxUTF16: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentLen = 0
        for grapheme in s {
            let g = String(grapheme)
            let gLen = g.utf16.count
            if currentLen + gLen > maxUTF16 && !current.isEmpty {
                chunks.append(current)
                current = ""
                currentLen = 0
            }
            current += g
            currentLen += gLen
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
