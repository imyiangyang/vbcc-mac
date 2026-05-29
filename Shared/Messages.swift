//
//  Messages.swift
//  VBCC Shared Protocol
//
//  iPhone ↔ Mac 通信协议的 Swift 类型定义。
//  iOS 和 Mac 两端共享同一份文件，避免协议漂移。
//  对应 /protocol.md
//

import Foundation

// MARK: - 协议常量

public enum VBCC {
    /// 协议版本号
    public static let protocolVersion: Int = 1
    /// Bonjour 服务类型
    public static let bonjourServiceType: String = "_vbcc._tcp"

    /// 配对数字的统一显示格式。两端共用，保证 Mac 屏幕与 iPhone 按钮上的
    /// 数字写法一致（补足两位，例如 7 → "07"）。
    public static func pairNumberText(_ number: Int) -> String {
        String(format: "%02d", number)
    }
}

// MARK: - 消息类型枚举

public enum MessageType: String, Codable {
    // iPhone → Mac
    case pairRequest  = "pair.request"
    case pairConfirm  = "pair.confirm"
    case sessionHello = "session.hello"
    case ping         = "ping"
    case inputText    = "input.text"
    case inputKey     = "input.key"

    // Mac → iPhone
    case pairChallenge  = "pair.challenge"
    case pairResult     = "pair.result"
    case sessionWelcome = "session.welcome"
    case pong           = "pong"
    case ack            = "ack"
    case error          = "error"
}

// MARK: - 统一消息信封

/// 所有消息的统一外壳。Payload 用泛型，发送/接收两端都用同一个 Envelope。
public struct Envelope<Payload: Codable>: Codable {
    public var v: Int
    public var id: String
    public var type: MessageType
    public var ts: Int64
    public var inReplyTo: String?
    public var payload: Payload

    public init(
        type: MessageType,
        payload: Payload,
        inReplyTo: String? = nil,
        id: String = UUID().uuidString,
        ts: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.v = VBCC.protocolVersion
        self.id = id
        self.type = type
        self.ts = ts
        self.inReplyTo = inReplyTo
        self.payload = payload
    }
}

/// 只解析头部用于 type 分发。先 peekType，再按类型解整个 Envelope<具体 Payload>。
public struct EnvelopeHeader: Codable {
    public let v: Int
    public let id: String
    public let type: MessageType
    public let ts: Int64
    public let inReplyTo: String?
}

// MARK: - 空 Payload（ping / pong 用）

public struct EmptyPayload: Codable {
    public init() {}
}

// MARK: - 配对相关

public struct PairRequestPayload: Codable {
    /// 稳定的 iPhone 标识（identifierForVendor），用于 Mac 端去重
    public let iPhoneId: String
    public let deviceName: String
    public let model: String
    public let iosVersion: String

    public init(iPhoneId: String, deviceName: String, model: String, iosVersion: String) {
        self.iPhoneId = iPhoneId
        self.deviceName = deviceName
        self.model = model
        self.iosVersion = iosVersion
    }
}

/// Mac → iPhone：Mac 下发的配对挑战。`numbers` 是 3 个互不相同的 0...99 数字，
/// 其中之一与 Mac 屏幕上显示的数字一致；Mac 不会告诉 iPhone 哪个才是正确答案，
/// 由用户对照 Mac 屏幕自己选。
public struct PairChallengePayload: Codable {
    public let numbers: [Int]
    public init(numbers: [Int]) { self.numbers = numbers }
}

/// iPhone → Mac：用户在 3 个数字按钮里点中的那个数字。
public struct PairConfirmPayload: Codable {
    public let choice: Int
    public init(choice: Int) { self.choice = choice }
}

public struct PairResultPayload: Codable {
    public let ok: Bool
    public let token: String?
    public let macName: String?
    public let macId: String?
    public let error: ErrorCode?

    public init(
        ok: Bool,
        token: String? = nil,
        macName: String? = nil,
        macId: String? = nil,
        error: ErrorCode? = nil
    ) {
        self.ok = ok
        self.token = token
        self.macName = macName
        self.macId = macId
        self.error = error
    }
}

// MARK: - 会话

public struct SessionHelloPayload: Codable {
    public let token: String
    public init(token: String) { self.token = token }
}

public struct SessionWelcomePayload: Codable {
    public let macName: String
    public let macId: String
    public let version: String
    public let capabilities: [String]

    public init(macName: String, macId: String, version: String, capabilities: [String]) {
        self.macName = macName
        self.macId = macId
        self.version = version
        self.capabilities = capabilities
    }
}

/// 能力字符串常量。新增能力直接加常量，无需改协议版本。
public enum Capability {
    public static let textInject         = "text.inject"
    public static let keyBasic           = "key.basic"
    public static let clipboardPreserve  = "clipboard.preserve"
}

// MARK: - 输入相关（核心）

/// 可单独下发的按键。修饰键（Command/Shift/Option/Fn）作为「单独点按」也算一个 KeyName。
public enum KeyName: String, Codable, CaseIterable {
    // 方向键
    case up, down, left, right
    // 回车 / 退出
    case returnKey = "return"   // 主键盘回车
    case enter                  // 小键盘回车（KeypadEnter）
    case escape
    // 修饰键（单独点按）
    case commandLeft, commandRight
    case shiftLeft, shiftRight
    case optionLeft, optionRight
    case fn
}

public enum Modifier: String, Codable {
    case cmd, option, shift, control
}

public enum KeyAction: String, Codable {
    case tap   // 单次按下抬起
    case down  // 按下（不抬起）—— V1.5 长按连发用
    case up    // 抬起
}

/// 语音转写后的文本注入。核心消息。
public struct InputTextPayload: Codable {
    public let text: String
    /// 注入完成后是否追加 Enter（用于聊天发送）
    public let sendEnter: Bool
    /// 注入后是否还原用户原有剪贴板
    public let preserveClipboard: Bool

    public init(text: String, sendEnter: Bool, preserveClipboard: Bool) {
        self.text = text
        self.sendEnter = sendEnter
        self.preserveClipboard = preserveClipboard
    }
}

public struct InputKeyPayload: Codable {
    public let key: KeyName
    public let modifiers: [Modifier]
    public let action: KeyAction

    public init(key: KeyName, modifiers: [Modifier] = [], action: KeyAction = .tap) {
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }
}

// MARK: - 回执与错误

public struct AckPayload: Codable {
    public let ok: Bool
    public let error: ErrorCode?

    public init(ok: Bool, error: ErrorCode? = nil) {
        self.ok = ok
        self.error = error
    }
}

public struct ErrorPayload: Codable {
    public let code: ErrorCode
    public let message: String

    public init(code: ErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum ErrorCode: String, Codable {
    case unauth                = "unauth"
    case pairChoiceInvalid     = "pair_choice_invalid"
    case pairTimeout           = "pair_timeout"
    case accessibilityDenied   = "accessibility_denied"
    case `internal`            = "internal"
}

// MARK: - 编解码助手

public enum MessageCoder {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder = JSONDecoder()

    /// 编码一个 Envelope 为 Data
    public static func encode<P: Codable>(_ envelope: Envelope<P>) throws -> Data {
        try encoder.encode(envelope)
    }

    /// 解码 Data 为指定 Payload 类型的 Envelope
    public static func decode<P: Codable>(_ data: Data, as: P.Type) throws -> Envelope<P> {
        try decoder.decode(Envelope<P>.self, from: data)
    }

    /// 先窥探消息 type，便于按 type 分发到不同 Payload 解码器
    public static func peekType(_ data: Data) throws -> MessageType {
        try decoder.decode(EnvelopeHeader.self, from: data).type
    }

    /// 先窥探完整头部（含 id / inReplyTo），分发用
    public static func peekHeader(_ data: Data) throws -> EnvelopeHeader {
        try decoder.decode(EnvelopeHeader.self, from: data)
    }
}

// MARK: - 统一入站消息（switch 分发友好）

/// 收到任意消息后，先用 IncomingMessage.decode 解析为联合体，再 switch。
public enum IncomingMessage {
    case pairRequest(Envelope<PairRequestPayload>)
    case pairConfirm(Envelope<PairConfirmPayload>)
    case sessionHello(Envelope<SessionHelloPayload>)
    case ping(Envelope<EmptyPayload>)
    case inputText(Envelope<InputTextPayload>)
    case inputKey(Envelope<InputKeyPayload>)

    case pairChallenge(Envelope<PairChallengePayload>)
    case pairResult(Envelope<PairResultPayload>)
    case sessionWelcome(Envelope<SessionWelcomePayload>)
    case pong(Envelope<EmptyPayload>)
    case ack(Envelope<AckPayload>)
    case error(Envelope<ErrorPayload>)

    public static func decode(_ data: Data) throws -> IncomingMessage {
        let type = try MessageCoder.peekType(data)
        switch type {
        case .pairRequest:
            return .pairRequest(try MessageCoder.decode(data, as: PairRequestPayload.self))
        case .pairConfirm:
            return .pairConfirm(try MessageCoder.decode(data, as: PairConfirmPayload.self))
        case .sessionHello:
            return .sessionHello(try MessageCoder.decode(data, as: SessionHelloPayload.self))
        case .ping:
            return .ping(try MessageCoder.decode(data, as: EmptyPayload.self))
        case .inputText:
            return .inputText(try MessageCoder.decode(data, as: InputTextPayload.self))
        case .inputKey:
            return .inputKey(try MessageCoder.decode(data, as: InputKeyPayload.self))
        case .pairChallenge:
            return .pairChallenge(try MessageCoder.decode(data, as: PairChallengePayload.self))
        case .pairResult:
            return .pairResult(try MessageCoder.decode(data, as: PairResultPayload.self))
        case .sessionWelcome:
            return .sessionWelcome(try MessageCoder.decode(data, as: SessionWelcomePayload.self))
        case .pong:
            return .pong(try MessageCoder.decode(data, as: EmptyPayload.self))
        case .ack:
            return .ack(try MessageCoder.decode(data, as: AckPayload.self))
        case .error:
            return .error(try MessageCoder.decode(data, as: ErrorPayload.self))
        }
    }
}
