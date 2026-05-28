//
//  VBCCServer.swift
//  vbcc-mac
//
//  Bonjour 注册 + WebSocket 服务端。
//  V1 第 2 阶段：数字选择配对 + token 持久化。
//

import Foundation
import Network
import Combine

final class VBCCServer: ObservableObject {

    // MARK: - 对外状态

    enum ServerStatus {
        case stopped
        case starting
        case running
        case failed(String)
    }

    /// 屏幕上需要展示的配对数字（同时只支持一个）
    struct PendingPair: Identifiable, Equatable {
        let id = UUID()
        let number: Int
        let deviceName: String
        let expiresAt: Date
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let message: String
    }

    @Published private(set) var status: ServerStatus = .stopped
    @Published private(set) var port: UInt16?
    @Published private(set) var connectedClients: Int = 0
    @Published private(set) var pendingPair: PendingPair?
    @Published private(set) var log: [LogEntry] = []

    let tokens: TokenStore
    let ollamaPreferences: OllamaPreferences
    let transcripts: TranscriptStore
    private let injector = TextInjector()
    private let textPolisher: OllamaTextPolisher

    // MARK: - 配对配置

    private let pairWindowSeconds: TimeInterval = 60

    // MARK: - 每连接的会话

    private final class ClientSession {
        enum Phase {
            /// 刚连上，等 pair.request 或 session.hello
            case awaitingHandshake
            /// pair.request 收到、已下发 pair.challenge，等 pair.confirm 里的选择
            case awaitingPairConfirm(answer: Int, deadline: Date, request: PairRequestPayload)
            /// 已建立的会话
            case established(device: PairedDevice)
        }
        let conn: NWConnection
        var phase: Phase = .awaitingHandshake
        var pairTimeoutTask: Task<Void, Never>?
        init(conn: NWConnection) { self.conn = conn }
    }

    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: ClientSession] = [:]

    // MARK: - init

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

    // MARK: - 生命周期

    func start() {
        guard listener == nil else { return }
        status = .starting
        appendLog("正在启动监听…")

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 允许 Bonjour 服务通过 AWDL（Apple Wireless Direct Link）暴露，
        // 公司 Wi-Fi 屏蔽 mDNS 多播时,iPhone 仍能 P2P 发现并连接 Mac。
        params.includePeerToPeer = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            let listener = try NWListener(using: params)
            let txt = NWTXTRecord([
                "v":    String(VBCC.protocolVersion),
                "name": MacIdentity.macName,
                "mid":  MacIdentity.macId
            ])
            listener.service = NWListener.Service(
                name: MacIdentity.macName,
                type: VBCC.bonjourServiceType,
                txtRecord: txt
            )
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.start(queue: .main)
        } catch {
            status = .failed("listener 创建失败：\(error)")
            appendLog("❌ \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, session) in sessions {
            session.pairTimeoutTask?.cancel()
            session.conn.cancel()
        }
        sessions.removeAll()
        connectedClients = 0
        port = nil
        pendingPair = nil
        status = .stopped
        appendLog("已停止")
    }

    /// 吊销某个 token，立即关闭还在用它的连接
    func revoke(token: String) {
        tokens.revoke(token: token)
        let toDrop = sessions.values.filter { session in
            if case let .established(device) = session.phase, device.token == token {
                return true
            }
            return false
        }
        for s in toDrop {
            appendLog("🚫 已吊销 token，断开 \(s.conn.endpoint)")
            s.conn.cancel()
        }
    }

    // MARK: - Listener 状态

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            status = .running
            appendLog("🟢 监听就绪 端口=\(port.map(String.init) ?? "?") macId=\(shortId(MacIdentity.macId))")
        case .failed(let err):
            status = .failed("\(err)")
            appendLog("❌ listener failed: \(err)")
        case .cancelled:
            status = .stopped
            appendLog("⚫️ listener cancelled")
        default:
            break
        }
    }

    // MARK: - 接入新连接

    private func accept(_ conn: NWConnection) {
        let session = ClientSession(conn: conn)
        sessions[ObjectIdentifier(conn)] = session
        connectedClients = sessions.count
        appendLog("➕ 新连接 \(conn.endpoint)")

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let conn else { return }
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.appendLog("✅ 连接就绪 \(conn.endpoint)")
                    self.receive(on: conn)
                case .failed(let err):
                    self.appendLog("❌ 连接失败 \(err)")
                    self.drop(conn)
                case .cancelled:
                    self.drop(conn)
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
    }

    private func drop(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.pairTimeoutTask?.cancel()

        // 如果这个连接正在持有 pendingPair 配对数字，清理掉
        if case let .awaitingPairConfirm(answer, _, _) = session.phase,
           pendingPair?.number == answer {
            pendingPair = nil
        }
        connectedClients = sessions.count
        appendLog("➖ 连接已断 \(conn.endpoint)")
    }

    // MARK: - 收

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let conn else { return }
            Task { @MainActor in
                guard let self else { return }
                if let error = error {
                    self.appendLog("❌ 收消息错误 \(error)")
                    self.drop(conn)
                    return
                }
                if let data = data, !data.isEmpty {
                    self.handleIncoming(data, from: conn)
                }
                if conn.state != .cancelled {
                    self.receive(on: conn)
                }
            }
        }
    }

    private func handleIncoming(_ data: Data, from conn: NWConnection) {
        guard let session = sessions[ObjectIdentifier(conn)] else { return }

        do {
            let message = try IncomingMessage.decode(data)
            switch message {
            case .ping(let env):
                appendLog("📥 ping id=\(shortId(env.id))")
                send(Envelope(type: .pong, payload: EmptyPayload(), inReplyTo: env.id), on: conn)

            case .pairRequest(let env):
                handlePairRequest(env: env, session: session)

            case .pairConfirm(let env):
                handlePairConfirm(env: env, session: session)

            case .sessionHello(let env):
                handleSessionHello(env: env, session: session)

            case .inputText(let env):
                guard requireEstablished(session, replyTo: env.id, on: conn) else { return }
                handleInputText(env: env, session: session, on: conn)

            case .inputKey(let env):
                guard requireEstablished(session, replyTo: env.id, on: conn) else { return }
                handleInputKey(env: env, on: conn)

            default:
                appendLog("📥 未处理消息")
            }
        } catch {
            appendLog("❌ 解码失败 \(error)")
        }
    }

    /// 业务消息要求已建立会话。否则回 error 并不处理。
    private func requireEstablished(_ session: ClientSession, replyTo id: String, on conn: NWConnection) -> Bool {
        if case .established = session.phase { return true }
        send(Envelope(type: .error, payload: ErrorPayload(code: .unauth, message: "session not established"),
                      inReplyTo: id), on: conn)
        return false
    }

    // MARK: - 配对：pair.request

    private func handlePairRequest(env: Envelope<PairRequestPayload>, session: ClientSession) {
        // 必须从 awaitingHandshake 进入；其他阶段忽略并报错
        guard case .awaitingHandshake = session.phase else {
            send(Envelope(type: .pairResult,
                          payload: PairResultPayload(ok: false, error: .internal),
                          inReplyTo: env.id), on: session.conn)
            return
        }

        // V1：同时只接受一个 pendingPair
        if pendingPair != nil {
            appendLog("⚠️ 已有待配对会话，拒绝 \(env.payload.deviceName)")
            send(Envelope(type: .pairResult,
                          payload: PairResultPayload(ok: false, error: .internal),
                          inReplyTo: env.id), on: session.conn)
            return
        }

        let challenge = Self.generatePairChallenge()
        let deadline = Date().addingTimeInterval(pairWindowSeconds)
        session.phase = .awaitingPairConfirm(
            answer: challenge.answer,
            deadline: deadline,
            request: env.payload
        )
        pendingPair = PendingPair(number: challenge.answer, deviceName: env.payload.deviceName, expiresAt: deadline)
        appendLog("🔢 配对数字 \(VBCC.pairNumberText(challenge.answer)) 候选 \(challenge.numbers.map(VBCC.pairNumberText)) 给 \(env.payload.deviceName)")

        // 下发 3 个候选数字（含正确答案，已打乱顺序）给 iPhone 显示成按钮
        send(Envelope(type: .pairChallenge,
                      payload: PairChallengePayload(numbers: challenge.numbers),
                      inReplyTo: env.id), on: session.conn)

        startPairTimeout(for: session)
    }

    private func startPairTimeout(for session: ClientSession) {
        session.pairTimeoutTask?.cancel()
        session.pairTimeoutTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(nanoseconds: UInt64(self?.pairWindowSeconds ?? 60) * 1_000_000_000)
            guard let self, let session, !Task.isCancelled else { return }
            if case .awaitingPairConfirm = session.phase {
                self.appendLog("⏰ 配对超时")
                self.send(Envelope(type: .pairResult,
                                   payload: PairResultPayload(ok: false, error: .pairTimeout)),
                          on: session.conn)
                self.pendingPair = nil
                session.phase = .awaitingHandshake
                // 超时后直接断开
                session.conn.cancel()
            }
        }
    }

    // MARK: - 配对：pair.confirm

    private func handlePairConfirm(env: Envelope<PairConfirmPayload>, session: ClientSession) {
        guard case let .awaitingPairConfirm(answer, deadline, request) = session.phase else {
            send(Envelope(type: .pairResult,
                          payload: PairResultPayload(ok: false, error: .internal),
                          inReplyTo: env.id), on: session.conn)
            return
        }

        // 检查超时
        if Date() > deadline {
            send(Envelope(type: .pairResult,
                          payload: PairResultPayload(ok: false, error: .pairTimeout),
                          inReplyTo: env.id), on: session.conn)
            pendingPair = nil
            session.phase = .awaitingHandshake
            return
        }

        // 检查选择：3 选 1，只给一次机会，选错立即断开
        if env.payload.choice == answer {
            // 成功：生成并存储 token
            let device = tokens.register(
                iPhoneId: request.iPhoneId,
                deviceName: request.deviceName,
                model: request.model,
                iosVersion: request.iosVersion
            )
            session.pairTimeoutTask?.cancel()
            session.phase = .established(device: device)
            pendingPair = nil

            appendLog("✅ 配对成功 \(request.deviceName)")
            send(Envelope(type: .pairResult,
                          payload: PairResultPayload(
                            ok: true,
                            token: device.token,
                            macName: MacIdentity.macName,
                            macId: MacIdentity.macId
                          ),
                          inReplyTo: env.id), on: session.conn)
            // 一并下发 welcome，省得客户端再发 hello
            send(Envelope(type: .sessionWelcome,
                          payload: SessionWelcomePayload(
                            macName: MacIdentity.macName,
                            macId: MacIdentity.macId,
                            version: String(VBCC.protocolVersion),
                            capabilities: [Capability.textInject, Capability.keyBasic, Capability.clipboardPreserve]
                          )),
                 on: session.conn)
        } else {
            appendLog("❌ 配对数字选错（\(VBCC.pairNumberText(env.payload.choice)) ≠ \(VBCC.pairNumberText(answer))），断开")
            send(Envelope(type: .pairResult,
                          payload: PairResultPayload(ok: false, error: .pairChoiceInvalid),
                          inReplyTo: env.id), on: session.conn)
            pendingPair = nil
            session.pairTimeoutTask?.cancel()
            session.phase = .awaitingHandshake
            session.conn.cancel()
        }
    }

    // MARK: - 配对：session.hello（已配对回连）

    private func handleSessionHello(env: Envelope<SessionHelloPayload>, session: ClientSession) {
        guard case .awaitingHandshake = session.phase else {
            send(Envelope(type: .error,
                          payload: ErrorPayload(code: .internal, message: "unexpected hello"),
                          inReplyTo: env.id), on: session.conn)
            return
        }
        guard let device = tokens.find(token: env.payload.token) else {
            appendLog("🚫 未识别 token，拒绝")
            send(Envelope(type: .error,
                          payload: ErrorPayload(code: .unauth, message: "token invalid"),
                          inReplyTo: env.id), on: session.conn)
            session.conn.cancel()
            return
        }
        session.phase = .established(device: device)
        appendLog("👋 已认会话 \(device.deviceName)")
        send(Envelope(type: .sessionWelcome,
                      payload: SessionWelcomePayload(
                        macName: MacIdentity.macName,
                        macId: MacIdentity.macId,
                        version: String(VBCC.protocolVersion),
                        capabilities: [Capability.textInject, Capability.keyBasic, Capability.clipboardPreserve]
                      ),
                      inReplyTo: env.id),
             on: session.conn)
    }

    // MARK: - 输入：input.text

    private func handleInputText(env: Envelope<InputTextPayload>, session: ClientSession, on conn: NWConnection) {
        let text = env.payload.text
        let sendEnter = env.payload.sendEnter
        let preview = text.count > 30 ? String(text.prefix(30)) + "…" : text
        appendLog("⌨️ input.text \"\(preview)\" enter=\(sendEnter)")

        let device: PairedDevice? = {
            if case let .established(device) = session.phase { return device }
            return nil
        }()

        Task { @MainActor [weak self] in
            guard let self else { return }
            let polishResult = await self.textForInjection(original: text)
            let textToInject = polishResult.text
            let ok = await self.injector.inject(textToInject, sendEnter: sendEnter)
            if !ok {
                self.appendLog("🚫 注入失败：缺少 Accessibility 权限")
            }
            if let device {
                self.transcripts.append(Transcript(
                    deviceToken: device.token,
                    deviceName: device.deviceName,
                    originalText: text,
                    polishedText: polishResult.polished ? textToInject : nil
                ))
            }
            self.send(Envelope(
                type: .ack,
                payload: AckPayload(ok: ok, error: ok ? nil : .accessibilityDenied),
                inReplyTo: env.id
            ), on: conn)
        }
    }

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
            appendLog("⚠️ Ollama 整理失败，使用原文：\(error)")
            return (text, false)
        }
    }

    // MARK: - 输入：input.key

    private func handleInputKey(env: Envelope<InputKeyPayload>, on conn: NWConnection) {
        let key = env.payload.key
        let action = env.payload.action
        appendLog("⌨️ input.key \(key.rawValue) action=\(action.rawValue)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.injector.injectKey(key, action: action)
            if !ok {
                self.appendLog("🚫 按键注入失败：缺少 Accessibility 权限")
            }
            self.send(Envelope(
                type: .ack,
                payload: AckPayload(ok: ok, error: ok ? nil : .accessibilityDenied),
                inReplyTo: env.id
            ), on: conn)
        }
    }

    // MARK: - 发

    private func send<P: Codable>(_ envelope: Envelope<P>, on conn: NWConnection) {
        do {
            let data = try MessageCoder.encode(envelope)
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(
                identifier: "vbcc-send",
                metadata: [metadata]
            )
            conn.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { [weak self] err in
                    if let err = err {
                        Task { @MainActor in self?.appendLog("❌ 发送失败 \(err)") }
                    }
                }
            )
            appendLog("📤 \(envelope.type.rawValue) id=\(shortId(envelope.id))")
        } catch {
            appendLog("❌ 编码失败 \(error)")
        }
    }

    // MARK: - 工具

    /// 生成配对挑战：3 个互不相同的 0...99 随机数（已打乱顺序），
    /// 其中随机一个作为正确答案显示在 Mac 屏幕上。
    private static func generatePairChallenge() -> (numbers: [Int], answer: Int) {
        var picked = Set<Int>()
        while picked.count < 3 {
            picked.insert(Int.random(in: 0...99))
        }
        let numbers = picked.shuffled()
        let answer = numbers.randomElement()!
        return (numbers, answer)
    }

    private func shortId(_ id: String) -> String { String(id.prefix(8)) }

    private func appendLog(_ message: String) {
        log.append(LogEntry(message: message))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
