//
//  Identity.swift
//  vbcc-mac
//
//  Mac 端身份 (macId) + token 存储。
//  V1 用 UserDefaults，简单可见；后续可改 Keychain。
//

import Foundation
import Combine

// MARK: - Mac 身份（持久 macId）

enum MacIdentity {
    private static let macIdKey = "vbcc.macId"

    /// 持久 macId，首次启动时生成
    static var macId: String {
        if let existing = UserDefaults.standard.string(forKey: macIdKey) {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: macIdKey)
        return id
    }

    /// Mac 显示名，TXT 里用
    static var macName: String {
        Host.current().localizedName ?? "Mac"
    }
}

// MARK: - 已配对设备 / Token 存储

struct PairedDevice: Codable, Identifiable, Equatable {
    let token: String        // 256-bit hex 随机串
    let iPhoneId: String     // 稳定的 iPhone 标识（identifierForVendor），用于去重
    let deviceName: String   // iPhone 显示名
    let model: String        // 比如 iPhone15,3
    let iosVersion: String
    let pairedAt: Date

    var id: String { token }
}

final class TokenStore: ObservableObject {

    @Published private(set) var devices: [PairedDevice] = []

    private let storageKey = "vbcc.pairedDevices"

    init() {
        load()
    }

    // MARK: - 查

    func find(token: String) -> PairedDevice? {
        devices.first(where: { $0.token == token })
    }

    // MARK: - 增

    /// 新建或更新一条配对记录（按 iPhoneId 去重），返回新生成的 token
    @discardableResult
    func register(iPhoneId: String, deviceName: String, model: String, iosVersion: String) -> PairedDevice {
        let token = Self.generateToken()
        let device = PairedDevice(
            token: token,
            iPhoneId: iPhoneId,
            deviceName: deviceName,
            model: model,
            iosVersion: iosVersion,
            pairedAt: Date()
        )
        // 同一 iPhone 重新配对：旧 token 作废，替换记录
        if let idx = devices.firstIndex(where: { $0.iPhoneId == iPhoneId }) {
            devices[idx] = device
        } else {
            devices.append(device)
        }
        save()
        return device
    }

    // MARK: - 删

    func revoke(token: String) {
        devices.removeAll(where: { $0.token == token })
        save()
    }

    func revokeAll() {
        devices.removeAll()
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        if let list = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            devices = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - 工具

    /// 256-bit token，hex 编码
    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
