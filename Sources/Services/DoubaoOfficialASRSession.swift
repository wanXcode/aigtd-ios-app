import Foundation
import UIKit

final class DoubaoOfficialASRSession: NSObject, SpeechEngineDelegate, @unchecked Sendable {
    private let defaultEndpoint = "wss://openspeech.bytedance.com"
    private let configuration: VoiceTranscriptionConfiguration
    private let stateQueue = DispatchQueue(label: "ai.gtd.voice.sdk.state")
    private let engineQueue = DispatchQueue(label: "ai.gtd.voice.sdk.engine")

    private var engine: SpeechEngine?
    private var updateHandler: (@Sendable (VoiceTranscriptionUpdate) async -> Void)?
    private var finishContinuation: CheckedContinuation<VoiceTranscriptionResult, Error>?
    private var latestTranscript = ""
    private var rawEvents: [String] = []
    private var didFinish = false
    private var hasStartedEngine = false
    private var lastEngineMessage = ""
    private var finishTimeoutWorkItem: DispatchWorkItem?

    init(configuration: VoiceTranscriptionConfiguration) {
        self.configuration = configuration
        super.init()
    }

    static func prepareEnvironmentIfNeeded() -> Bool {
        SpeechEngine.prepareEnvironment()
    }

    func start(
        languageCode: String?,
        onUpdate: @escaping @Sendable (VoiceTranscriptionUpdate) async -> Void
    ) throws {
        let appID = configuration.appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessToken = configuration.accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cluster = configuration.cluster.trimmingCharacters(in: .whitespacesAndNewlines)

        guard appID.isEmpty == false,
              accessToken.isEmpty == false,
              cluster.isEmpty == false else {
            throw VoiceTranscriptionError.missingConfiguration
        }

        let resolvedLanguage = nonEmpty(languageCode) ?? nonEmpty(configuration.languageCode) ?? "zh-CN"
        let endpoint = resolveWebSocketEndpoint()
        let address = endpoint.scheme != nil && endpoint.host != nil
            ? "\(endpoint.scheme ?? "wss")://\(endpoint.host ?? "openspeech.bytedance.com")"
            : defaultEndpoint
        let uri = endpoint.path.isEmpty ? "/api/v2/asr" : endpoint.path
        let bearerToken = "Bearer;\(accessToken)"
        let userID = resolveStableUserID()
        stateQueue.sync {
            latestTranscript = ""
            rawEvents.removeAll(keepingCapacity: true)
            didFinish = false
            hasStartedEngine = false
            lastEngineMessage = ""
            finishTimeoutWorkItem?.cancel()
            finishTimeoutWorkItem = nil
        }
        let createdEngine = try engineQueue.sync { () throws -> SpeechEngine in
            let engine = SpeechEngine()
            guard engine.createEngine(with: self) else {
                throw VoiceTranscriptionError.connectionFailed("豆包语音 SDK 创建引擎失败。")
            }

            engine.setStringParam(SE_ASR_ENGINE, forKey: SE_PARAMS_KEY_ENGINE_NAME_STRING)
            engine.setStringParam(SE_LOG_LEVEL_DEBUG, forKey: SE_PARAMS_KEY_LOG_LEVEL_STRING)
            engine.setStringParam(SE_RECORDER_TYPE_RECORDER, forKey: SE_PARAMS_KEY_RECORDER_TYPE_STRING)
            engine.setStringParam(appID, forKey: SE_PARAMS_KEY_APP_ID_STRING)
            engine.setStringParam(bearerToken, forKey: SE_PARAMS_KEY_APP_TOKEN_STRING)
            engine.setStringParam(userID, forKey: SE_PARAMS_KEY_UID_STRING)
            engine.setStringParam(cluster, forKey: SE_PARAMS_KEY_ASR_CLUSTER_STRING)
            engine.setStringParam(address, forKey: SE_PARAMS_KEY_ASR_ADDRESS_STRING)
            engine.setStringParam(uri, forKey: SE_PARAMS_KEY_ASR_URI_STRING)
            engine.setStringParam(resolvedLanguage, forKey: SE_PARAMS_KEY_ASR_LANGUAGE_STRING)
            engine.setBoolParam(true, forKey: SE_PARAMS_KEY_ASR_ENABLE_DDC_BOOL)
            engine.setBoolParam(true, forKey: SE_PARAMS_KEY_ASR_SHOW_NLU_PUNC_BOOL)
            engine.setBoolParam(true, forKey: SE_PARAMS_KEY_ASR_DISABLE_END_PUNC_BOOL)
            engine.setBoolParam(false, forKey: SE_PARAMS_KEY_ASR_AUTO_STOP_BOOL)
            engine.setIntParam(60_000, forKey: SE_PARAMS_KEY_VAD_MAX_SPEECH_DURATION_INT)
            engine.setBoolParam(true, forKey: SE_PARAMS_KEY_ENABLE_GET_VOLUME_BOOL)
            engine.setStringParam(SE_ASR_RESULT_TYPE_SINGLE, forKey: SE_PARAMS_KEY_ASR_RESULT_TYPE_STRING)

            let ret = engine.initEngine()
            guard ret == SENoError else {
                engine.destroy()
                throw VoiceTranscriptionError.serviceError("豆包语音 SDK 初始化失败：\(ret.rawValue)")
            }

            _ = engine.send(SEDirectiveSyncStopEngine, data: "")
            let startRet = engine.send(SEDirectiveStartEngine, data: "")
            guard startRet == SENoError else {
                engine.destroy()
                throw VoiceTranscriptionError.serviceError("启动语音识别失败：\(startRet.rawValue)")
            }

            return engine
        }

        self.engine = createdEngine
        self.updateHandler = onUpdate
    }

    func finish() async throws -> VoiceTranscriptionResult {
        let snapshot = stateQueue.sync {
            (
                engine: hasStartedEngine ? self.engine : nil,
                lastMessage: lastEngineMessage,
                rawSummary: rawEvents.suffix(8).joined(separator: "\n")
            )
        }
        guard let engine = snapshot.engine else {
            let message = formatSDKErrorMessage(
                primary: snapshot.lastMessage,
                fallback: "语音引擎还没准备好，哥哥你再试一下。",
                rawSummary: snapshot.rawSummary
            )
            throw VoiceTranscriptionError.connectionFailed(message)
        }
        return try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.finishContinuation = continuation
                let timeoutWorkItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.stateQueue.async {
                        guard self.didFinish == false else { return }
                        let transcript = self.latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        if transcript.isEmpty == false {
                            let summary = self.rawEvents.suffix(12).joined(separator: "\n")
                            self.finishLocked(
                                result: VoiceTranscriptionResult(
                                    transcript: transcript,
                                    confidence: 0.92,
                                    provider: VoiceProviderPreset.doubao.rawValue,
                                    rawResponseSummary: summary
                                ),
                                error: nil
                            )
                        } else {
                            let rawSummary = self.rawEvents.suffix(8).joined(separator: "\n")
                            let message = self.formatSDKErrorMessage(
                                primary: self.lastEngineMessage,
                                fallback: "语音识别超时了，哥哥你再试一下。",
                                rawSummary: rawSummary
                            )
                            self.finishLocked(
                                result: nil,
                                error: VoiceTranscriptionError.connectionFailed(message)
                            )
                        }
                    }
                }
                self.finishTimeoutWorkItem = timeoutWorkItem
                self.stateQueue.asyncAfter(deadline: .now() + 1.5, execute: timeoutWorkItem)
                let ret: SEEngineErrorCode = self.engineQueue.sync {
                    engine.send(SEDirectiveFinishTalking, data: "")
                }
                guard ret == SENoError else {
                    self.finishLocked(
                        result: nil,
                        error: VoiceTranscriptionError.serviceError("结束录音失败：\(ret.rawValue)")
                    )
                    return
                }
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.finishLocked(result: nil, error: VoiceTranscriptionError.serviceError("语音识别已取消。"))
        }
        engineQueue.sync {
            if let engine {
                _ = engine.send(SEDirectiveStopEngine, data: "")
                engine.destroy()
            }
        }
        engine = nil
        updateHandler = nil
    }

    func onMessage(with type: SEMessageType, andData data: Data) {
        let text = decodeText(from: data)
        stateQueue.async {
            self.rawEvents.append("[\(type.rawValue)] \(text)")
            if let readable = self.nonEmpty(text) {
                self.lastEngineMessage = readable
            }

            switch type {
            case SEEngineStart:
                self.hasStartedEngine = true
            case SEAsrPartialResult, SEPartialResult:
                if let partial = self.extractText(from: text) {
                    self.latestTranscript = partial
                    if let updateHandler = self.updateHandler {
                        Task {
                            await updateHandler(.partial(partial))
                        }
                    }
                }
            case SEFinalResult:
                if let finalText = self.extractText(from: text) {
                    self.latestTranscript = finalText
                    if let updateHandler = self.updateHandler {
                        Task {
                            await updateHandler(.finalTranscript(finalText))
                        }
                    }
                }
                self.finishLockedIfPossible()
            case SEEngineError:
                let rawSummary = self.rawEvents.suffix(8).joined(separator: "\n")
                let message = self.formatSDKErrorMessage(
                    primary: self.extractText(from: text) ?? self.nonEmpty(text),
                    fallback: "豆包语音识别失败。",
                    rawSummary: rawSummary
                )
                self.finishLocked(result: nil, error: VoiceTranscriptionError.serviceError(message))
            case SEEngineStop:
                self.finishLockedIfPossible()
            default:
                break
            }
        }
    }

    private func finishLockedIfPossible() {
        guard didFinish == false else { return }
        guard let continuation = finishContinuation else { return }
        let transcript = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcript.isEmpty == false else { return }

        didFinish = true
        finishContinuation = nil
        let summary = rawEvents.suffix(12).joined(separator: "\n")
        continuation.resume(returning: VoiceTranscriptionResult(
            transcript: transcript,
            confidence: 0.92,
            provider: VoiceProviderPreset.doubao.rawValue,
            rawResponseSummary: summary
        ))
        engineQueue.async {
            self.engine?.destroy()
            self.engine = nil
            self.updateHandler = nil
        }
    }

    private func finishLocked(result: VoiceTranscriptionResult?, error: Error?) {
        guard didFinish == false else { return }
        didFinish = true

        finishTimeoutWorkItem?.cancel()
        finishTimeoutWorkItem = nil
        let continuation = finishContinuation
        finishContinuation = nil
        hasStartedEngine = false

        engineQueue.async {
            self.engine?.destroy()
            self.engine = nil
            self.updateHandler = nil
        }

        guard let continuation else { return }
        if let result {
            continuation.resume(returning: result)
        } else if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(throwing: VoiceTranscriptionError.serviceError("语音识别没有返回结果。"))
        }
    }

    private func decodeText(from data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    private func resolveWebSocketEndpoint() -> URL {
        let raw = nonEmpty(configuration.baseURL) ?? defaultEndpoint
        return URL(string: raw) ?? URL(string: defaultEndpoint)!
    }

    private func resolveStableUserID() -> String {
        if let vendorID = UIDevice.current.identifierForVendor?.uuidString,
           vendorID.isEmpty == false {
            return vendorID
        }

        let key = "ai.gtd.voice.user-id"
        if let existing = UserDefaults.standard.string(forKey: key),
           existing.isEmpty == false {
            return existing
        }

        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private func extractText(from value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return extractText(fromJSONObject: json)
    }

    private func extractText(fromJSONObject value: Any) -> String? {
        if let string = value as? String {
            return nonEmpty(string)
        }
        if let dict = value as? [String: Any] {
            if let utterances = dict["utterances"] as? [[String: Any]] {
                let joined = utterances.compactMap { extractText(fromJSONObject: $0) }.joined()
                if let joined = nonEmpty(joined) {
                    return joined
                }
            }
            let candidates = ["err_msg", "text", "utterances_text", "result", "payload"]
            for key in candidates {
                if let nested = dict[key],
                   let text = extractText(fromJSONObject: nested) {
                    return text
                }
            }
            if let errCode = dict["err_code"] {
                let reqID = (dict["req_id"] as? String).flatMap(nonEmpty) ?? ""
                let readableReqID = reqID.isEmpty ? "" : " req_id=\(reqID)"
                return "err_code=\(errCode)\(readableReqID)"
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let text = extractText(fromJSONObject: item) {
                    return text
                }
            }
        }
        return nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private func formatSDKErrorMessage(primary: String?, fallback: String, rawSummary: String) -> String {
        let resolved = nonEmpty(primary) ?? fallback
        guard looksLikeOpaqueIdentifier(resolved) else { return resolved }
        let compactSummary = nonEmpty(rawSummary.replacingOccurrences(of: "\n", with: " | ")) ?? ""
        guard compactSummary.isEmpty == false else { return "\(fallback) req_id=\(resolved)" }
        return "\(fallback) req_id=\(resolved) | \(compactSummary)"
    }

    private func looksLikeOpaqueIdentifier(_ value: String) -> Bool {
        let pattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
