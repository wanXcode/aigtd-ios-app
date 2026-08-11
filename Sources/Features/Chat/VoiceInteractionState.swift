import AVFoundation
import Combine
import Foundation

enum VoiceRecordingPermissionState: Equatable, Sendable {
    case granted
    case denied
}

protocol VoiceRecordingPermissionAuthorizing: Sendable {
    func requestPermission() async -> VoiceRecordingPermissionState
}

struct SystemVoiceRecordingPermissionAuthorizer: VoiceRecordingPermissionAuthorizing {
    func requestPermission() async -> VoiceRecordingPermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .granted : .denied
        @unknown default:
            return .denied
        }
    }
}

struct VoiceTranscriptPresentation: Equatable, Sendable {
    var stable = ""
    var partial = ""
    var live = ""
}

@MainActor
final class VoiceCapturePresentationState: ObservableObject {
    @Published private(set) var transcript = VoiceTranscriptPresentation()
    @Published private(set) var elapsedSeconds = 0

    func updateTranscript(stable: String, partial: String, live: String) {
        let updated = VoiceTranscriptPresentation(stable: stable, partial: partial, live: live)
        guard updated != transcript else { return }
        transcript = updated
    }

    func updateElapsedSeconds(_ value: Int) {
        guard value != elapsedSeconds else { return }
        elapsedSeconds = value
    }

    func reset() {
        transcript = VoiceTranscriptPresentation()
        elapsedSeconds = 0
    }
}

@MainActor
final class VoiceAudioMeterState: ObservableObject {
    @Published private(set) var level = 0.0

    func update(_ value: Double) {
        let normalized = min(max(value, 0), 1)
        let smoothed = level * 0.55 + normalized * 0.45
        guard abs(smoothed - level) >= 0.01 else { return }
        level = smoothed
    }

    func reset() {
        level = 0
    }
}

@MainActor
final class VoiceInteractionState: ObservableObject {
    static let composerPrompt = "发消息或按住说话…"
    static let focusedComposerPrompt = "请输入..."

    enum Phase: Equatable, Sendable {
        case idle
        case requestingPermission
        case starting
        case recording
        case cancelling
        case finalizing
        case draftReady
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var preparedDraft: String?
    @Published private(set) var noticeText: String?

    let presentation = VoiceCapturePresentationState()
    let audioMeter = VoiceAudioMeterState()

    let cancellationDistance: CGFloat
    let warningDuration: Int
    let maximumDuration: Int

    private let permissionAuthorizer: any VoiceRecordingPermissionAuthorizing
    private let sessionBuilder: any VoiceLiveTranscriptionSessionBuilding
    private var session: (any VoiceLiveTranscriptionSession)?
    private var activeCaptureID: UUID?
    private var originalDraft = ""
    private var insertionUTF16Offset: Int?
    private var releaseRequested = false
    private var cancellationRequested = false
    private var durationTask: Task<Void, Never>?
    private var committedTranscript = ""
    private var currentPartialTranscript = ""
    private var preparedTranscript = ""

    init(
        permissionAuthorizer: any VoiceRecordingPermissionAuthorizing = SystemVoiceRecordingPermissionAuthorizer(),
        sessionBuilder: any VoiceLiveTranscriptionSessionBuilding = DoubaoLiveTranscriptionSessionBuilder(),
        cancellationDistance: CGFloat = 72,
        warningDuration: Int = 50,
        maximumDuration: Int = 60
    ) {
        self.permissionAuthorizer = permissionAuthorizer
        self.sessionBuilder = sessionBuilder
        self.cancellationDistance = cancellationDistance
        self.warningDuration = warningDuration
        self.maximumDuration = max(maximumDuration, 1)
    }

    deinit {
        durationTask?.cancel()
        session?.cancel()
    }

    var showsCaptureOverlay: Bool {
        switch phase {
        case .requestingPermission, .starting, .recording, .cancelling:
            return true
        case .idle, .finalizing, .draftReady, .failed:
            return false
        }
    }

    var isCancellationArmed: Bool {
        phase == .cancelling || cancellationRequested
    }

    var statusText: String {
        switch phase {
        case .idle:
            return Self.composerPrompt
        case .requestingPermission:
            return "正在请求麦克风权限…"
        case .starting:
            return "正在准备…"
        case .recording:
            return elapsedSeconds >= warningDuration ? "录音即将结束" : "正在听…"
        case .cancelling:
            return "松开取消"
        case .finalizing:
            return "正在整理…"
        case .draftReady:
            return "已转成文字，可以修改后发送"
        case .failed:
            return noticeText ?? "没有听清，请再试一次"
        }
    }

    var releaseInstruction: String {
        isCancellationArmed ? "松开取消" : "松手转文字 · 上滑取消"
    }

    var formattedDuration: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    var liveTranscript: String {
        presentation.transcript.live
    }

    var elapsedSeconds: Int {
        presentation.elapsedSeconds
    }

    var audioLevel: Double {
        audioMeter.level
    }

    var stableTranscript: String {
        committedTranscript
    }

    var partialTranscript: String {
        currentPartialTranscript
    }

    /// Begins a hold-to-talk capture. The current draft is snapshotted so a
    /// cancellation can restore it exactly.
    func beginCapture(
        configuration: VoiceTranscriptionConfiguration,
        currentDraft: String,
        insertionUTF16Offset: Int? = nil
    ) async {
        guard canBeginCapture else { return }

        let captureID = UUID()
        activeCaptureID = captureID
        originalDraft = currentDraft
        self.insertionUTF16Offset = insertionUTF16Offset
        committedTranscript = ""
        currentPartialTranscript = ""
        preparedTranscript = ""
        preparedDraft = nil
        noticeText = nil
        presentation.reset()
        audioMeter.reset()
        releaseRequested = false
        cancellationRequested = false
        phase = .requestingPermission

        let permission = await permissionAuthorizer.requestPermission()
        guard activeCaptureID == captureID else { return }
        guard permission == .granted else {
            fail("没有麦克风权限，请在系统设置中开启后再试。")
            return
        }
        if cancellationRequested {
            cancelCapture()
            return
        }

        phase = .starting
        let newSession = sessionBuilder.makeSession(configuration: configuration)
        session = newSession

        do {
            try newSession.start(languageCode: configuration.languageCode) { [weak self] update in
                await self?.receive(update, captureID: captureID)
            }
            guard activeCaptureID == captureID else {
                newSession.cancel()
                return
            }
            if cancellationRequested {
                cancelCapture()
                return
            }
            phase = .recording
            startDurationTimer(captureID: captureID)
            if releaseRequested {
                await finishCapture()
            }
        } catch {
            guard activeCaptureID == captureID else { return }
            fail(publicMessage(for: error))
        }
    }

    /// Updates the vertical drag while the finger remains pressed.
    func updateDrag(verticalTranslation: CGFloat) {
        let shouldCancel = verticalTranslation <= -cancellationDistance
        switch phase {
        case .requestingPermission, .starting:
            cancellationRequested = shouldCancel
        case .recording, .cancelling:
            cancellationRequested = shouldCancel
            phase = shouldCancel ? .cancelling : .recording
        case .idle, .finalizing, .draftReady, .failed:
            break
        }
    }

    /// Handles finger release. It never sends a message; success only prepares
    /// text that the caller may apply to its composer binding.
    func releaseCapture() async {
        switch phase {
        case .requestingPermission, .starting:
            if cancellationRequested {
                cancelCapture()
            } else {
                releaseRequested = true
            }
        case .recording:
            await finishCapture()
        case .cancelling:
            cancelCapture()
        case .idle, .finalizing, .draftReady, .failed:
            break
        }
    }

    func cancelCapture() {
        durationTask?.cancel()
        durationTask = nil
        session?.cancel()
        session = nil
        activeCaptureID = nil
        committedTranscript = ""
        currentPartialTranscript = ""
        preparedTranscript = ""
        preparedDraft = nil
        originalDraft = ""
        insertionUTF16Offset = nil
        noticeText = nil
        releaseRequested = false
        cancellationRequested = false
        presentation.reset()
        audioMeter.reset()
        phase = .idle
    }

    /// Stops an interrupted capture and preserves reliable partial text as an
    /// editable draft when available.
    func handleInterruption() {
        switch phase {
        case .requestingPermission, .starting, .recording, .cancelling, .finalizing:
            break
        case .idle, .draftReady, .failed:
            return
        }
        durationTask?.cancel()
        durationTask = nil
        session?.cancel()
        session = nil
        activeCaptureID = nil
        cancellationRequested = false

        let partial = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if partial.isEmpty {
            preparedDraft = nil
            noticeText = "录音已中断，原来的文字已保留。"
            phase = .failed
        } else {
            preparedDraft = VoiceDraftMerger.merge(
                transcript: partial,
                into: originalDraft,
                insertionUTF16Offset: insertionUTF16Offset
            )
            preparedTranscript = partial
            noticeText = "录音已中断，已保留听到的内容。"
            phase = .draftReady
        }
    }

    /// VoiceOver and Switch Control can call the same start/finish lifecycle
    /// without relying on a continuous press gesture.
    func toggleAccessibleCapture(
        configuration: VoiceTranscriptionConfiguration,
        currentDraft: String,
        insertionUTF16Offset: Int? = nil
    ) async {
        switch phase {
        case .idle, .draftReady, .failed:
            await beginCapture(
                configuration: configuration,
                currentDraft: currentDraft,
                insertionUTF16Offset: insertionUTF16Offset
            )
        case .requestingPermission, .starting, .recording, .cancelling:
            await releaseCapture()
        case .finalizing:
            break
        }
    }

    /// Returns the prepared composer text once and resets transient voice UI.
    /// If the composer changed while finalization was in flight, preserve those
    /// edits and append the transcript rather than restoring the stale snapshot.
    func takePreparedDraft(currentDraft: String? = nil) -> String? {
        guard phase == .draftReady, let preparedDraft else { return nil }
        let resolvedDraft: String
        if let currentDraft, currentDraft != originalDraft, preparedTranscript.isEmpty == false {
            resolvedDraft = currentDraft.contains(preparedTranscript)
                ? currentDraft
                : VoiceDraftMerger.merge(
                    transcript: preparedTranscript,
                    into: currentDraft,
                    insertionUTF16Offset: nil
                )
        } else {
            resolvedDraft = preparedDraft
        }
        self.preparedDraft = nil
        preparedTranscript = ""
        originalDraft = ""
        insertionUTF16Offset = nil
        committedTranscript = ""
        currentPartialTranscript = ""
        noticeText = nil
        presentation.reset()
        audioMeter.reset()
        phase = .idle
        return resolvedDraft
    }

    func clearFailure() {
        guard phase == .failed else { return }
        noticeText = nil
        phase = .idle
    }

    private var canBeginCapture: Bool {
        switch phase {
        case .idle, .draftReady, .failed:
            return true
        case .requestingPermission, .starting, .recording, .cancelling, .finalizing:
            return false
        }
    }

    private func receive(_ update: VoiceTranscriptionUpdate, captureID: UUID) {
        guard activeCaptureID == captureID else { return }
        switch update {
        case let .partial(text):
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty == false {
                currentPartialTranscript = normalized
                updatePresentedTranscript(
                    live: appendingTranscript(normalized, to: committedTranscript)
                )
            }
        case let .finalTranscript(text):
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty == false {
                committedTranscript = appendingTranscript(normalized, to: committedTranscript)
                currentPartialTranscript = ""
                updatePresentedTranscript(live: committedTranscript)
            }
        case let .audioLevel(level):
            audioMeter.update(level)
        }
    }

    private func finishCapture() async {
        guard phase == .recording,
              let activeSession = session,
              let captureID = activeCaptureID else { return }
        phase = .finalizing
        durationTask?.cancel()
        durationTask = nil

        do {
            let result = try await activeSession.finish()
            guard activeCaptureID == captureID, phase == .finalizing else { return }
            let resultText = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let capturedText = appendingTranscript(currentPartialTranscript, to: committedTranscript)
            let finalText = resultText.isEmpty
                ? capturedText
                : appendingTranscript(resultText, to: committedTranscript)
            guard finalText.isEmpty == false else {
                fail("没有听清，请再试一次。")
                return
            }
            committedTranscript = finalText
            currentPartialTranscript = ""
            preparedTranscript = finalText
            updatePresentedTranscript(live: finalText)
            preparedDraft = VoiceDraftMerger.merge(
                transcript: finalText,
                into: originalDraft,
                insertionUTF16Offset: insertionUTF16Offset
            )
            session = nil
            activeCaptureID = nil
            noticeText = nil
            phase = .draftReady
        } catch {
            guard activeCaptureID == captureID, phase == .finalizing else { return }
            let partial = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial.isEmpty == false {
                preparedTranscript = partial
                preparedDraft = VoiceDraftMerger.merge(
                    transcript: partial,
                    into: originalDraft,
                    insertionUTF16Offset: insertionUTF16Offset
                )
                noticeText = "识别中断，已保留听到的内容。"
                session = nil
                activeCaptureID = nil
                phase = .draftReady
            } else {
                fail(publicMessage(for: error))
            }
        }
    }

    private func startDurationTimer(captureID: UUID) {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            guard let self else { return }
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(1))
                guard Task.isCancelled == false, self.activeCaptureID == captureID else { return }
                let elapsed = self.elapsedSeconds + 1
                self.presentation.updateElapsedSeconds(elapsed)
                if elapsed >= self.maximumDuration {
                    if self.phase == .cancelling {
                        self.cancelCapture()
                    } else {
                        await self.finishCapture()
                    }
                    return
                }
            }
        }
    }

    private func fail(_ message: String) {
        durationTask?.cancel()
        durationTask = nil
        session?.cancel()
        session = nil
        activeCaptureID = nil
        preparedDraft = nil
        preparedTranscript = ""
        originalDraft = ""
        insertionUTF16Offset = nil
        committedTranscript = ""
        currentPartialTranscript = ""
        releaseRequested = false
        cancellationRequested = false
        presentation.reset()
        audioMeter.reset()
        noticeText = message
        phase = .failed
    }

    private func updatePresentedTranscript(live: String) {
        presentation.updateTranscript(
            stable: committedTranscript,
            partial: currentPartialTranscript,
            live: live
        )
    }

    private func appendingTranscript(_ chunk: String, to existing: String) -> String {
        let existing = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let chunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing.isEmpty == false else { return chunk }
        guard chunk.isEmpty == false else { return existing }

        if existing == chunk || existing.hasSuffix(chunk) {
            return existing
        }
        if chunk.hasPrefix(existing) {
            return chunk
        }

        let normalizedExisting = normalizedTranscript(existing)
        let normalizedChunk = normalizedTranscript(chunk)
        if normalizedExisting == normalizedChunk || normalizedExisting.hasSuffix(normalizedChunk) {
            return existing
        }
        if normalizedChunk.hasPrefix(normalizedExisting) {
            return chunk
        }

        return VoiceDraftMerger.merge(
            transcript: chunk,
            into: existing,
            insertionUTF16Offset: nil
        )
    }

    private func normalizedTranscript(_ value: String) -> String {
        value.unicodeScalars
            .filter {
                CharacterSet.whitespacesAndNewlines.contains($0) == false &&
                CharacterSet.punctuationCharacters.contains($0) == false
            }
            .map(String.init)
            .joined()
    }

    private func publicMessage(for error: Error) -> String {
        if case VoiceTranscriptionError.missingConfiguration = error {
            return "语音服务暂时不可用，请稍后再试。"
        }
        if case VoiceTranscriptionError.invalidAudio = error {
            return "没有听清，请再试一次。"
        }
        return "语音输入没有完成，请再试一次。"
    }
}

enum VoiceDraftMerger {
    static func merge(
        transcript: String,
        into draft: String,
        insertionUTF16Offset: Int?
    ) -> String {
        let spokenText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard spokenText.isEmpty == false else { return draft }
        guard draft.isEmpty == false else { return spokenText }

        let insertionIndex = stringIndex(in: draft, utf16Offset: insertionUTF16Offset)
        let prefix = String(draft[..<insertionIndex])
        let suffix = String(draft[insertionIndex...])
        let beforeSeparator = separator(after: prefix, before: spokenText)
        let afterSeparator = separator(after: spokenText, before: suffix)
        return prefix + beforeSeparator + spokenText + afterSeparator + suffix
    }

    private static func stringIndex(in value: String, utf16Offset: Int?) -> String.Index {
        guard let utf16Offset else { return value.endIndex }
        let clamped = min(max(utf16Offset, 0), value.utf16.count)
        let utf16Index = value.utf16.index(value.utf16.startIndex, offsetBy: clamped)
        return String.Index(utf16Index, within: value) ?? value.endIndex
    }

    private static func separator(after prefix: String, before suffix: String) -> String {
        guard let left = prefix.last, let right = suffix.first else { return "" }
        if left.isWhitespace || right.isWhitespace || isPunctuation(left) || isPunctuation(right) {
            return ""
        }
        if left.isASCII, right.isASCII {
            return " "
        }
        return "，"
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }
}
