# shared/

iPhone 端和 Mac 端共用的协议层代码。**两端各自的 Xcode 工程都要把这个目录里的文件加进 target**，避免在两侧重复实现协议结构体导致漂移。

## 如何加入 Xcode 工程

最简单的方式（V1 推荐）：

1. 在 Xcode 里 File → Add Files to "..."，选 `shared/Messages.swift`
2. **重要**：在弹窗的 "Add to targets" 里勾上当前 target，但**不要勾选 "Copy items if needed"**——保持引用，让两端共享同一个源文件
3. iOS 和 Mac 两个工程都重复一次

如果你后面想升级为更工程化的方式，可以把 `shared/` 改成一个 Swift Package（`Package.swift`），两端通过 local dependency 引用。V1 不必。

## 文件清单

- `Messages.swift` — 所有协议消息结构体、枚举、编解码助手

## 使用示例

### 发送：构造 + 编码

```swift
let payload = InputTextPayload(
    text: "晚上一起吃饭",
    sendEnter: true,
    preserveClipboard: true
)
let envelope = Envelope(type: .inputText, payload: payload)
let data = try MessageCoder.encode(envelope)
// data 通过 WebSocket 发出去
```

### 接收：分发

```swift
// data 是从 WebSocket 收到的 bytes
let message = try IncomingMessage.decode(data)
switch message {
case .inputText(let env):
    injectText(env.payload.text,
               sendEnter: env.payload.sendEnter,
               preserveClipboard: env.payload.preserveClipboard)
case .inputKey(let env):
    injectKey(env.payload.key,
              modifiers: env.payload.modifiers,
              action: env.payload.action)
case .ping(let env):
    send(Envelope(type: .pong, payload: EmptyPayload(), inReplyTo: env.id))
// ... 其他 case
default:
    break
}
```

### 回执（ack）

```swift
// 收到 inputText 处理完之后，回 ack 给对端
let ack = Envelope(
    type: .ack,
    payload: AckPayload(ok: true),
    inReplyTo: incomingEnvelope.id
)
try webSocket.send(MessageCoder.encode(ack))
```

## 改协议的纪律

1. 改 `Messages.swift` 的同时，**同步更新 `../protocol.md`**
2. 加新消息类型：在 `MessageType` 枚举加一项 + 新的 `Payload` 结构体 + `IncomingMessage` 加 case + `decode` 加分支
3. 加字段：尽量加为 `Optional`，老版本客户端不会因为缺字段而崩
4. 删字段：V1 阶段直接删；后续如果有线上用户，要走"先标记 deprecated → 下一版才删"

## 协议版本

`VBCC.protocolVersion` 当前是 `1`。破坏性变更（删字段、改字段类型）要 bump，并在 `session.welcome` 阶段校验对端版本。V1 不做这个校验，先记着。
