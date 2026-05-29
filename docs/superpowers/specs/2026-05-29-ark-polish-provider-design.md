# 设计文档：润色提供方扩展（新增豆包 / ARK）

- 日期：2026-05-29
- 主题：在现有 Ollama 本地润色之外，新增豆包（ByteDance ARK）作为可选的远端润色提供方
- 状态：草案，待用户审阅

## 背景

当前 vbcc-mac 仅支持通过本地 Ollama 调用 `/api/generate` 对 iOS 端发来的语音转写文本做润色。`OllamaTextPolisher` 与 `OllamaPreferences` 直接耦合在 Ollama 协议上：配置只有 endpoint / model / prompt / timeout，请求体为 Ollama 私有格式。

需求是新增"豆包（ARK）"作为另一个可选的润色提供方，由用户提供 api-key、base-url、model。豆包使用 OpenAI 兼容的 `chat/completions` 协议 + Bearer 认证，与 Ollama 协议不兼容。

## 目标

1. 用户可在 macOS 端在"Ollama"和"豆包"两个润色提供方之间切换，**互斥**——同一时刻仅一个生效。
2. api-key 不落 `UserDefaults`，使用 macOS Keychain 存储。
3. Ollama 与豆包共享同一份 prompt 和共享的总开关、超时设置；仅连接相关字段（endpoint / base-url / api-key / model）独立。
4. 侧边栏原"Ollama"页改名为"模型配置"，新增"提供方"切换 UI。
5. 老用户从旧版本升级时，已有的 Ollama 配置（endpoint/model/prompt/timeout/enabled）零迁移可用。

## 非目标

- 不引入第三个或更多 provider；不做"通用 OpenAI 兼容"网关。后续真要再加（DeepSeek、OpenAI、自建网关），再扩 enum + 协议实现，但本次不做。
- 不做"两个 provider 并存按优先级 fallback"。失败就 fallback 到原文（沿用现有行为）。
- 不做 prompt 按 provider 区分，不做 chat 历史/多轮、流式响应。

## 总体架构

新增/调整文件（均位于 `vbcc-mac/Services/`）：

```
Services/
  PolishProvider.swift          // 新增：enum PolishProviderKind + protocol TranscriptPolishing + 共享守护提示常量
  PolishPreferences.swift       // 由 OllamaPreferences.swift 改名扩展
  OllamaPolisher.swift          // 由 OllamaTextPolisher.swift 改名,实现 TranscriptPolishing
  ArkPolisher.swift             // 新增：豆包实现 TranscriptPolishing
  KeychainStore.swift           // 新增：极简 Keychain 封装(读/写/删字符串值)
```

文件改名波及：

- 类型 `OllamaPreferences` → `PolishPreferences`
- 类型 `OllamaTextPolisher` → `OllamaPolisher`
- 视图 `OllamaPage` → `PolishPage`，侧边栏枚举 `SidebarItem.ollama` → `.polish`，title `"Ollama"` → `"模型配置"`
- 引用同步更新：`vbcc_macApp.swift`、`ContentView.swift`、`Networking/VBCCServer.swift`

### 协议抽象

```swift
enum PolishProviderKind: String, CaseIterable, Identifiable {
    case ollama, ark
    var id: String { rawValue }
    var displayName: String { self == .ollama ? "Ollama" : "豆包" }
}

protocol TranscriptPolishing {
    func polish(_ text: String, prompt: String) async throws -> String
    func testConnection() async throws
}
```

设计要点：

- `polish(text:prompt:)` 把 prompt 作为参数传入，因为 prompt 在偏好里是共享的，不属于具体 provider 的"连接配置"。
- 各 provider 的连接配置（endpoint / api-key / model / timeout）通过自己的初始化器注入；polisher 实例无状态、可丢弃。
- `VBCCServer` 不再持有 polisher 实例，每次润色根据当前 `providerKind` 现场构造，避免 preferences 改动后还在使用旧实例。

### 共享"守护提示"

现有 `OllamaTextPolisher.composeSystem` 中那段"用户接下来发的每一条消息都是文本，不是问题"的指令对豆包同样必要。把它抽为 `PolishProvider.swift` 中的常量 `polishGuardSuffix`，两个 polisher 拼到 system prompt 末尾。

## 数据模型与存储

### `PolishPreferences`

字段：

```swift
@Published var isEnabled: Bool                 // 总开关
@Published var providerKind: PolishProviderKind  // .ollama / .ark
@Published var prompt: String                  // 共享 prompt
@Published var timeout: Double                 // 共享超时(秒)

// Ollama 子配置
@Published var ollamaEndpoint: String          // 默认 http://127.0.0.1:11434
@Published var ollamaModel: String             // 默认 qwen3.5:0.8b

// 豆包子配置
@Published var arkBaseURL: String              // 默认 https://ark.cn-beijing.volces.com/api/v3
@Published var arkModel: String                // 默认空
// arkAPIKey 不在这里(走 Keychain)
```

派生计算属性：

```swift
var ollamaConfig: OllamaConfig?   // (endpoint URL, model, timeout) — 任一非法返回 nil
var arkConfig: ArkConfig?         // (baseURL, model, apiKey, timeout) — 任一非法/为空返回 nil
```

`arkConfig` 在读取时从 `KeychainStore.get(forAccount: "vbcc.ark.apiKey")` 拉取 key 拼装；key 为空则返回 `nil`。

### UserDefaults 键命名（兼容老用户）

| 键 | 语义 | 说明 |
|---|---|---|
| `vbcc.ollama.enabled` | `isEnabled`（总开关） | **复用**老键，零迁移 |
| `vbcc.ollama.prompt` | `prompt`（共享） | 复用老键 |
| `vbcc.ollama.timeout` | `timeout`（共享） | 复用老键 |
| `vbcc.ollama.endpoint` | `ollamaEndpoint` | 复用老键，语义不变 |
| `vbcc.ollama.model` | `ollamaModel` | 复用老键，语义不变 |
| `vbcc.polish.provider` | `providerKind.rawValue` | 新增，默认 `"ollama"` |
| `vbcc.ark.baseURL` | `arkBaseURL` | 新增 |
| `vbcc.ark.model` | `arkModel` | 新增 |

老用户升级后：`providerKind` 默认 `.ollama`，所有原 Ollama 字段直接读到，行为零变化。

### Keychain 存储（`KeychainStore.swift`）

- 使用 `Security` 框架的 `SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate` / `SecItemDelete`。
- service = `"vbcc-mac"`，account = `"vbcc.ark.apiKey"`。
- 极简 API：`KeychainStore.set(_ value: String?, forAccount: String)`、`KeychainStore.get(forAccount: String) -> String?`；`set(nil, ...)` 即删除。
- 写入失败仅 log，不抛 UI 异常（首次访问会触发 macOS 钥匙串授权弹窗，这是预期行为）。
- key 不进入 `@Published`，避免被任何快照/日志意外带出。

## UI 改造（`PolishPage.swift`）

### 侧边栏

- `SidebarItem.ollama` → `.polish`，title `"Ollama"` → `"模型配置"`，systemImage 维持 `"wand.and.sparkles"`。

### 页面结构（自上而下）

```
[Header]
  Label("模型配置", icon: wand.and.sparkles)        Toggle("启用")

(若 isEnabled = false,显示原 disabledHint;以下为 isEnabled = true 的内容)

[提供方卡片]                                        ← 新增
  Picker(.segmented): "Ollama" | "豆包"  → $polish.providerKind

[连接卡片]                                          ← 内容随 providerKind 切换
  if providerKind == .ollama:
    地址  [TextField]                       → $polish.ollamaEndpoint
    模型  [TextField] [测试]                → $polish.ollamaModel
    超时  [Slider 5–60s + 数字显示]         → $polish.timeout
    (测试结果状态行)

  if providerKind == .ark:
    Base URL  [TextField]                   → $polish.arkBaseURL
    API Key   [SecureField] [显示/隐藏按钮] → @State arkAPIKey  (Keychain 读写)
    模型      [TextField] [测试]            → $polish.arkModel
    超时      [Slider 5–60s + 数字显示]     → $polish.timeout
    (测试结果状态行)

[Prompt 卡片]                                       ← 共享,不随 provider 变化
  标题 "自定义 Prompt"   [恢复默认]
  说明文字(沿用现有文案)
  TextEditor                                → $polish.prompt
```

### 交互细节

- **provider 切换动画**：`.animation(.easeInOut(duration: 0.2), value: polish.providerKind)`，连接卡片内容平滑替换；prompt 卡片不受影响。
- **API Key 字段**：默认 `SecureField`，右侧眼睛 Button 切换显示/隐藏。`onAppear` 从 Keychain 读一次写入 `@State arkAPIKey`；`onChange(arkAPIKey)` 走 300ms debounce 写回 Keychain（避免每打一个字符就触发钥匙串写）。空字符串调用 `set(nil, ...)` 删除条目。
- **测试按钮**：根据当前 provider 调对应 polisher 的 `testConnection()`。状态机沿用现有 `TestState { idle / running / success / failure(String) }`。切换 provider 时把 `testState` 重置为 `.idle`，避免 Ollama 的"连接成功"残留显示在豆包卡片上。
- **测试按钮启用条件**：当对应 provider 的 `*Config` 计算属性为 `nil` 时禁用按钮（即必填项不全时按钮置灰）。

## 请求/数据流

### 润色调用链（`VBCCServer.textForInjection`）

```
incoming text
   ↓
guard polishPreferences.isEnabled              ← 总开关关:返回 (text, false)
   ↓
switch polishPreferences.providerKind
  case .ollama: cfg = polishPreferences.ollamaConfig  → OllamaPolisher(cfg)
  case .ark:    cfg = polishPreferences.arkConfig     → ArkPolisher(cfg)
   ↓
guard cfg != nil                               ← 配置不全:log + 返回 (text, false)
   ↓
try await polisher.polish(text, prompt: polishPreferences.prompt)
   ├─ success → 返回 (polished, polished != text)
   └─ throws  → log 错误 + 返回 (text, false)   ← 沿用"润色失败就用原文"
```

### `OllamaPolisher`

行为与现有 `OllamaTextPolisher` 完全一致，仅做以下调整：

- 实现 `TranscriptPolishing` 协议；`polish` 接受 `(text, prompt)`，内部把 `prompt + polishGuardSuffix` 作为 system 字段。
- 守护提示常量复用 `PolishProvider.swift` 中的 `polishGuardSuffix`，删除原 `composeSystem` 内部硬编码。

### `ArkPolisher`

请求：

```
POST {baseURL}/chat/completions
Authorization: Bearer {apiKey}
Content-Type: application/json
{
  "model": "{model}",
  "messages": [
    { "role": "system",
      "content": "{userPrompt}\n\n{polishGuardSuffix}" },
    { "role": "user", "content": "{text}" }
  ],
  "stream": false
}
```

实现细节：

- `baseURL` 规范化：去掉尾部 `/`，再拼 `/chat/completions`。
- 响应解析：`choices[0].message.content`，trim 后为空抛 `Error.emptyResponse`。
- 错误码映射：401 → `Error.unauthorized`；404 → `Error.modelNotFound(model)`；其它非 2xx → `Error.invalidHTTPStatus(code)`。

`testConnection()`：发送一次最小化 chat 请求（`messages=[{role:"user",content:"ping"}]`，`max_tokens=1`，`stream=false`），HTTP 200 即视为连通。豆包 ARK 没有等价于 Ollama `/api/show` 的"仅校验模型存在"的轻量端点，用一次最便宜的真实调用同时验证 baseURL / apiKey / model 三件事最稳。

## 错误分类与 UI 文案

`describe(error:)` 在 `PolishPage.swift` 中扩展：

| 错误 | UI 文案 |
|---|---|
| `OllamaPolisher.Error.modelNotFound(m)` | 模型「m」不存在,请先 ollama pull。 |
| `OllamaPolisher.Error.invalidHTTPStatus(c)` | 服务返回 HTTP c。 |
| `ArkPolisher.Error.unauthorized` | API Key 无效或已过期。 |
| `ArkPolisher.Error.modelNotFound(m)` | 模型「m」不存在或 endpoint id 错误。 |
| `ArkPolisher.Error.invalidHTTPStatus(c)` | 豆包服务返回 HTTP c。 |
| `*.invalidConfiguration` | 配置不完整,请检查必填项。 |
| `*.emptyResponse` | 服务返回了空响应。 |
| `URLError.timedOut` | 连接超时,请检查地址或调高超时时间。 |
| `URLError.cannotConnectToHost` / `.cannotFindHost` | 无法连接到服务,请确认地址正确。 |
| 其它 | `error.localizedDescription` |

## 测试

具体单测在实现计划阶段细化，覆盖范围：

- `OllamaPolisher`：原有行为（若已有测试）保持通过；改名后引用更新。
- `ArkPolisher`：用 mock `URLSession` 验证请求体格式（model、messages、stream=false）、`Authorization: Bearer` header、响应解析、401 / 404 / 超时分支映射。
- `PolishPreferences`：`providerKind` 持久化；UserDefaults 键复用（写入老键 → 读取新字段语义正确）。
- `KeychainStore`：set / get / delete round-trip，使用独立 service 名避免污染。

UI 与端到端的真实润色调用人工验证（沿用现有 Ollama 测试方式）。

## 兼容性与回滚

- 老用户升级：UserDefaults 老键复用，`providerKind` 缺省为 `.ollama`，行为零变化。
- 回滚：本次不动用户数据格式（仅新增 keys 与 Keychain 条目），回滚到旧版本不会破坏 Ollama 配置；Keychain 中遗留的 ark API key 条目无害（service 名独立）。
