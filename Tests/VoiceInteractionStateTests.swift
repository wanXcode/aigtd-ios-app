import XCTest
@testable import AIGTDReminders

@MainActor
final class VoiceInteractionStateTests: XCTestCase {
    func testComposerPromptMatchesApprovedCopy() {
        XCTAssertEqual(VoiceInteractionState.composerPrompt, "发消息或按住说话…")
        XCTAssertEqual(VoiceInteractionState.focusedComposerPrompt, "请输入...")
    }

    func testReleaseProducesEditableDraftWithoutSending() async {
        let session = FakeVoiceSession(finalTranscript: "明天下午三点开会")
        let state = makeState(session: session)

        await state.beginCapture(
            configuration: configuration,
            currentDraft: "",
            insertionUTF16Offset: nil
        )
        await state.releaseCapture()

        XCTAssertEqual(state.phase, .draftReady)
        XCTAssertEqual(state.preparedDraft, "明天下午三点开会")
        XCTAssertEqual(session.finishCallCount, 1)
        XCTAssertEqual(state.takePreparedDraft(), "明天下午三点开会")
        XCTAssertEqual(state.phase, .idle)
    }

    func testVoiceAppendsToExistingDraft() async {
        let session = FakeVoiceSession(finalTranscript: "时间改成三点")
        let state = makeState(session: session)

        await state.beginCapture(
            configuration: configuration,
            currentDraft: "明天下午联系小王",
            insertionUTF16Offset: nil
        )
        await state.releaseCapture()

        XCTAssertEqual(state.preparedDraft, "明天下午联系小王，时间改成三点")
    }

    func testMultipleSpokenSentencesAreAccumulated() async {
        let session = FakeVoiceSession(finalTranscript: "第二句")
        let state = makeState(session: session)

        await state.beginCapture(
            configuration: configuration,
            currentDraft: "",
            insertionUTF16Offset: nil
        )
        await session.emit(.finalTranscript("第一句"))
        await session.emit(.partial("第二句"))

        XCTAssertEqual(state.liveTranscript, "第一句，第二句")

        await state.releaseCapture()

        XCTAssertEqual(state.preparedDraft, "第一句，第二句")
    }

    func testCumulativePartialTranscriptKeepsAllSpokenLines() async {
        let session = FakeVoiceSession(finalTranscript: "第一句，第二句，第三句")
        let state = makeState(session: session)

        await state.beginCapture(configuration: configuration, currentDraft: "")
        await session.emit(.partial("第一句"))
        await session.emit(.partial("第一句，第二句"))
        await session.emit(.partial("第一句，第二句，第三句"))

        XCTAssertEqual(state.liveTranscript, "第一句，第二句，第三句")

        await state.releaseCapture()
        XCTAssertEqual(state.preparedDraft, "第一句，第二句，第三句")
    }

    func testVoiceCanInsertAtUTF16CursorWithoutOverwritingDraft() async {
        let session = FakeVoiceSession(finalTranscript: "下午三点")
        let state = makeState(session: session)
        let draft = "明天开会"
        let cursor = "明天".utf16.count

        await state.beginCapture(
            configuration: configuration,
            currentDraft: draft,
            insertionUTF16Offset: cursor
        )
        await state.releaseCapture()

        XCTAssertEqual(state.preparedDraft, "明天，下午三点，开会")
    }

    func testSlideUpThenReleaseCancelsAndRestoresOriginalDraft() async {
        let session = FakeVoiceSession(finalTranscript: "不应保留")
        let state = makeState(session: session)

        await state.beginCapture(configuration: configuration, currentDraft: "原草稿")
        await session.emit(.partial("临时识别"))
        state.updateDrag(verticalTranslation: -100)
        XCTAssertEqual(state.phase, .cancelling)

        await state.releaseCapture()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.preparedDraft)
        XCTAssertEqual(session.cancelCallCount, 1)
    }

    func testSlidingBackDownResumesRecording() async {
        let session = FakeVoiceSession(finalTranscript: "补充内容")
        let state = makeState(session: session)

        await state.beginCapture(configuration: configuration, currentDraft: "原草稿")
        state.updateDrag(verticalTranslation: -100)
        state.updateDrag(verticalTranslation: -20)

        XCTAssertEqual(state.phase, .recording)
        await state.releaseCapture()
        XCTAssertEqual(state.preparedDraft, "原草稿，补充内容")
    }

    func testInterruptionPreservesReliablePartialTranscript() async {
        let session = FakeVoiceSession(finalTranscript: "")
        let state = makeState(session: session)

        await state.beginCapture(configuration: configuration, currentDraft: "原草稿")
        await session.emit(.partial("可靠片段"))
        state.handleInterruption()

        XCTAssertEqual(state.phase, .draftReady)
        XCTAssertEqual(state.preparedDraft, "原草稿，可靠片段")
        XCTAssertEqual(state.noticeText, "录音已中断，已保留听到的内容。")
    }

    func testDeniedPermissionKeepsOriginalDraftUntouched() async {
        let session = FakeVoiceSession(finalTranscript: "不会开始")
        let state = VoiceInteractionState(
            permissionAuthorizer: FakePermissionAuthorizer(result: .denied),
            sessionBuilder: FakeVoiceSessionBuilder(session: session)
        )

        await state.beginCapture(configuration: configuration, currentDraft: "原草稿")

        XCTAssertEqual(state.phase, .failed)
        XCTAssertNil(state.preparedDraft)
        XCTAssertEqual(session.startCallCount, 0)
        XCTAssertEqual(state.noticeText, "没有麦克风权限，请在系统设置中开启后再试。")
    }

    func testAccessibleToggleStartsAndStopsCapture() async {
        let session = FakeVoiceSession(finalTranscript: "无障碍输入")
        let state = makeState(session: session)

        await state.toggleAccessibleCapture(configuration: configuration, currentDraft: "")
        XCTAssertEqual(state.phase, .recording)
        await state.toggleAccessibleCapture(configuration: configuration, currentDraft: "")

        XCTAssertEqual(state.phase, .draftReady)
        XCTAssertEqual(state.preparedDraft, "无障碍输入")
    }

    func testSlideUpCancellationWhilePermissionIsPendingNeverStartsSession() async {
        let permission = DeferredPermissionAuthorizer()
        let session = FakeVoiceSession(finalTranscript: "不应写回")
        let state = VoiceInteractionState(
            permissionAuthorizer: permission,
            sessionBuilder: FakeVoiceSessionBuilder(session: session)
        )

        let beginTask = Task {
            await state.beginCapture(configuration: configuration, currentDraft: "原草稿")
        }
        await Task.yield()
        XCTAssertEqual(state.phase, .requestingPermission)

        state.updateDrag(verticalTranslation: -100)
        await state.releaseCapture()
        await permission.resolve(.granted)
        await beginTask.value

        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.preparedDraft)
        XCTAssertEqual(session.startCallCount, 0)
    }

    func testCancellationDuringFinalizationDiscardsLateTranscript() async {
        let session = DeferredFinishVoiceSession()
        let state = VoiceInteractionState(
            permissionAuthorizer: FakePermissionAuthorizer(result: .granted),
            sessionBuilder: DeferredVoiceSessionBuilder(session: session)
        )

        await state.beginCapture(configuration: configuration, currentDraft: "原草稿")
        let finishTask = Task { await state.releaseCapture() }
        await session.waitUntilFinishStarts()
        XCTAssertEqual(session.finishCallCount, 1)
        XCTAssertEqual(state.phase, .finalizing)

        state.cancelCapture()
        session.resolve(transcript: "迟到的识别结果")
        await finishTask.value

        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.preparedDraft)
    }

    private var configuration: VoiceTranscriptionConfiguration {
        VoiceTranscriptionConfiguration(
            provider: VoiceProviderPreset.doubao.rawValue,
            baseURL: "wss://example.com",
            appKey: "app",
            accessKey: "token",
            resourceID: "resource",
            cluster: "cluster",
            languageCode: "zh-CN",
            autoSendTranscript: true,
            interimResultsEnabled: true
        )
    }

    private func makeState(session: FakeVoiceSession) -> VoiceInteractionState {
        VoiceInteractionState(
            permissionAuthorizer: FakePermissionAuthorizer(result: .granted),
            sessionBuilder: FakeVoiceSessionBuilder(session: session)
        )
    }
}

private struct FakePermissionAuthorizer: VoiceRecordingPermissionAuthorizing {
    let result: VoiceRecordingPermissionState

    func requestPermission() async -> VoiceRecordingPermissionState {
        result
    }
}

private actor DeferredPermissionAuthorizer: VoiceRecordingPermissionAuthorizing {
    private var continuation: CheckedContinuation<VoiceRecordingPermissionState, Never>?

    func requestPermission() async -> VoiceRecordingPermissionState {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ result: VoiceRecordingPermissionState) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private struct FakeVoiceSessionBuilder: VoiceLiveTranscriptionSessionBuilding {
    let session: FakeVoiceSession

    func makeSession(configuration _: VoiceTranscriptionConfiguration) -> any VoiceLiveTranscriptionSession {
        session
    }
}

private struct DeferredVoiceSessionBuilder: VoiceLiveTranscriptionSessionBuilding {
    let session: DeferredFinishVoiceSession

    func makeSession(configuration _: VoiceTranscriptionConfiguration) -> any VoiceLiveTranscriptionSession {
        session
    }
}

private final class FakeVoiceSession: VoiceLiveTranscriptionSession, @unchecked Sendable {
    private let finalTranscript: String
    private var updateHandler: (@Sendable (VoiceTranscriptionUpdate) async -> Void)?
    private(set) var startCallCount = 0
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0

    init(finalTranscript: String) {
        self.finalTranscript = finalTranscript
    }

    func start(
        languageCode _: String?,
        onUpdate: @escaping @Sendable (VoiceTranscriptionUpdate) async -> Void
    ) throws {
        startCallCount += 1
        updateHandler = onUpdate
    }

    func finish() async throws -> VoiceTranscriptionResult {
        finishCallCount += 1
        return VoiceTranscriptionResult(
            transcript: finalTranscript,
            confidence: 1,
            provider: "fake",
            rawResponseSummary: ""
        )
    }

    func cancel() {
        cancelCallCount += 1
    }

    func emit(_ update: VoiceTranscriptionUpdate) async {
        await updateHandler?(update)
    }
}

private final class DeferredFinishVoiceSession: VoiceLiveTranscriptionSession, @unchecked Sendable {
    private var continuation: CheckedContinuation<VoiceTranscriptionResult, Error>?
    private var finishStartedContinuation: CheckedContinuation<Void, Never>?
    private(set) var finishCallCount = 0

    func start(
        languageCode _: String?,
        onUpdate _: @escaping @Sendable (VoiceTranscriptionUpdate) async -> Void
    ) throws {}

    func finish() async throws -> VoiceTranscriptionResult {
        finishCallCount += 1
        finishStartedContinuation?.resume()
        finishStartedContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {}

    func waitUntilFinishStarts() async {
        guard finishCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            if finishCallCount > 0 {
                continuation.resume()
            } else {
                finishStartedContinuation = continuation
            }
        }
    }

    func resolve(transcript: String) {
        continuation?.resume(
            returning: VoiceTranscriptionResult(
                transcript: transcript,
                confidence: 1,
                provider: "fake",
                rawResponseSummary: ""
            )
        )
        continuation = nil
    }
}
