import Foundation

enum VoiceProviderPreset: String, CaseIterable, Identifiable, Sendable {
    case doubao = "Doubao"
    case custom = "Custom"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .doubao:
            return "豆包"
        case .custom:
            return "自定义"
        }
    }
}

struct VoiceTranscriptionConfiguration: Sendable {
    let provider: String
    let baseURL: String
    let appKey: String
    let accessKey: String
    let resourceID: String
    let cluster: String
    let languageCode: String
    let autoSendTranscript: Bool
    let interimResultsEnabled: Bool
}

struct VoiceTranscriptionRequest: Sendable {
    let audioURL: URL
    let languageCode: String?
    let prompt: String?
}

struct VoiceTranscriptionResult: Sendable {
    let transcript: String
    let confidence: Double
    let provider: String
    let rawResponseSummary: String
}

enum VoiceTranscriptionUpdate: Sendable {
    case partial(String)
    case finalTranscript(String)
    case audioLevel(Double)
}

protocol VoiceTranscriptionService: Sendable {
    func transcribe(
        _ request: VoiceTranscriptionRequest,
        onUpdate: (@Sendable (VoiceTranscriptionUpdate) async -> Void)?
    ) async throws -> VoiceTranscriptionResult
}

/// A live speech session used by the hold-to-talk interaction.
///
/// Keeping this protocol provider-neutral lets the Chat UI depend on voice
/// behavior without knowing about the Doubao SDK lifecycle.
protocol VoiceLiveTranscriptionSession: AnyObject, Sendable {
    func start(
        languageCode: String?,
        onUpdate: @escaping @Sendable (VoiceTranscriptionUpdate) async -> Void
    ) throws

    func finish() async throws -> VoiceTranscriptionResult
    func cancel()
}

protocol VoiceLiveTranscriptionSessionBuilding: Sendable {
    func makeSession(configuration: VoiceTranscriptionConfiguration) -> any VoiceLiveTranscriptionSession
}

struct DoubaoLiveTranscriptionSessionBuilder: VoiceLiveTranscriptionSessionBuilding {
    func makeSession(configuration: VoiceTranscriptionConfiguration) -> any VoiceLiveTranscriptionSession {
        DoubaoOfficialASRSession(configuration: configuration)
    }
}

extension VoiceTranscriptionService {
    func transcribe(_ request: VoiceTranscriptionRequest) async throws -> VoiceTranscriptionResult {
        try await transcribe(request, onUpdate: nil)
    }
}

enum VoiceTranscriptionError: LocalizedError {
    case unsupportedProvider(String)
    case missingConfiguration
    case invalidAudio
    case connectionFailed(String)
    case serviceError(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider):
            return "暂不支持语音提供方：\(provider)。"
        case .missingConfiguration:
            return "语音配置不完整。"
        case .invalidAudio:
            return "录音内容不可用，请再试一次。"
        case let .connectionFailed(message):
            return "语音连接失败：\(message)"
        case let .serviceError(message):
            return "语音识别失败：\(message)"
        }
    }
}

enum VoiceTranscriptionServiceFactory {
    static func make(configuration: VoiceTranscriptionConfiguration) -> any VoiceTranscriptionService {
        switch VoiceProviderPreset(rawValue: configuration.provider) ?? .custom {
        case .doubao:
            return UnsupportedVoiceTranscriptionService(configuration: configuration)
        case .custom:
            return UnsupportedVoiceTranscriptionService(configuration: configuration)
        }
    }
}

struct UnsupportedVoiceTranscriptionService: VoiceTranscriptionService {
    let configuration: VoiceTranscriptionConfiguration

    func transcribe(
        _ request: VoiceTranscriptionRequest,
        onUpdate: (@Sendable (VoiceTranscriptionUpdate) async -> Void)?
    ) async throws -> VoiceTranscriptionResult {
        throw VoiceTranscriptionError.unsupportedProvider(configuration.provider)
    }
}
