# 润色提供方扩展（豆包 / ARK）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 Ollama 本地润色之外新增豆包（ByteDance ARK）作为可选的远端润色提供方,UI 支持互斥切换,api-key 走 Keychain。

**Architecture:** 把 `OllamaTextPolisher` 抽象为 `TranscriptPolishing` 协议;`OllamaPolisher` 与新增 `ArkPolisher` 实现该协议;偏好对象 `OllamaPreferences` 改名扩展为 `PolishPreferences`,持有 `providerKind` 和两套连接配置加共享 prompt;UI 页面 `PolishPage` 顶部新增"提供方"分段切换。

**Tech Stack:** Swift 5.9+ / SwiftUI / Combine / Foundation URLSession / macOS Security 框架(Keychain) / Swift Testing(`@Test`)。

**项目特性:** 项目使用 Xcode 的 `PBXFileSystemSynchronizedRootGroup`,新增/改名文件会被 Xcode 自动纳入 build,无需手动修改 `vbcc-mac.xcodeproj/project.pbxproj`。

---

## 文件结构

新建:
- `vbcc-mac/Services/PolishProvider.swift` — `PolishProviderKind` enum、`TranscriptPolishing` 协议、共享守护提示常量 `polishGuardSuffix`
- `vbcc-mac/Services/ArkPolisher.swift` — 豆包 / ARK 实现
- `vbcc-mac/Services/KeychainStore.swift` — 极简 Keychain 字符串存取封装

改名:
- `vbcc-mac/Services/OllamaTextPolisher.swift` → `vbcc-mac/Services/OllamaPolisher.swift`(类型同名改 `OllamaPolisher`)
- `vbcc-mac/Services/OllamaPreferences.swift` → `vbcc-mac/Services/PolishPreferences.swift`(类型 `PolishPreferences`)
- `vbcc-mac/Views/OllamaPage.swift` → `vbcc-mac/Views/PolishPage.swift`(类型 `PolishPage`)

修改:
- `vbcc-mac/ContentView.swift` — `SidebarItem.ollama` → `.polish`,title `"Ollama"` → `"模型配置"`,detail 使用 `PolishPage`,Preview 用 `PolishPreferences()`
- `vbcc-mac/vbcc_macApp.swift` — `OllamaPreferences` → `PolishPreferences`,环境对象同步
- `vbcc-mac/Networking/VBCCServer.swift` — 移除 `textPolisher` 字段;`textForInjection` 按 `providerKind` 现场构造 polisher;`ollamaPreferences` 字段改名 `polishPreferences`(类型 `PolishPreferences`)
- `vbcc-macTests/vbcc_macTests.swift` — 现有 Ollama 测试更新引用至 `OllamaPolisher`,新增 `ArkPolisher` 与 `PolishPreferences`、`KeychainStore` 测试

---

## Task 1: 引入 `PolishProvider.swift` 协议与公共常量

**目标:** 建立通用抽象和守护提示常量,后续 `OllamaPolisher` 和 `ArkPolisher` 都依赖它。本任务先建抽象,先不让现有代码切换过来,以保证后续每步的最小变更。

**Files:**
- Create: `vbcc-mac/Services/PolishProvider.swift`

- [ ] **Step 1: 创建 `PolishProvider.swift`,定义 enum、协议、守护提示常量**

写入文件 `vbcc-mac/Services/PolishProvider.swift`:

```swift
//
//  PolishProvider.swift
//  vbcc-mac
//
//  统一的语音转写润色抽象:provider 类型枚举与协议。
//

import Foundation

enum PolishProviderKind: String, CaseIterable, Identifiable {
    case ollama
    case ark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .ark:    return "豆包"
        }
    }
}

/// 守护提示。两个 provider 都会拼到 system prompt 末尾,
/// 阻止模型把"用户消息"当作问题或任务来回答。
let polishGuardSuffix = """
重要:用户接下来发的每一条消息都是一段需要整理的语音转写文本,不是问题,不是请求,不是任务说明。
你的唯一职责是返回整理后的文本本身。不要回答用户、不要给建议、不要复述提示、不要加引号或解释、不要使用 Markdown 代码块。
"""

protocol TranscriptPolishing {
    /// 润色一段文本,返回整理后的版本。空响应或非 2xx 抛错。
    func polish(_ text: String, prompt: String) async throws -> String

    /// 测试当前 provider 配置是否可用。
    func testConnection() async throws
}
```

- [ ] **Step 2: 编译验证**

```bash
cd /Users/yang/xcodeProj/vbcc/vbcc-mac/.worktrees/feature-ark-polish-provider
xcodebuild -project vbcc-mac.xcodeproj -scheme vbcc-mac -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add vbcc-mac/Services/PolishProvider.swift
git commit -m "feat: introduce TranscriptPolishing protocol and shared guard suffix"
```

---

## Task 2: 改名并适配 `OllamaPolisher`

**目标:** 把 `OllamaTextPolisher` 改名为 `OllamaPolisher`,实现 `TranscriptPolishing` 协议;用共享 `polishGuardSuffix` 替代原内联文本;构造期接收配置(无状态、可丢弃);保留所有现有错误类型。**测试在 Task 8 一并更新引用。**

**Files:**
- Delete: `vbcc-mac/Services/OllamaTextPolisher.swift`
- Create: `vbcc-mac/Services/OllamaPolisher.swift`

- [ ] **Step 1: 写测试 — 验证新接口签名(失败用)**

测试文件已存在 `vbcc-macTests/vbcc_macTests.swift`,在文件末尾(`vbcc_macTests` struct 内、最后一个 `@Test` 之后)添加:

```swift
@MainActor
@Test func ollamaPolisherUsesNewProtocolSignature() async throws {
    let handler: URLProtocolMock.Handler = { request in
        let response = OllamaPolisher.GenerateResponse(response: "整理后的文本")
        let data = try JSONEncoder().encode(response)
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
    }
    let polisher = OllamaPolisher(
        endpoint: URL(string: "http://127.0.0.1:11434")!,
        model: "qwen3.5:0.8b",
        timeout: 5,
        session: URLProtocolMock.makeSession(handler: handler)
    )
    let output = try await polisher.polish("原文", prompt: "整理文本")
    #expect(output == "整理后的文本")
}
```

- [ ] **Step 2: 删除旧文件**

```bash
rm vbcc-mac/Services/OllamaTextPolisher.swift
```

(此时项目临时不可编译,Task 2 末尾恢复。这是预期。)

- [ ] **Step 3: 创建 `OllamaPolisher.swift`**

写入 `vbcc-mac/Services/OllamaPolisher.swift`:

```swift
//
//  OllamaPolisher.swift
//  vbcc-mac
//
//  Ollama `/api/generate` 实现,无状态,接收连接参数构造。
//

import Foundation

nonisolated final class OllamaPolisher: TranscriptPolishing {
    struct GenerateRequest: Codable, Equatable {
        let model: String
        let system: String
        let prompt: String
        let think: Bool
        let stream: Bool
    }

    struct GenerateResponse: Codable, Equatable {
        let response: String
    }

    enum Error: Swift.Error, Equatable {
        case invalidConfiguration
        case invalidHTTPStatus(Int)
        case emptyResponse
        case modelNotFound(String)
    }

    private let endpoint: URL
    private let model: String
    private let timeout: TimeInterval
    private let session: URLSession

    init(endpoint: URL, model: String, timeout: TimeInterval, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.model = model
        self.timeout = timeout
        self.session = session
    }

    func polish(_ text: String, prompt: String) async throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty, !trimmedPrompt.isEmpty else {
            throw Error.invalidConfiguration
        }

        let payload = GenerateRequest(
            model: trimmedModel,
            system: "\(trimmedPrompt)\n\n\(polishGuardSuffix)",
            prompt: text,
            think: false,
            stream: false
        )

        var request = URLRequest(url: endpoint.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Error.invalidHTTPStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        let polished = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else { throw Error.emptyResponse }
        return polished
    }

    func testConnection() async throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { throw Error.invalidConfiguration }

        var request = URLRequest(url: endpoint.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": trimmedModel])

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 404 { throw Error.modelNotFound(trimmedModel) }
        if !(200...299).contains(http.statusCode) {
            throw Error.invalidHTTPStatus(http.statusCode)
        }
    }
}
```

注意:此时 `VBCCServer` 还在引用 `OllamaTextPolisher`,无法编译。下一步统一适配。

- [ ] **Step 4: 修改 `VBCCServer.swift`,临时直接持有 `OllamaPolisher`**

打开 `vbcc-mac/Networking/VBCCServer.swift`,改三处:

第 45 行:
```swift
let ollamaPreferences: OllamaPreferences
```
保持不变(本任务不动 Preferences,Task 4 再处理)。

第 48 行:
```swift
private let textPolisher: OllamaTextPolisher
```
改为:
```swift
// textPolisher 字段移除,运行时构造
```
即删除整行。

第 76-86 行的 init:
```swift
init(
    tokens: TokenStore,
    ollamaPreferences: OllamaPreferences = OllamaPreferences(),
    transcripts: TranscriptStore? = nil,
    textPolisher: OllamaTextPolisher = OllamaTextPolisher()
) {
    self.tokens = tokens
    self.ollamaPreferences = ollamaPreferences
    self.transcripts = transcripts ?? MainActor.assumeIsolated { TranscriptStore() }
    self.textPolisher = textPolisher
}
```
改为:
```swift
init(
    tokens: TokenStore,
    ollamaPreferences: OllamaPreferences = OllamaPreferences(),
    transcripts: TranscriptStore? = nil
) {
    self.tokens = tokens
    self.ollamaPreferences = ollamaPreferences
    self.transcripts = transcripts ?? MainActor.assumeIsolated { TranscriptStore() }
}
```

第 475-497 行的 `textForInjection`:
```swift
private func textForInjection(original text: String) async -> (text: String, polished: Bool) {
    guard let configuration = ollamaPreferences.configuration, configuration.enabled else {
        return (text, false)
    }

    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return (text, false)
    }

    do {
        let polished = try await textPolisher.polish(text, configuration: configuration)
        if polished != text {
            appendLog("🪄 Ollama 已整理语音文本")
            return (polished, true)
        } else {
            appendLog("🪄 Ollama 返回原文")
            return (polished, false)
        }
    } catch {
        appendLog("⚠️ Ollama 整理失败,使用原文:\(error)")
        return (text, false)
    }
}
```
改为:
```swift
private func textForInjection(original text: String) async -> (text: String, polished: Bool) {
    guard let configuration = ollamaPreferences.configuration, configuration.enabled else {
        return (text, false)
    }

    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return (text, false)
    }

    let polisher = OllamaPolisher(
        endpoint: configuration.endpoint,
        model: configuration.model,
        timeout: configuration.timeout
    )

    do {
        let polished = try await polisher.polish(text, prompt: configuration.prompt)
        if polished != text {
            appendLog("🪄 Ollama 已整理语音文本")
            return (polished, true)
        } else {
            appendLog("🪄 Ollama 返回原文")
            return (polished, false)
        }
    } catch {
        appendLog("⚠️ Ollama 整理失败,使用原文:\(error)")
        return (text, false)
    }
}
```

- [ ] **Step 5: 更新现有测试中 `OllamaTextPolisher` 引用**

打开 `vbcc-macTests/vbcc_macTests.swift`,把所有 `OllamaTextPolisher` 替换为 `OllamaPolisher`,且老测试调用方式也要适配新接口:

第 24 行:
```swift
let payload = try JSONDecoder().decode(OllamaTextPolisher.GenerateRequest.self, from: body)
```
→
```swift
let payload = try JSONDecoder().decode(OllamaPolisher.GenerateRequest.self, from: body)
```

第 32 行:
```swift
let response = OllamaTextPolisher.GenerateResponse(response: "\n今天 meeting 改到三点。\n")
```
→
```swift
let response = OllamaPolisher.GenerateResponse(response: "\n今天 meeting 改到三点。\n")
```

第 37-46 行 `polisher` 构造与调用:
```swift
let polisher = OllamaTextPolisher(session: URLProtocolMock.makeSession(handler: handler))
let config = OllamaConfiguration(
    enabled: true,
    endpoint: URL(string: "http://127.0.0.1:11434")!,
    model: "qwen3.5:0.8b",
    prompt: "修正错别字,保留中英双语表达。",
    timeout: 5
)

let output = try await polisher.polish("呃今天meetng改到三点", configuration: config)
```
→
```swift
let polisher = OllamaPolisher(
    endpoint: URL(string: "http://127.0.0.1:11434")!,
    model: "qwen3.5:0.8b",
    timeout: 5,
    session: URLProtocolMock.makeSession(handler: handler)
)
let output = try await polisher.polish("呃今天meetng改到三点", prompt: "修正错别字,保留中英双语表达。")
```

注意:此时该测试中 `payload.prompt.contains("修正错别字")` 会失败,因为新接口里"prompt"参数变成了 system 字段内容,而 `payload.prompt` 现在是 user 输入文本。把这两条 `#expect` 调整为:

```swift
#expect(payload.system.contains("修正错别字"))
#expect(payload.prompt.contains("呃今天meetng改到三点"))
```

第 52-65 行的 invalidConfiguration 测试:
```swift
let polisher = OllamaTextPolisher(session: URLSession(configuration: .ephemeral))
let config = OllamaConfiguration(
    enabled: true,
    endpoint: URL(string: "http://127.0.0.1:11434")!,
    model: "   ",
    prompt: "整理文本",
    timeout: 5
)

await #expect(throws: OllamaTextPolisher.Error.invalidConfiguration) {
    try await polisher.polish("原文", configuration: config)
}
```
→
```swift
let polisher = OllamaPolisher(
    endpoint: URL(string: "http://127.0.0.1:11434")!,
    model: "   ",
    timeout: 5,
    session: URLSession(configuration: .ephemeral)
)

await #expect(throws: OllamaPolisher.Error.invalidConfiguration) {
    try await polisher.polish("原文", prompt: "整理文本")
}
```

注意:此时 `OllamaConfiguration` 类型在 `OllamaPreferences.swift` 里仍然存在(Task 4 才会动它),所以删除测试中对它的引用即可,不要动其它文件。

- [ ] **Step 6: 编译并跑测试**

```bash
cd /Users/yang/xcodeProj/vbcc/vbcc-mac/.worktrees/feature-ark-polish-provider
xcodebuild -project vbcc-mac.xcodeproj -scheme vbcc-mac -configuration Debug -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: 全部 PASS,包括新加的 `ollamaPolisherUsesNewProtocolSignature` 与 2 个改造后的旧测试。

- [ ] **Step 7: 提交**

```bash
git add vbcc-mac/Services/OllamaPolisher.swift vbcc-mac/Networking/VBCCServer.swift vbcc-macTests/vbcc_macTests.swift
git rm vbcc-mac/Services/OllamaTextPolisher.swift
git commit -m "refactor: rename OllamaTextPolisher to OllamaPolisher implementing TranscriptPolishing"
```

---

## Task 3: 引入 `KeychainStore.swift`

**目标:** macOS Keychain 字符串存取的极简封装,供 ArkPolisher / PolishPage 使用。

**Files:**
- Create: `vbcc-mac/Services/KeychainStore.swift`
- Test: `vbcc-macTests/vbcc_macTests.swift`(新增测试)

- [ ] **Step 1: 写测试(失败用)**

在 `vbcc-macTests/vbcc_macTests.swift` 末尾添加:

```swift
@MainActor
@Test func keychainStoreSetGetDeleteRoundTrip() async throws {
    let testAccount = "vbcc.tests.keychain.\(UUID().uuidString)"
    defer { KeychainStore.set(nil, forAccount: testAccount) }

    KeychainStore.set("hello", forAccount: testAccount)
    #expect(KeychainStore.get(forAccount: testAccount) == "hello")

    KeychainStore.set("world", forAccount: testAccount)
    #expect(KeychainStore.get(forAccount: testAccount) == "world")

    KeychainStore.set(nil, forAccount: testAccount)
    #expect(KeychainStore.get(forAccount: testAccount) == nil)
}
```

- [ ] **Step 2: 跑测试,确认失败**

```bash
xcodebuild -project vbcc-mac.xcodeproj -scheme vbcc-mac -configuration Debug -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: 编译失败 — `KeychainStore` 未定义。

- [ ] **Step 3: 创建 `KeychainStore.swift`**

写入 `vbcc-mac/Services/KeychainStore.swift`:

```swift
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
```

- [ ] **Step 4: 跑测试,确认通过**

```bash
xcodebuild -project vbcc-mac.xcodeproj -scheme vbcc-mac -configuration Debug -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: 全部 PASS,新加的 `keychainStoreSetGetDeleteRoundTrip` 也通过。

(macOS 测试 host 进程会触发钥匙串访问;首次运行可能弹窗。这是预期。)

- [ ] **Step 5: 提交**

```bash
git add vbcc-mac/Services/KeychainStore.swift vbcc-macTests/vbcc_macTests.swift
git commit -m "feat: add minimal KeychainStore wrapper for keychain-backed secrets"
```

---

## Task 4: 改名扩展 `OllamaPreferences` → `PolishPreferences`

**目标:** 替换偏好对象,新增 `providerKind` / `arkBaseURL` / `arkModel`,Ollama 字段改名 `ollamaEndpoint` / `ollamaModel`,prompt 与 timeout 共享。沿用老 UserDefaults 键名做平滑迁移。`OllamaConfiguration` 也迁出新文件。

**Files:**
- Delete: `vbcc-mac/Services/OllamaPreferences.swift`
- Create: `vbcc-mac/Services/PolishPreferences.swift`
- Modify: `vbcc-mac/Networking/VBCCServer.swift`
- Modify: `vbcc-mac/vbcc_macApp.swift`
- Modify: `vbcc-mac/ContentView.swift`
- Modify: `vbcc-mac/Views/OllamaPage.swift`(本步只为编译通过做最小适配,Task 6 会再大改)

- [ ] **Step 1: 写测试(失败用) — `PolishPreferences` 默认值与持久化**

在 `vbcc-macTests/vbcc_macTests.swift` 末尾添加:

```swift
@MainActor
@Test func polishPreferencesDefaultsAndProviderPersistence() async throws {
    let suiteName = "vbcc.tests.prefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let prefs = PolishPreferences(defaults: defaults)
    #expect(prefs.isEnabled == false)
    #expect(prefs.providerKind == .ollama)
    #expect(prefs.ollamaEndpoint == "http://127.0.0.1:11434")
    #expect(prefs.ollamaModel == "qwen3.5:0.8b")
    #expect(prefs.arkBaseURL == "https://ark.cn-beijing.volces.com/api/v3")
    #expect(prefs.arkModel == "")
    #expect(prefs.timeout == 5)

    prefs.providerKind = .ark
    prefs.arkBaseURL = "https://example.com/api/v3/"
    prefs.arkModel = "doubao-test"

    let reloaded = PolishPreferences(defaults: defaults)
    #expect(reloaded.providerKind == .ark)
    #expect(reloaded.arkBaseURL == "https://example.com/api/v3/")
    #expect(reloaded.arkModel == "doubao-test")
}

@MainActor
@Test func polishPreferencesReadsLegacyOllamaKeys() async throws {
    let suiteName = "vbcc.tests.prefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // 模拟老用户已存的 Ollama 配置(老键名)
    defaults.set(true, forKey: "vbcc.ollama.enabled")
    defaults.set("http://localhost:11434", forKey: "vbcc.ollama.endpoint")
    defaults.set("custom-model", forKey: "vbcc.ollama.model")
    defaults.set("我的自定义 prompt", forKey: "vbcc.ollama.prompt")
    defaults.set(20.0, forKey: "vbcc.ollama.timeout")

    let prefs = PolishPreferences(defaults: defaults)
    #expect(prefs.isEnabled == true)
    #expect(prefs.providerKind == .ollama)  // 缺省
    #expect(prefs.ollamaEndpoint == "http://localhost:11434")
    #expect(prefs.ollamaModel == "custom-model")
    #expect(prefs.prompt == "我的自定义 prompt")
    #expect(prefs.timeout == 20.0)
}

@MainActor
@Test func polishPreferencesArkConfigRequiresKeychainKey() async throws {
    let suiteName = "vbcc.tests.prefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let testAccount = "vbcc.tests.ark.key.\(UUID().uuidString)"
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        KeychainStore.set(nil, forAccount: testAccount)
    }

    let prefs = PolishPreferences(defaults: defaults, arkAPIKeyAccount: testAccount)
    prefs.providerKind = .ark
    prefs.arkBaseURL = "https://ark.cn-beijing.volces.com/api/v3"
    prefs.arkModel = "doubao-test"

    #expect(prefs.arkConfig == nil)  // 还没存 key

    KeychainStore.set("sk-test", forAccount: testAccount)
    let cfg = prefs.arkConfig
    #expect(cfg?.apiKey == "sk-test")
    #expect(cfg?.model == "doubao-test")
    #expect(cfg?.baseURL.absoluteString == "https://ark.cn-beijing.volces.com/api/v3")
    #expect(cfg?.timeout == 5)
}
```

- [ ] **Step 2: 删除旧 `OllamaPreferences.swift`**

```bash
git rm vbcc-mac/Services/OllamaPreferences.swift
```

(此时项目临时不可编译。)

- [ ] **Step 3: 创建 `PolishPreferences.swift`**

写入 `vbcc-mac/Services/PolishPreferences.swift`:

```swift
//
//  PolishPreferences.swift
//  vbcc-mac
//
//  统一的润色偏好:总开关 / provider 切换 / 共享 prompt+timeout / 各 provider 子配置。
//  老 UserDefaults 键名复用,实现零迁移升级。
//

import Foundation
import Combine

nonisolated struct OllamaConfiguration: Equatable {
    var enabled: Bool
    var endpoint: URL
    var model: String
    var prompt: String
    var timeout: TimeInterval
}

nonisolated struct ArkConfiguration: Equatable {
    var enabled: Bool
    var baseURL: URL
    var apiKey: String
    var model: String
    var prompt: String
    var timeout: TimeInterval
}

final class PolishPreferences: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    @Published var providerKind: PolishProviderKind {
        didSet { defaults.set(providerKind.rawValue, forKey: Keys.providerKind) }
    }

    @Published var prompt: String {
        didSet { defaults.set(prompt, forKey: Keys.prompt) }
    }

    @Published var timeout: Double {
        didSet { defaults.set(timeout, forKey: Keys.timeout) }
    }

    @Published var ollamaEndpoint: String {
        didSet { defaults.set(ollamaEndpoint, forKey: Keys.ollamaEndpoint) }
    }

    @Published var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: Keys.ollamaModel) }
    }

    @Published var arkBaseURL: String {
        didSet { defaults.set(arkBaseURL, forKey: Keys.arkBaseURL) }
    }

    @Published var arkModel: String {
        didSet { defaults.set(arkModel, forKey: Keys.arkModel) }
    }

    /// API key 不进 @Published,通过专用 getter/setter 走 Keychain。
    var arkAPIKey: String {
        get { KeychainStore.get(forAccount: arkAPIKeyAccount) ?? "" }
        set { KeychainStore.set(newValue.isEmpty ? nil : newValue, forAccount: arkAPIKeyAccount) }
    }

    private let defaults: UserDefaults
    private let arkAPIKeyAccount: String

    init(defaults: UserDefaults = .standard, arkAPIKeyAccount: String = "vbcc.ark.apiKey") {
        self.defaults = defaults
        self.arkAPIKeyAccount = arkAPIKeyAccount

        self.isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? false

        if let raw = defaults.string(forKey: Keys.providerKind),
           let kind = PolishProviderKind(rawValue: raw) {
            self.providerKind = kind
        } else {
            self.providerKind = .ollama
        }

        self.prompt = defaults.string(forKey: Keys.prompt) ?? Self.defaultPrompt
        let storedTimeout = defaults.double(forKey: Keys.timeout)
        self.timeout = storedTimeout > 0 ? storedTimeout : 5

        self.ollamaEndpoint = defaults.string(forKey: Keys.ollamaEndpoint) ?? "http://127.0.0.1:11434"
        self.ollamaModel = defaults.string(forKey: Keys.ollamaModel) ?? "qwen3.5:0.8b"

        self.arkBaseURL = defaults.string(forKey: Keys.arkBaseURL) ?? "https://ark.cn-beijing.volces.com/api/v3"
        self.arkModel = defaults.string(forKey: Keys.arkModel) ?? ""
    }

    /// 当前选定 provider 是否处于"配置可用"状态(总开关已开 + 必填齐全)。
    var isReady: Bool {
        guard isEnabled else { return false }
        switch providerKind {
        case .ollama: return ollamaConfig != nil
        case .ark:    return arkConfig != nil
        }
    }

    /// Ollama 子配置;字段非法返回 nil。
    var ollamaConfig: OllamaConfiguration? {
        let trimmedEndpoint = ollamaEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty,
              let url = URL(string: trimmedEndpoint) else { return nil }
        return OllamaConfiguration(
            enabled: isEnabled,
            endpoint: url,
            model: trimmedModel,
            prompt: prompt,
            timeout: timeout
        )
    }

    /// 豆包子配置;baseURL/model/key 任一缺失返回 nil。
    var arkConfig: ArkConfiguration? {
        let trimmedBase = arkBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = arkModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = arkAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty, !key.isEmpty,
              let url = URL(string: trimmedBase) else { return nil }
        return ArkConfiguration(
            enabled: isEnabled,
            baseURL: url,
            apiKey: key,
            model: trimmedModel,
            prompt: prompt,
            timeout: timeout
        )
    }

    static let defaultPrompt = """
    你是语音转写文本整理助手。请将 iOS 端发来的语音文字整理为可直接发送或粘贴的文本:
    - 修正明显错别字、同音词、英文单词识别错误和中英双语夹杂错误。
    - 去除"嗯、啊、呃、就是、那个"等口语化语气词。
    - 在不改变原意的前提下整理标点、空格、大小写和段落格式。
    - 保留用户原本想表达的语言风格,不扩写,不补充事实。
    """

    private enum Keys {
        // 沿用老键,实现零迁移
        static let isEnabled = "vbcc.ollama.enabled"
        static let prompt = "vbcc.ollama.prompt"
        static let timeout = "vbcc.ollama.timeout"
        static let ollamaEndpoint = "vbcc.ollama.endpoint"
        static let ollamaModel = "vbcc.ollama.model"

        // 新增键
        static let providerKind = "vbcc.polish.provider"
        static let arkBaseURL = "vbcc.ark.baseURL"
        static let arkModel = "vbcc.ark.model"
    }
}
```

- [ ] **Step 4: 适配 `vbcc_macApp.swift`**

打开 `vbcc-mac/vbcc_macApp.swift`,把所有 `OllamaPreferences` 替换为 `PolishPreferences`,环境对象的标识符 `ollama` 改为 `polish`(避免类型与变量名混淆):

```swift
@StateObject private var polish: PolishPreferences

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
}
```

- [ ] **Step 5: 适配 `VBCCServer.swift`**

在 `vbcc-mac/Networking/VBCCServer.swift` 中:

第 45 行 `let ollamaPreferences: OllamaPreferences` → `let polishPreferences: PolishPreferences`

init 方法(目前是)
```swift
init(
    tokens: TokenStore,
    ollamaPreferences: OllamaPreferences = OllamaPreferences(),
    transcripts: TranscriptStore? = nil
) {
    self.tokens = tokens
    self.ollamaPreferences = ollamaPreferences
    self.transcripts = transcripts ?? MainActor.assumeIsolated { TranscriptStore() }
}
```
改为:
```swift
init(
    tokens: TokenStore,
    polishPreferences: PolishPreferences = PolishPreferences(),
    transcripts: TranscriptStore? = nil
) {
    self.tokens = tokens
    self.polishPreferences = polishPreferences
    self.transcripts = transcripts ?? MainActor.assumeIsolated { TranscriptStore() }
}
```

`textForInjection` 现在引用 `ollamaPreferences.configuration`,改为基于 `polishPreferences.ollamaConfig`(本任务暂时只支持 Ollama,Task 5 加豆包分支):

```swift
private func textForInjection(original text: String) async -> (text: String, polished: Bool) {
    guard polishPreferences.isEnabled else { return (text, false) }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return (text, false)
    }

    switch polishPreferences.providerKind {
    case .ollama:
        guard let cfg = polishPreferences.ollamaConfig else {
            appendLog("⚠️ Ollama 配置不完整,跳过整理")
            return (text, false)
        }
        let polisher = OllamaPolisher(
            endpoint: cfg.endpoint,
            model: cfg.model,
            timeout: cfg.timeout
        )
        return await runPolish(polisher: polisher, prompt: cfg.prompt, text: text, label: "Ollama")
    case .ark:
        // Task 5 接入
        appendLog("⚠️ 豆包 provider 尚未接入,使用原文")
        return (text, false)
    }
}

private func runPolish(polisher: TranscriptPolishing, prompt: String, text: String, label: String) async -> (text: String, polished: Bool) {
    do {
        let polished = try await polisher.polish(text, prompt: prompt)
        if polished != text {
            appendLog("🪄 \(label) 已整理语音文本")
            return (polished, true)
        } else {
            appendLog("🪄 \(label) 返回原文")
            return (polished, false)
        }
    } catch {
        appendLog("⚠️ \(label) 整理失败,使用原文:\(error)")
        return (text, false)
    }
}
```

- [ ] **Step 6: `ContentView.swift` 暂只改 Preview 引用**

```swift
.environmentObject(OllamaPreferences())
```
→
```swift
.environmentObject(PolishPreferences())
```

侧边栏 case 与页面切换 Task 6 处理。本任务保持 `OllamaPage`(Task 6 才改名)。

- [ ] **Step 7: `OllamaPage.swift` 内最小适配以编译通过**

打开 `vbcc-mac/Views/OllamaPage.swift`:

```swift
@EnvironmentObject private var ollama: OllamaPreferences
```
→
```swift
@EnvironmentObject private var polish: PolishPreferences
```

把文件中所有 `ollama.isEnabled` / `ollama.endpointText` / `ollama.model` / `ollama.timeout` / `ollama.prompt` 引用同步改为:
- `ollama.isEnabled` → `polish.isEnabled`
- `ollama.endpointText` → `polish.ollamaEndpoint`
- `ollama.model` → `polish.ollamaModel`
- `ollama.timeout` → `polish.timeout`
- `ollama.prompt` → `polish.prompt`
- `ollama.configuration` → `polish.ollamaConfig`(在 `runConnectionTest` 中)
- `OllamaPreferences.defaultPrompt` → `PolishPreferences.defaultPrompt`

`runConnectionTest` 中的 polisher 构造:
```swift
let polisher = OllamaTextPolisher()
do {
    try await polisher.testConnection(configuration: configuration)
    ...
```
此时 `OllamaTextPolisher` 已不存在(Task 2 改名),且 `testConnection` 接口变了。改为:
```swift
let polisher = OllamaPolisher(
    endpoint: configuration.endpoint,
    model: configuration.model,
    timeout: configuration.timeout
)
do {
    try await polisher.testConnection()
    ...
```

`describe(error:)` 中的 `OllamaTextPolisher.Error` → `OllamaPolisher.Error`(全局替换)。

注意:`OllamaConfiguration` 仍在用,Task 4 已把它迁到 `PolishPreferences.swift`,引用不需改。

- [ ] **Step 8: 编译并跑测试**

```bash
cd /Users/yang/xcodeProj/vbcc/vbcc-mac/.worktrees/feature-ark-polish-provider
xcodebuild -project vbcc-mac.xcodeproj -scheme vbcc-mac -configuration Debug -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: 全部 PASS,新加的 3 个 `polishPreferences*` 测试也通过。

- [ ] **Step 9: 提交**

```bash
git add vbcc-mac/Services/PolishPreferences.swift vbcc-mac/vbcc_macApp.swift vbcc-mac/ContentView.swift vbcc-mac/Networking/VBCCServer.swift vbcc-mac/Views/OllamaPage.swift vbcc-macTests/vbcc_macTests.swift
git commit -m "refactor: rename OllamaPreferences to PolishPreferences with provider kind"
```

---

## Task 5: 实现 `ArkPolisher`

**目标:** 新增豆包 provider 实现,支持 OpenAI 兼容 chat/completions 协议;接入 `VBCCServer.textForInjection` 的 `.ark` 分支。

**Files:**
- Create: `vbcc-mac/Services/ArkPolisher.swift`
- Modify: `vbcc-mac/Networking/VBCCServer.swift`
- Test: `vbcc-macTests/vbcc_macTests.swift`

- [ ] **Step 1: 写测试 — `ArkPolisher` 请求格式与 Bearer 认证**

在 `vbcc-macTests/vbcc_macTests.swift` 末尾添加:

```swift
@MainActor
@Test func arkPolisherSendsBearerAuthAndOpenAICompatibleRequest() async throws {
    let handler: URLProtocolMock.Handler = { request in
        #expect(request.url?.absoluteString == "https://example.com/api/v3/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        guard let body = request.httpBody ?? request.httpBodyStream?.readAllData() else {
            Issue.record("Request body should be present")
            throw URLError(.badServerResponse)
        }
        let payload = try JSONDecoder().decode(ArkPolisher.ChatRequest.self, from: body)

        #expect(payload.model == "doubao-test")
        #expect(payload.stream == false)
        #expect(payload.messages.count == 2)
        #expect(payload.messages[0].role == "system")
        #expect(payload.messages[0].content.contains("整理文本"))
        #expect(payload.messages[0].content.contains("整理后的文本"))  // polishGuardSuffix 片段
        #expect(payload.messages[1].role == "user")
        #expect(payload.messages[1].content == "原文")

        let response = ArkPolisher.ChatResponse(
            choices: [.init(message: .init(role: "assistant", content: "  整理后的内容  "))]
        )
        let data = try JSONEncoder().encode(response)
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
    }

    let polisher = ArkPolisher(
        baseURL: URL(string: "https://example.com/api/v3/")!,  // 末尾 / 应被清掉
        apiKey: "sk-secret",
        model: "doubao-test",
        timeout: 5,
        session: URLProtocolMock.makeSession(handler: handler)
    )

    let output = try await polisher.polish("原文", prompt: "整理文本")
    #expect(output == "整理后的内容")
}

@MainActor
@Test func arkPolisherMaps401ToUnauthorized() async throws {
    let handler: URLProtocolMock.Handler = { request in
        let body = "{\"error\":{\"message\":\"unauthorized\"}}".data(using: .utf8)!
        return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, body)
    }
    let polisher = ArkPolisher(
        baseURL: URL(string: "https://example.com/api/v3")!,
        apiKey: "bad",
        model: "doubao-test",
        timeout: 5,
        session: URLProtocolMock.makeSession(handler: handler)
    )

    await #expect(throws: ArkPolisher.Error.unauthorized) {
        try await polisher.polish("原文", prompt: "整理文本")
    }
}

@MainActor
@Test func arkPolisherMaps404ToModelNotFound() async throws {
    let handler: URLProtocolMock.Handler = { request in
        let body = Data()
        return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, body)
    }
    let polisher = ArkPolisher(
        baseURL: URL(string: "https://example.com/api/v3")!,
        apiKey: "sk",
        model: "ghost-model",
        timeout: 5,
        session: URLProtocolMock.makeSession(handler: handler)
    )

    await #expect(throws: ArkPolisher.Error.modelNotFound("ghost-model")) {
        try await polisher.polish("原文", prompt: "整理文本")
    }
}

@MainActor
@Test func arkPolisherRejectsEmptyConfigurationBeforeNetwork() async throws {
    let polisher = ArkPolisher(
        baseURL: URL(string: "https://example.com/api/v3")!,
        apiKey: "",
        model: "doubao-test",
        timeout: 5,
        session: URLSession(configuration: .ephemeral)
    )
    await #expect(throws: ArkPolisher.Error.invalidConfiguration) {
        try await polisher.polish("原文", prompt: "整理文本")
    }
}
```

注意 `polishGuardSuffix` 中含有"整理后的文本本身"短语,因此 `contains("整理后的文本")` 会命中守护提示;这正是测试想验证的拼接。

- [ ] **Step 2: 跑测试,确认失败**

Expected: 编译失败 — `ArkPolisher` 未定义。

- [ ] **Step 3: 创建 `ArkPolisher.swift`**

写入 `vbcc-mac/Services/ArkPolisher.swift`:

```swift
//
//  ArkPolisher.swift
//  vbcc-mac
//
//  豆包(ByteDance ARK)实现:OpenAI 兼容 chat/completions + Bearer 认证。
//

import Foundation

nonisolated final class ArkPolisher: TranscriptPolishing {
    struct Message: Codable, Equatable {
        let role: String
        let content: String
    }

    struct ChatRequest: Codable, Equatable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let max_tokens: Int?
    }

    struct Choice: Codable, Equatable {
        let message: Message
    }

    struct ChatResponse: Codable, Equatable {
        let choices: [Choice]
    }

    enum Error: Swift.Error, Equatable {
        case invalidConfiguration
        case unauthorized
        case modelNotFound(String)
        case invalidHTTPStatus(Int)
        case emptyResponse
    }

    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let timeout: TimeInterval
    private let session: URLSession

    init(baseURL: URL, apiKey: String, model: String, timeout: TimeInterval, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.session = session
    }

    func polish(_ text: String, prompt: String) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedModel.isEmpty, !trimmedPrompt.isEmpty else {
            throw Error.invalidConfiguration
        }

        let payload = ChatRequest(
            model: trimmedModel,
            messages: [
                Message(role: "system", content: "\(trimmedPrompt)\n\n\(polishGuardSuffix)"),
                Message(role: "user", content: text)
            ],
            stream: false,
            max_tokens: nil
        )

        let request = try buildRequest(body: try JSONEncoder().encode(payload))
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, model: trimmedModel)

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = decoded.choices.first?.message.content ?? ""
        let polished = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else { throw Error.emptyResponse }
        return polished
    }

    func testConnection() async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedModel.isEmpty else {
            throw Error.invalidConfiguration
        }

        let payload = ChatRequest(
            model: trimmedModel,
            messages: [Message(role: "user", content: "ping")],
            stream: false,
            max_tokens: 1
        )

        let request = try buildRequest(body: try JSONEncoder().encode(payload))
        let (_, response) = try await session.data(for: request)
        try Self.validate(response: response, model: trimmedModel)
    }

    private func buildRequest(body: Data) throws -> URLRequest {
        let normalized = Self.endpointURL(baseURL: baseURL)
        var request = URLRequest(url: normalized)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    /// 规范化 baseURL,去掉尾部 `/`,然后拼 `/chat/completions`。
    static func endpointURL(baseURL: URL) -> URL {
        var raw = baseURL.absoluteString
        while raw.hasSuffix("/") { raw.removeLast() }
        return URL(string: raw + "/chat/completions") ?? baseURL.appendingPathComponent("chat/completions")
    }

    private static func validate(response: URLResponse, model: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if (200...299).contains(http.statusCode) { return }
        switch http.statusCode {
        case 401: throw Error.unauthorized
        case 404: throw Error.modelNotFound(model)
        default:  throw Error.invalidHTTPStatus(http.statusCode)
        }
    }
}
```

- [ ] **Step 4: 接入 `VBCCServer.textForInjection` 的 `.ark` 分支**

打开 `vbcc-mac/Networking/VBCCServer.swift`,把 `textForInjection` 中 `case .ark` 块替换:

```swift
case .ark:
    // Task 5 接入
    appendLog("⚠️ 豆包 provider 尚未接入,使用原文")
    return (text, false)
```
→
```swift
case .ark:
    guard let cfg = polishPreferences.arkConfig else {
        appendLog("⚠️ 豆包配置不完整,跳过整理")
        return (text, false)
    }
    let polisher = ArkPolisher(
        baseURL: cfg.baseURL,
        apiKey: cfg.apiKey,
        model: cfg.model,
        timeout: cfg.timeout
    )
    return await runPolish(polisher: polisher, prompt: cfg.prompt, text: text, label: "豆包")
```

- [ ] **Step 5: 跑测试,确认通过**

```bash
xcodebuild -project vbcc-mac.xcodeproj -scheme vbcc-mac -configuration Debug -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: 全部 PASS,4 个 `arkPolisher*` 测试也通过。

- [ ] **Step 6: 提交**

```bash
git add vbcc-mac/Services/ArkPolisher.swift vbcc-mac/Networking/VBCCServer.swift vbcc-macTests/vbcc_macTests.swift
git commit -m "feat: add ArkPolisher (doubao) implementing TranscriptPolishing"
```

---

## Task 6: UI 改造 — 侧边栏改名 + provider 切换页面

**目标:** `OllamaPage` 改名为 `PolishPage`,顶部新增 provider 分段控件,Ollama / 豆包连接卡片按当前 provider 切换;Prompt 卡片共享。侧边栏 title 由"Ollama"改为"模型配置"。

**Files:**
- Delete: `vbcc-mac/Views/OllamaPage.swift`
- Create: `vbcc-mac/Views/PolishPage.swift`
- Modify: `vbcc-mac/ContentView.swift`

- [ ] **Step 1: 删除旧文件**

```bash
git rm vbcc-mac/Views/OllamaPage.swift
```

- [ ] **Step 2: 创建 `PolishPage.swift`**

写入 `vbcc-mac/Views/PolishPage.swift`:

```swift
//
//  PolishPage.swift
//  vbcc-mac
//
//  模型配置页:provider 切换(Ollama / 豆包)、连接配置、共享 prompt。
//

import SwiftUI

struct PolishPage: View {
    @EnvironmentObject private var polish: PolishPreferences
    @State private var testState: TestState = .idle
    @State private var arkAPIKey: String = ""
    @State private var showAPIKey: Bool = false
    @State private var apiKeyDebounceTask: Task<Void, Never>?

    private enum TestState: Equatable {
        case idle
        case running
        case success
        case failure(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if polish.isEnabled {
                    providerCard
                    connectionCard
                    promptCard
                } else {
                    disabledHint
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("模型配置")
        .animation(.easeInOut(duration: 0.2), value: polish.isEnabled)
        .animation(.easeInOut(duration: 0.2), value: polish.providerKind)
        .onAppear { arkAPIKey = polish.arkAPIKey }
        .onChange(of: polish.providerKind) { _, _ in
            testState = .idle
        }
        .onChange(of: arkAPIKey) { _, newValue in
            apiKeyDebounceTask?.cancel()
            apiKeyDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if !Task.isCancelled {
                    await MainActor.run { polish.arkAPIKey = newValue }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Label("模型配置", systemImage: "wand.and.sparkles")
                .font(.title3.weight(.semibold))
            Spacer()
            Toggle("启用", isOn: $polish.isEnabled)
                .toggleStyle(.switch)
        }
    }

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("提供方")
                .font(.headline)
            Picker("提供方", selection: $polish.providerKind) {
                ForEach(PolishProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接")
                .font(.headline)

            switch polish.providerKind {
            case .ollama: ollamaFields
            case .ark:    arkFields
            }

            timeoutRow

            if let message = testStatusMessage {
                HStack(spacing: 6) {
                    Image(systemName: testStatusIcon)
                        .foregroundStyle(testStatusColor)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(testStatusColor)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var ollamaFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("地址").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                TextField("http://127.0.0.1:11434", text: $polish.ollamaEndpoint)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("模型").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                HStack(spacing: 8) {
                    TextField("qwen3.5:0.8b", text: $polish.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                    testButton(disabled: polish.ollamaConfig == nil)
                }
            }
        }
    }

    private var arkFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Base URL").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                TextField("https://ark.cn-beijing.volces.com/api/v3", text: $polish.arkBaseURL)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("API Key").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                HStack(spacing: 8) {
                    if showAPIKey {
                        TextField("sk-...", text: $arkAPIKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("sk-...", text: $arkAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(action: { showAPIKey.toggle() }) {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showAPIKey ? "隐藏" : "显示")
                }
            }
            GridRow {
                Text("模型").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                HStack(spacing: 8) {
                    TextField("doubao-... 或 endpoint id", text: $polish.arkModel)
                        .textFieldStyle(.roundedBorder)
                    testButton(disabled: polish.arkConfig == nil)
                }
            }
        }
    }

    private var timeoutRow: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("超时").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                HStack {
                    Slider(value: $polish.timeout, in: 5...60, step: 1)
                    Text("\(Int(polish.timeout)) 秒")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    private func testButton(disabled: Bool) -> some View {
        Button(action: runConnectionTest) {
            if testState == .running {
                ProgressView().controlSize(.small).frame(width: 14, height: 14)
            } else {
                Text("测试")
            }
        }
        .disabled(testState == .running || disabled)
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自定义 Prompt")
                    .font(.headline)
                Spacer()
                Button("恢复默认") {
                    polish.prompt = PolishPreferences.defaultPrompt
                }
                .controlSize(.small)
            }
            Text("用于指导模型整理 iPhone 发来的语音转写文本。两个 provider 共用同一份 prompt。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $polish.prompt)
                .font(.system(.body, design: .default))
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var disabledHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("模型整理已关闭。开启后,iPhone 发来的语音文字会先经选定的模型整理,再写入当前焦点输入框。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var testStatusMessage: String? {
        switch testState {
        case .idle: return nil
        case .running: return "正在连接…"
        case .success: return "连接成功,模型可用。"
        case .failure(let reason): return reason
        }
    }

    private var testStatusIcon: String {
        switch testState {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        default: return "info.circle"
        }
    }

    private var testStatusColor: Color {
        switch testState {
        case .success: return .green
        case .failure: return .red
        default: return .secondary
        }
    }

    private func runConnectionTest() {
        testState = .running
        Task {
            let polisher: TranscriptPolishing?
            switch polish.providerKind {
            case .ollama:
                if let cfg = polish.ollamaConfig {
                    polisher = OllamaPolisher(endpoint: cfg.endpoint, model: cfg.model, timeout: cfg.timeout)
                } else { polisher = nil }
            case .ark:
                if let cfg = polish.arkConfig {
                    polisher = ArkPolisher(baseURL: cfg.baseURL, apiKey: cfg.apiKey, model: cfg.model, timeout: cfg.timeout)
                } else { polisher = nil }
            }

            guard let polisher else {
                await MainActor.run { testState = .failure("配置不完整,请检查必填项。") }
                return
            }

            do {
                try await polisher.testConnection()
                await MainActor.run { testState = .success }
            } catch {
                let reason = Self.describe(error: error)
                await MainActor.run { testState = .failure(reason) }
            }
        }
    }

    private static func describe(error: Swift.Error) -> String {
        if let e = error as? OllamaPolisher.Error {
            switch e {
            case .invalidConfiguration: return "配置不完整,请检查必填项。"
            case .modelNotFound(let m):  return "模型「\(m)」不存在,请先 ollama pull。"
            case .invalidHTTPStatus(let c): return "服务返回 HTTP \(c)。"
            case .emptyResponse: return "服务返回了空响应。"
            }
        }
        if let e = error as? ArkPolisher.Error {
            switch e {
            case .invalidConfiguration: return "配置不完整,请检查必填项。"
            case .unauthorized: return "API Key 无效或已过期。"
            case .modelNotFound(let m): return "模型「\(m)」不存在或 endpoint id 错误。"
            case .invalidHTTPStatus(let c): return "豆包服务返回 HTTP \(c)。"
            case .emptyResponse: return "服务返回了空响应。"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "连接超时,请检查地址或调高超时时间。"
            case .cannotConnectToHost, .cannotFindHost:
                return "无法连接到服务,请确认地址正确。"
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
```

- [ ] **Step 3: 改 `ContentView.swift` 侧边栏**

```swift
enum SidebarItem: Hashable, CaseIterable, Identifiable {
    case devices
    case log
    case ollama   // ← 改名

    ...

    var title: String {
        switch self {
        case .devices: return "设备"
        case .log:     return "日志"
        case .ollama:  return "Ollama"  // ← 改文案
        }
    }
}
```

替换为:
```swift
enum SidebarItem: Hashable, CaseIterable, Identifiable {
    case devices
    case log
    case polish

    var id: Self { self }

    var title: String {
        switch self {
        case .devices: return "设备"
        case .log:     return "日志"
        case .polish:  return "模型配置"
        }
    }

    var systemImage: String {
        switch self {
        case .devices: return "iphone.gen3"
        case .log:     return "text.alignleft"
        case .polish:  return "wand.and.sparkles"
        }
    }
}
```

`ContentView.body` 中:
```swift
case .ollama:  OllamaPage()
```
→
```swift
case .polish:  PolishPage()
```

- [ ] **Step 4: 编译并跑测试**

```bash
xcodebuild -project vbcc-mac.xcodeproj -scheme vbcc-mac -configuration Debug -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: 全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add vbcc-mac/Views/PolishPage.swift vbcc-mac/ContentView.swift
git commit -m "feat: rename Ollama page to 模型配置 with provider switch UI"
```

---

## Task 7: 端到端手工验证

**目标:** 在真实环境上跑 UI,确认 Ollama / 豆包 两条路径都能完成"测试连接 + 端到端润色"。代码动作只在出错时进行,默认本任务无 commit。

**Files:** 无代码改动。

- [ ] **Step 1: 启动 app**

```bash
cd /Users/yang/xcodeProj/vbcc/vbcc-mac/.worktrees/feature-ark-polish-provider
xcodebuild -project vbcc-mac.xcodeproj -scheme vbcc-mac -configuration Debug build 2>&1 | tail -5
open -a $(xcodebuild -project vbcc-mac.xcodeproj -scheme vbcc-mac -showBuildSettings 2>/dev/null | awk -F= '/ BUILT_PRODUCTS_DIR /{gsub(/ /,"",$2); print $2}' | head -1)/vbcc-mac.app
```

(如果 `open` 启动有问题,直接在 Xcode 里按 ⌘R 启动。)

- [ ] **Step 2: 验证 Ollama 路径(老用户场景)**

进入"模型配置"侧边栏,确认:
- 标题显示"模型配置"。
- 启用开关初始为关(若是干净 defaults)或保持升级前状态。
- 打开启用,顶部出现"提供方"分段,默认选中"Ollama"。
- 连接卡片显示地址 / 模型 / 超时,Prompt 卡片显示原默认 prompt。
- 输入有效地址/模型,点"测试" → 显示绿色"连接成功"。
- 在 iOS 端发一段语音,确认 Mac 端注入文本是 Ollama 整理后的版本。

- [ ] **Step 3: 验证豆包路径**

切换"提供方"到"豆包",确认:
- 连接卡片切换为 Base URL / API Key / 模型 三行;Prompt 卡片不变。
- 默认 Base URL 是 `https://ark.cn-beijing.volces.com/api/v3`。
- API Key 字段默认 SecureField,眼睛按钮可切换显示。
- 输入真实 ARK key + endpoint id → 点"测试" → 应显示绿色"连接成功"。
- 故意填错 key → "测试"显示"API Key 无效或已过期"。
- 故意填错 model → "测试"显示"模型「xxx」不存在或 endpoint id 错误"。
- 在 iOS 端发一段语音,确认 Mac 端注入文本是豆包整理后的版本(可对比 Ollama 输出风格不同)。

- [ ] **Step 4: 验证切换互斥与残留**

- 切回"Ollama" → 之前豆包卡片的"连接成功"或失败提示应消失(testState 重置)。
- 切回"豆包" → API Key 字段应自动恢复为之前输入的值(从 Keychain 读)。
- 关闭"启用"开关 → 整张页面收起为 disabledHint;再打开,provider 选择保持上次。

- [ ] **Step 5: 报告验证结果**

如果以上任一项不符合预期,打开新 task 修复;否则进入 Task 8 收尾。

---

## Task 8: 自查与文档同步

**目标:** 检查代码遗留、对照 spec 收尾确认。

**Files:**
- 可能修改:任意上述新文件,视自查结果

- [ ] **Step 1: 全局搜索遗留命名**

```bash
cd /Users/yang/xcodeProj/vbcc/vbcc-mac/.worktrees/feature-ark-polish-provider
grep -rn "OllamaTextPolisher\|OllamaPreferences\b\|OllamaPage" vbcc-mac vbcc-macTests 2>/dev/null
```

Expected: 无任何输出。如果有,说明 Task 2/4/6 漏改,补上后提交。

- [ ] **Step 2: 验证 spec 关键点都已覆盖**

逐条对照 spec 中"目标"5 条:

1. ✅ Picker 互斥切换 — Task 6
2. ✅ api-key 走 Keychain — Task 3 + Task 4 + Task 6 onChange debounce
3. ✅ 共享 prompt + timeout,连接独立 — Task 4 字段划分 + Task 6 UI
4. ✅ 侧边栏改名"模型配置" — Task 6
5. ✅ 老用户零迁移 — Task 4 沿用老键名 + `polishPreferencesReadsLegacyOllamaKeys` 测试

如有未覆盖项,新增 task 处理。

- [ ] **Step 3: 跑全套测试最后一遍**

```bash
xcodebuild -project vbcc-mac.xcodeproj -scheme vbcc-mac -configuration Debug -destination 'platform=macOS' test 2>&1 | tail -15
```

Expected: 全部 PASS。

- [ ] **Step 4: 检查 git log,确保提交粒度合理**

```bash
git log --oneline main..HEAD
```

Expected: 6 个左右独立提交,每个对应一个 Task。

- [ ] **Step 5: (本任务无新增提交,除非有补丁)**

---

## 完成后的合并流程

按 AGENTS.md 的 Post-Completion Workflow:
1. 切回 main,确认 main 干净
2. 把 `feature/ark-polish-provider` 合并到 main
3. 报告变更摘要给用户
4. 用户确认无问题后,push、删除 worktree、删除分支
