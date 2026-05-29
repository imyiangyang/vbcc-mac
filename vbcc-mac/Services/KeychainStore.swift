//
//  KeychainStore.swift
//  vbcc-mac
//
//  极简 Keychain 字符串存取封装。失败仅 log,不抛异常 —
//  本项目里只用来存 API key,这类配置失败(钥匙串被锁/拒绝)时
//  应让上层"无配置"路径接管,而非中断流程。
//

import Foundation
import Security
import os

enum KeychainStore {
    private static let service = "vbcc-mac"
    private static let logger = Logger(subsystem: "vbcc.mac", category: "keychain")

    static func get(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            logger.error("Keychain get failed for \(account, privacy: .public): \(status)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, forAccount account: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        guard let value, !value.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                logger.error("Keychain delete failed for \(account, privacy: .public): \(status)")
            }
            return
        }

        let data = Data(value.utf8)
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("Keychain add failed for \(account, privacy: .public): \(addStatus)")
            }
            return
        }

        logger.error("Keychain update failed for \(account, privacy: .public): \(updateStatus)")
    }
}
