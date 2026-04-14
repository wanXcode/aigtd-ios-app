import SwiftData
import SwiftUI
import AVFoundation
import UIKit

struct ChatHomeView: View {
    private static let bottomAnchorID = "chat-bottom-anchor"
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]
    @Query(sort: \ChatMessage.createdAt) private var messages: [ChatMessage]
    @Query(sort: \ActionLog.createdAt) private var actionLogs: [ActionLog]
    @Query(sort: \ModelProfile.displayName) private var modelProfiles: [ModelProfile]
    @Query(sort: \AgentDocument.updatedAt, order: .forward) private var agentDocuments: [AgentDocument]
    @Query private var preferences: [UserPreference]
    @State private var draft = ""
    @State private var isSending = false
    @State private var isStreamingReply = false
    @State private var runtimeNotice: RuntimeNotice?
    @State private var modelSetupPrompt: ModelSetupPrompt?
    @State private var hasSeenModelSetupPrompt = false
    @State private var isVoicePrimed = false
    @State private var isRecordingVoice = false
    @State private var isTranscribingVoice = false
    @State private var isFinalizingVoice = false
    @State private var keyboardInset: CGFloat = 0
    @State private var activeVoiceSession: DoubaoOfficialASRSession?
    @State private var draftBeforeVoiceInput = ""
    @State private var hasVoiceUpdatedDraft = false
    @State private var committedVoiceTranscript = ""
    @State private var liveVoiceTranscript = ""
    @State private var isStoppingVoice = false
    @State private var activeVoiceSessionID: UUID?
    @State private var voiceTailDotsCount = 0
    @State private var composerFocusRequestID = UUID()
    @State private var isComposerFocused = false
    private let agentRuntime = AgentRuntimeService()
    @StateObject private var composerFocusBridge = ComposerTextViewFocusBridge()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ChatIntroCard(
                        isUsingRemoteModel: activeModelConfiguration != nil,
                        runtimeNotice: runtimeNotice
                    )

                    if activeMessages.isEmpty {
                        StarterPromptsCard { prompt in
                            Task {
                                await sendWithoutPrompt(prompt, clearDraft: false)
                            }
                        }
                    } else {
                        ForEach(activeMessages, id: \.id) { message in
                            ChatMessageRow(
                                message: message,
                                actionLog: latestActionLogByMessageID[message.id],
                                onPrimaryAction: handleCardPrimaryAction
                            )
                            .id(message.id)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissComposerFocus()
                }
            }
            .background(chatBackground)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .onAppear {
                scrollToLatestMessage(using: proxy, animated: false)
            }
            .onChange(of: activeMessages.count) { _, _ in
                scrollToLatestMessage(using: proxy, animated: true)
            }
            .onChange(of: keyboardInset) { _, newInset in
                if newInset <= 0.5 {
                    // Keyboard just dismissed: always pin back to the latest message.
                    scrollToLatestMessage(using: proxy, animated: true)
                    return
                }
                guard isComposerFocused || isRecordingVoice || isTranscribingVoice else { return }
                scrollToLatestMessage(using: proxy, animated: true)
            }
            .onChange(of: isComposerFocused) { _, focused in
                guard focused else { return }
                scrollToLatestMessage(using: proxy, animated: true)
            }
            .onChange(of: appModel.selectedTab) { _, newValue in
                guard newValue == .chat else { return }
                scrollToLatestMessage(using: proxy, animated: false)
            }
            .onChange(of: activeMessageScrollSignature) { _, _ in
                scrollToLatestMessage(using: proxy, animated: true)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatComposer(
                    draft: $draft,
                    isSending: isSending,
                    isStreamingReply: isStreamingReply,
                    isVoicePrimed: isVoicePrimed,
                    isRecordingVoice: isRecordingVoice,
                    isTranscribingVoice: isTranscribingVoice,
                    isFinalizingVoice: isFinalizingVoice,
                    tailHighlightLength: voiceTailHighlightLength,
                    tailAnimatedDotsCount: voiceTailAnimatedDotsCount,
                    focusRequestID: $composerFocusRequestID,
                    isFocused: $isComposerFocused,
                    focusBridge: composerFocusBridge,
                    onToggleVoice: {
                        Task {
                            await handleVoiceToggle()
                        }
                    },
                    onSend: {
                        Task {
                            await sendDraft()
                        }
                    },
                    onVoiceInputTakeoverByKeyboard: {
                        handleVoiceKeyboardTakeover()
                    }
                )
            }
        }
        .navigationTitle("AIGTD")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $modelSetupPrompt, onDismiss: {
            isComposerFocused = true
        }) { prompt in
            ModelSetupPromptSheet(
                pendingDraft: prompt.pendingDraft,
                onGoToSettings: {
                    hasSeenModelSetupPrompt = true
                    modelSetupPrompt = nil
                    appModel.routeToAgentSetup(with: prompt.pendingDraft)
                },
                onSendNow: {
                    hasSeenModelSetupPrompt = true
                    modelSetupPrompt = nil
                    Task {
                        await sendWithoutPrompt(prompt.pendingDraft, clearDraft: true)
                    }
                },
                onCancel: {
                    hasSeenModelSetupPrompt = true
                    modelSetupPrompt = nil
                }
            )
            .presentationDetents([.medium, .large])
            .presentationContentInteraction(.scrolls)
            .presentationDragIndicator(.visible)
        }
        .task {
            ensureMainSession()
            restorePendingDraftIfNeeded()
        }
        .onChange(of: appModel.selectedTab) { _, newValue in
            guard newValue == .chat else { return }
            restorePendingDraftIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            keyboardInset = keyboardInsetValue(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardInset = 0
        }
        .task(id: shouldAnimateVoiceTailDots) {
            guard shouldAnimateVoiceTailDots else {
                voiceTailDotsCount = 0
                return
            }
            if voiceTailDotsCount == 0 {
                voiceTailDotsCount = 1
            }
            while Task.isCancelled == false && shouldAnimateVoiceTailDots {
                try? await Task.sleep(for: .milliseconds(380))
                guard shouldAnimateVoiceTailDots else { break }
                voiceTailDotsCount = (voiceTailDotsCount % 3) + 1
            }
        }
    }

    private var activeSession: ChatSession? {
        sessions.first
    }

    private var activeMessages: [ChatMessage] {
        guard let activeSession else { return [] }
        return messages.filter { $0.sessionID == activeSession.id }
    }

    private var latestActionLogByMessageID: [UUID: ActionLog] {
        guard let activeSession else { return [:] }
        var lookup: [UUID: ActionLog] = [:]
        for log in actionLogs where log.sessionID == activeSession.id {
            guard let messageID = log.messageID else { continue }
            if let existing = lookup[messageID], existing.createdAt >= log.createdAt {
                continue
            }
            lookup[messageID] = log
        }
        return lookup
    }

    private var activeMessageScrollSignature: String {
        guard let last = activeMessages.last else { return "" }
        return "\(last.id.uuidString)-\(last.text.count)-\(last.status)"
    }

    private var voiceTailHighlightLength: Int {
        guard isRecordingVoice || isTranscribingVoice else { return 0 }
        let transcript = composeVoiceTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcript.isEmpty == false else { return 0 }
        return min(3, transcript.count)
    }

    private var voiceTailAnimatedDotsCount: Int {
        guard shouldAnimateVoiceTailDots else { return 0 }
        return max(1, voiceTailDotsCount)
    }

    private var isVoiceLiveRecognizing: Bool {
        isRecordingVoice || isTranscribingVoice
    }

    private var shouldAnimateVoiceTailDots: Bool {
        guard isVoiceLiveRecognizing else { return false }
        let transcript = composeVoiceTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty == false
    }

    private var activeModelConfiguration: AgentModelConfiguration? {
        guard let profile = modelProfiles.first(where: \.isActive) else { return nil }
        return AgentModelConfiguration(
            provider: profile.provider,
            wireAPI: profile.wireAPI,
            modelID: profile.modelID,
            baseURL: profile.baseURL,
            apiKey: profile.apiKeyReference,
            temperature: profile.temperature,
            maxTokens: profile.maxTokens,
            timeoutSeconds: profile.timeoutSeconds
        )
    }

    private var activeVoicePreference: UserPreference? {
        preferences.first
    }

    private var activeVoiceConfiguration: VoiceTranscriptionConfiguration? {
        guard let preference = activeVoicePreference, preference.voiceEnabled else { return nil }
        let provider = preference.voiceProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        let appKey = preference.voiceAppKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessKey = preference.voiceAPIKeyReference.trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceID = preference.voiceModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cluster = preference.voiceCluster.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.isEmpty == false,
              appKey.isEmpty == false,
              accessKey.isEmpty == false,
              resourceID.isEmpty == false,
              cluster.isEmpty == false else {
            return nil
        }
        return VoiceTranscriptionConfiguration(
            provider: provider,
            baseURL: preference.voiceBaseURL,
            appKey: appKey,
            accessKey: accessKey,
            resourceID: resourceID,
            cluster: cluster,
            languageCode: preference.voiceLanguageCode.isEmpty ? "zh-CN" : preference.voiceLanguageCode,
            autoSendTranscript: preference.voiceAutoSendTranscript,
            interimResultsEnabled: true
        )
    }

    private func ensureMainSession() {
        guard sessions.isEmpty else { return }
        let session = ChatSession(title: "主会话")
        modelContext.insert(session)
        try? modelContext.save()
    }

    private func sendDraft() async {
        guard isSending == false else { return }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty == false else { return }

        if shouldPromptForModelSetup(beforeSending: content) {
            hasSeenModelSetupPrompt = true
            modelSetupPrompt = ModelSetupPrompt(pendingDraft: content)
            isComposerFocused = false
            composerFocusBridge.blur()
            runtimeNotice = RuntimeNotice(
                text: "第一次发送前，先确认一下是否要配置模型。也可以先把这条消息直接发出去。",
                tone: .info
            )
            return
        }

        await sendWithoutPrompt(content, clearDraft: true)
    }

    private func sendPrompt(_ content: String) async {
        let session: ChatSession
        if let existing = activeSession {
            session = existing
        } else {
            let created = ChatSession(title: "主会话")
            modelContext.insert(created)
            session = created
        }

        let userMessage = ChatMessage(
            sessionID: session.id,
            role: "user",
            text: content
        )
        modelContext.insert(userMessage)

        let assistantMessage = ChatMessage(
            sessionID: session.id,
            role: "assistant",
            text: "",
            actionResultSummary: "",
            status: "streaming"
        )
        modelContext.insert(assistantMessage)
        try? modelContext.save()

        let runtimeContext = AIGTDAgentDocumentStore.runtimeContext(from: agentDocuments)
        let result = await agentRuntime.respond(
            to: content,
            reminderLists: appModel.reminderLists,
            reminderItems: appModel.reminderItems,
            configuration: activeModelConfiguration,
            agentContext: runtimeContext,
            onTextUpdate: { partialText in
                if partialText.isEmpty == false {
                    isStreamingReply = true
                }
                assistantMessage.text = partialText
                assistantMessage.status = "streaming"
                try? modelContext.save()
            }
        )
        let executionResult = resolveExecutionResult(
            userContent: content,
            remoteResult: result,
            runtimeContext: runtimeContext
        )
        updateRuntimeNotice(using: result)
        assistantMessage.text = result.reply
        assistantMessage.actionResultSummary = executionResult.actionType == nil ? "" : executionResult.summary
        assistantMessage.status = "sent"
        isStreamingReply = false
        var createdLogID: UUID?
        if let actionType = executionResult.actionType {
            let startsPending = [
                MockAgentIntent.createList.rawValue,
                MockAgentIntent.createReminder.rawValue,
                MockAgentIntent.moveReminder.rawValue,
                MockAgentIntent.completeReminder.rawValue
            ].contains(actionType)
            let log = ActionLog(
                sessionID: session.id,
                messageID: assistantMessage.id,
                actionType: actionType,
                payloadJSON: executionResult.payloadJSON,
                executionStatus: startsPending ? "pending" : "success",
                errorMessage: "",
                executedAt: startsPending ? nil : .now,
                undoToken: ""
            )
            modelContext.insert(log)
            createdLogID = log.id
        }

        session.updatedAt = .now
        session.lastMessagePreview = content

        try? modelContext.save()

        if let createdLogID {
            await executeResultAction(logID: createdLogID, result: executionResult)
        }
    }

    private func sendWithoutPrompt(_ content: String, clearDraft: Bool) async {
        guard isSending == false else { return }
        isSending = true
        isStreamingReply = false
        if clearDraft {
            draft = ""
        }
        defer {
            isSending = false
        }
        await sendPrompt(content)
    }

    private func handleVoiceKeyboardTakeover() {
        guard isVoicePrimed || isRecordingVoice || isTranscribingVoice || isFinalizingVoice || activeVoiceSession != nil else { return }
        activeVoiceSession?.cancel()
        activeVoiceSession = nil
        activeVoiceSessionID = nil
        isVoicePrimed = false
        isRecordingVoice = false
        isTranscribingVoice = false
        isFinalizingVoice = false
        isStoppingVoice = false
        committedVoiceTranscript = ""
        liveVoiceTranscript = ""
        hasVoiceUpdatedDraft = false
        draftBeforeVoiceInput = removingVoiceIndicatorDots(from: draft)
    }

    private func beginVoiceInput() async {
        guard isSending == false else { return }
        guard isVoicePrimed == false,
              isRecordingVoice == false,
              isTranscribingVoice == false,
              isFinalizingVoice == false,
              activeVoiceSession == nil else { return }
        guard let configuration = activeVoiceConfiguration else {
            runtimeNotice = RuntimeNotice(
                text: "先去 Agent 里把豆包语音识别配置好，再来用语音输入。",
                tone: .warning
            )
            return
        }

        draftBeforeVoiceInput = draft
        hasVoiceUpdatedDraft = false
        committedVoiceTranscript = ""
        liveVoiceTranscript = ""
        isStoppingVoice = false
        // Keep keyboard open when starting voice input.
        isComposerFocused = true
        composerFocusRequestID = UUID()
        composerFocusBridge.focus()
        isVoicePrimed = true
        isRecordingVoice = false
        isTranscribingVoice = false
        isFinalizingVoice = false

        do {
            let permissionResult = await requestMicrophonePermissionIfNeeded()
            switch permissionResult {
            case .denied:
                isVoicePrimed = false
                runtimeNotice = RuntimeNotice(
                    text: "没有麦克风权限，先去系统设置里开启一下。",
                    tone: .warning
                )
                return
            case .requestedNow:
                isVoicePrimed = false
                runtimeNotice = RuntimeNotice(
                    text: "麦克风权限已经授权好了。你再点一次语音按钮开始录音。",
                    tone: .info
                )
                return
            case .granted:
                break
            }
            let session = DoubaoOfficialASRSession(configuration: configuration)
            let sessionID = UUID()
            try session.start(languageCode: configuration.languageCode) { update in
                await MainActor.run {
                    guard activeVoiceSessionID == sessionID else { return }
                    switch update {
                    case let .partial(text):
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                            committedVoiceTranscript = promotePreviousLiveTranscriptIfNeeded(
                                committed: committedVoiceTranscript,
                                currentLive: liveVoiceTranscript,
                                incoming: text
                            )
                            liveVoiceTranscript = text
                            let updatedDraft = mergedVoiceDraft(composeVoiceTranscript())
                            if updatedDraft != draft {
                                draft = updatedDraft
                            }
                            hasVoiceUpdatedDraft = true
                            if isStoppingVoice == false {
                                isVoicePrimed = false
                                isRecordingVoice = true
                                isTranscribingVoice = true
                            }
                        }
                    case let .finalTranscript(text):
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                            committedVoiceTranscript = appendVoiceChunk(
                                committedVoiceTranscript,
                                chunk: text
                            )
                            liveVoiceTranscript = ""
                            let updatedDraft = mergedVoiceDraft(composeVoiceTranscript())
                            if updatedDraft != draft {
                                draft = updatedDraft
                            }
                            hasVoiceUpdatedDraft = true
                        }
                        if isStoppingVoice == false {
                            isTranscribingVoice = false
                        }
                    }
                }
            }
            activeVoiceSession = session
            activeVoiceSessionID = sessionID
            isRecordingVoice = true
            isComposerFocused = true
            composerFocusRequestID = UUID()
            composerFocusBridge.focus()
            runtimeNotice = RuntimeNotice(
                text: "开始录音了。你再点一次语音按钮就会结束并整理文字。",
                tone: .info
            )
        } catch {
            if let activeVoiceSession {
                activeVoiceSession.cancel()
            }
            activeVoiceSession = nil
            activeVoiceSessionID = nil
            isVoicePrimed = false
            isRecordingVoice = false
            runtimeNotice = RuntimeNotice(
                text: "开始录音失败：\(readableVoiceError(error))",
                tone: .warning
            )
        }
    }

    private func endVoiceInput(cancelled: Bool) async {
        if cancelled {
            cancelVoiceInput()
            return
        }

        guard isVoicePrimed || isRecordingVoice || activeVoiceSession != nil else { return }
        guard activeVoiceSession != nil else {
            isVoicePrimed = false
            isRecordingVoice = false
            runtimeNotice = RuntimeNotice(
                text: "说话时间太短，我还没来得及听清。",
                tone: .warning
            )
            return
        }

        await stopRecordingAndTranscribe()
    }

    private func handleVoiceToggle() async {
        if isVoicePrimed || isRecordingVoice || activeVoiceSession != nil {
            await endVoiceInput(cancelled: false)
        } else {
            await beginVoiceInput()
        }
    }

    private func stopRecordingAndTranscribe() async {
        guard let configuration = activeVoiceConfiguration else { return }
        guard let activeVoiceSession else { return }

        do {
            self.activeVoiceSession = nil
            activeVoiceSessionID = nil
            isVoicePrimed = false
            isRecordingVoice = false
            isTranscribingVoice = false
            isFinalizingVoice = true
            isStoppingVoice = true
            let result = try await finishVoiceSessionWithTimeout(activeVoiceSession)

            let transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard transcript.isEmpty == false else {
                isFinalizingVoice = false
                isStoppingVoice = false
                runtimeNotice = RuntimeNotice(
                    text: "这次没识别出可用文字，你再说一遍试试。",
                    tone: .warning
                )
                return
            }

            try? await Task.sleep(for: .milliseconds(350))
            committedVoiceTranscript = appendVoiceChunk(committedVoiceTranscript, chunk: transcript)
            liveVoiceTranscript = ""
            let finalizedDraft = mergedVoiceDraft(refineVoiceTranscript(composeVoiceTranscript()))
            if finalizedDraft != draft {
                draft = finalizedDraft
            }
            isFinalizingVoice = false
            isStoppingVoice = false
            runtimeNotice = RuntimeNotice(
                text: "语音已转成文字，你可以直接发出去了。",
                tone: .success
            )

            if configuration.autoSendTranscript {
                await sendWithoutPrompt(transcript, clearDraft: true)
            } else {
                isComposerFocused = true
                composerFocusRequestID = UUID()
                composerFocusBridge.focus()
            }
        } catch {
            activeVoiceSession.cancel()
            self.activeVoiceSession = nil
            activeVoiceSessionID = nil
            isVoicePrimed = false
            isRecordingVoice = false
            isTranscribingVoice = false
            isFinalizingVoice = false
            isStoppingVoice = false
            let fallbackTranscript = composeVoiceTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
            if fallbackTranscript.isEmpty == false {
                draft = mergedVoiceDraft(fallbackTranscript)
                runtimeNotice = RuntimeNotice(
                    text: "我先把刚才识别到的内容留在输入框里，你可以看一下再发。",
                    tone: .info
                )
                isComposerFocused = true
                composerFocusRequestID = UUID()
                composerFocusBridge.focus()
                return
            }
            runtimeNotice = RuntimeNotice(
                text: readableVoiceError(error),
                tone: .warning
            )
        }
    }

    private func cancelVoiceInput() {
        activeVoiceSession?.cancel()
        activeVoiceSession = nil
        activeVoiceSessionID = nil
        isVoicePrimed = false
        isRecordingVoice = false
        isTranscribingVoice = false
        isFinalizingVoice = false
        isStoppingVoice = false
        committedVoiceTranscript = ""
        liveVoiceTranscript = ""
        if hasVoiceUpdatedDraft {
            draft = draftBeforeVoiceInput
        }
        runtimeNotice = RuntimeNotice(
            text: "这次语音输入已取消。",
            tone: .info
        )
    }

    private func mergedVoiceDraft(_ transcript: String) -> String {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.isEmpty == false else { return draft }
        let prefix = draftBeforeVoiceInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.isEmpty == false else { return cleaned }
        if cleaned.hasPrefix(prefix) {
            return cleaned
        }
        let separator = prefix.hasSuffix("，") || prefix.hasSuffix("。") || prefix.hasSuffix(",") || prefix.hasSuffix(".") ? "" : " "
        return prefix + separator + cleaned
    }

    private func composeVoiceTranscript() -> String {
        let committed = committedVoiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let live = liveVoiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty { return live }
        if live.isEmpty { return committed }
        if committed.hasSuffix(live) { return committed }
        if live.hasPrefix(committed) { return live }
        let separator = committed.hasSuffix("，") || committed.hasSuffix("。") || committed.hasSuffix(",") || committed.hasSuffix(".") ? "" : " "
        return committed + separator + live
    }

    private func appendVoiceChunk(_ existing: String, chunk: String) -> String {
        let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedChunk.isEmpty == false else { return trimmedExisting }
        guard trimmedExisting.isEmpty == false else { return trimmedChunk }
        if trimmedExisting.hasSuffix(trimmedChunk) { return trimmedExisting }
        if trimmedChunk.hasPrefix(trimmedExisting) { return trimmedChunk }
        let separator = trimmedExisting.hasSuffix("，") || trimmedExisting.hasSuffix("。") || trimmedExisting.hasSuffix(",") || trimmedExisting.hasSuffix(".") ? "" : " "
        return trimmedExisting + separator + trimmedChunk
    }

    private func refineVoiceTranscript(_ transcript: String) -> String {
        var value = transcript
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: "\n\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let punctuationPairs = [
            (" ,", ","),
            (" .", "."),
            (" !", "!"),
            (" ?", "?"),
            (" ，", "，"),
            (" 。", "。"),
            (" ？", "？"),
            (" ！", "！")
        ]
        for (source, target) in punctuationPairs {
            value = value.replacingOccurrences(of: source, with: target)
        }
        return value
    }

    private func removingVoiceIndicatorDots(from value: String) -> String {
        if value.hasSuffix("...") {
            return String(value.dropLast(3))
        }
        if value.hasSuffix("..") {
            return String(value.dropLast(2))
        }
        if value.hasSuffix(".") {
            return String(value.dropLast())
        }
        if let strayDotsRange = value.range(
            of: #"\.{2,3}(?=[^\s]{1,8}$)"#,
            options: .regularExpression
        ) {
            return value.replacingCharacters(in: strayDotsRange, with: "")
        }
        return value
    }

    private func promotePreviousLiveTranscriptIfNeeded(
        committed: String,
        currentLive: String,
        incoming: String
    ) -> String {
        let trimmedCurrent = currentLive.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCurrent.isEmpty == false, trimmedIncoming.isEmpty == false else {
            return committed
        }
        if trimmedIncoming == trimmedCurrent { return committed }
        if trimmedIncoming.hasPrefix(trimmedCurrent) { return committed }
        if trimmedCurrent.hasPrefix(trimmedIncoming) { return committed }
        return appendVoiceChunk(committed, chunk: trimmedCurrent)
    }

    private func finishVoiceSessionWithTimeout(
        _ session: DoubaoOfficialASRSession
    ) async throws -> VoiceTranscriptionResult {
        try await withThrowingTaskGroup(of: VoiceTranscriptionResult.self) { group in
            group.addTask {
                try await session.finish()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(6))
                throw VoiceTranscriptionError.connectionFailed("语音整理超时了，哥哥你再试一下。")
            }

            guard let first = try await group.next() else {
                throw VoiceTranscriptionError.connectionFailed("语音整理失败了，哥哥你再试一下。")
            }
            group.cancelAll()
            return first
        }
    }

    private enum MicrophonePermissionResult {
        case granted
        case requestedNow
        case denied
    }

    private func requestMicrophonePermissionIfNeeded() async -> MicrophonePermissionResult {
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
            return granted ? .requestedNow : .denied
        @unknown default:
            return .denied
        }
    }

    private func readableVoiceError(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           description.isEmpty == false {
            return description
        }
        return error.localizedDescription
    }

    private func executeResultAction(
        logID: UUID,
        result: MockAgentResult
    ) async {
        guard let log = actionLogs.first(where: { $0.id == logID }) else { return }

        if result.actionType == MockAgentIntent.createList.rawValue {
            guard let envelope = decodePayload(from: result.payloadJSON),
                  let listName = envelope.action.entities["list_name"]?.nonEmpty else {
                log.executionStatus = "failed"
                log.errorMessage = "无法解析要创建的列表名称。"
                log.executedAt = .now
                try? modelContext.save()
                return
            }

            let created = await appModel.createReminderList(named: listName)
            log.executionStatus = created ? "success" : "failed"
            log.errorMessage = created ? "" : appModel.reminderListsErrorMessage.nonEmpty ?? "创建列表失败。"
            log.executedAt = .now
            try? modelContext.save()
            return
        }

        if result.actionType == MockAgentIntent.createReminder.rawValue {
            guard let envelope = decodePayload(from: result.payloadJSON),
                  let title = envelope.action.entities["title"]?.nonEmpty else {
                log.executionStatus = "failed"
                log.errorMessage = "无法解析要创建的任务标题。"
                log.executedAt = .now
                try? modelContext.save()
                return
            }

            let dueDate = parseISODate(envelope.action.entities["due_date"])
            let preferredListName = envelope.action.entities["preferred_list_name"]?.nonEmpty
            let sourceText = envelope.action.entities["source_text"] ?? ""
            let note = envelope.action.entities["note"]?.nonEmpty ?? sourceText

            do {
                let reminderID = try ReminderStoreService().createReminder(
                    input: ReminderCreateInput(
                        title: title,
                        notes: note,
                        dueDate: dueDate,
                        preferredListName: preferredListName
                    )
                )
                await appModel.refreshReminderLists()
                appModel.prepareReminderFocus(identifier: reminderID)
                log.executionStatus = "success"
                log.errorMessage = ""
            } catch {
                log.executionStatus = "failed"
                log.errorMessage = error.localizedDescription
            }
            log.executedAt = .now
            try? modelContext.save()
            return
        }

        if result.actionType == MockAgentIntent.moveReminder.rawValue {
            guard let envelope = decodePayload(from: result.payloadJSON),
                  let target = actionEntityValue(
                    in: envelope.action.entities,
                    keys: ["target", "title", "task_title", "task", "object"]
                  ),
                  let destination = actionEntityValue(
                    in: envelope.action.entities,
                    keys: ["destination_list", "preferred_list_name", "list_name", "destination"]
                  ) else {
                log.executionStatus = "failed"
                log.errorMessage = "无法解析要移动的任务或目标列表。"
                log.executedAt = .now
                try? modelContext.save()
                return
            }

            do {
                _ = try await ReminderStoreService().moveReminder(
                    targetText: target,
                    destinationListName: destination
                )
                await appModel.refreshReminderLists()
                log.executionStatus = "success"
                log.errorMessage = ""
            } catch {
                log.executionStatus = "failed"
                log.errorMessage = error.localizedDescription
            }
            log.executedAt = .now
            try? modelContext.save()
            return
        }

        if result.actionType == MockAgentIntent.completeReminder.rawValue {
            guard let envelope = decodePayload(from: result.payloadJSON),
                  let target = actionEntityValue(
                    in: envelope.action.entities,
                    keys: ["target", "title", "task_title", "task", "object"]
                  ) else {
                log.executionStatus = "failed"
                log.errorMessage = "无法解析要完成的任务。"
                log.executedAt = .now
                try? modelContext.save()
                return
            }

            do {
                _ = try await ReminderStoreService().completeReminder(targetText: target)
                await appModel.refreshReminderLists()
                log.executionStatus = "success"
                log.errorMessage = ""
            } catch {
                log.executionStatus = "failed"
                log.errorMessage = error.localizedDescription
            }
            log.executedAt = .now
            try? modelContext.save()
            return
        }

        log.executionStatus = "success"
        log.executedAt = .now
        try? modelContext.save()
    }

    private func decodePayload(from json: String) -> MockAgentEnvelope? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MockAgentEnvelope.self, from: data)
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value, value.isEmpty == false else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func actionEntityValue(
        in entities: [String: String],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = entities[key]?.nonEmpty {
                return value
            }
        }
        return nil
    }

    private func resolveExecutionResult(
        userContent: String,
        remoteResult: MockAgentResult,
        runtimeContext: AIGTDAgentRuntimeContext?
    ) -> MockAgentResult {
        let executableIntents: Set<String> = [
            MockAgentIntent.createReminder.rawValue,
            MockAgentIntent.createList.rawValue,
            MockAgentIntent.moveReminder.rawValue,
            MockAgentIntent.completeReminder.rawValue
        ]

        if let actionType = remoteResult.actionType,
           executableIntents.contains(actionType),
           decodePayload(from: remoteResult.payloadJSON) != nil {
            return remoteResult
        }
        return remoteResult
    }

    private func scrollToLatestMessage(using proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func dismissComposerFocus() {
        guard isComposerFocused else { return }
        isComposerFocused = false
        composerFocusBridge.blur()
    }

    private func handleCardPrimaryAction(_ log: ActionLog) {
        switch log.actionType {
        case MockAgentIntent.createReminder.rawValue,
             MockAgentIntent.createList.rawValue,
             MockAgentIntent.summarizeLists.rawValue:
            appModel.selectedTab = .reminders
        default:
            if let envelope = decodePayload(from: log.payloadJSON),
               let followUp = envelope.followUpPrompt?.nonEmpty {
            draft = followUp
            isComposerFocused = true
            composerFocusRequestID = UUID()
            composerFocusBridge.focus()
        }
    }
    }

    private func updateRuntimeNotice(using result: MockAgentResult) {
        if result.summary.contains("远端模型暂时不可用") {
            runtimeNotice = RuntimeNotice(
                text: "远端模型暂时不可用，这次未能完成回复。",
                tone: .warning
            )
            return
        }

        if result.summary.contains("远端返回格式暂未兼容") {
            runtimeNotice = RuntimeNotice(
                text: "模型已经连上了，但这次聊天返回格式还没完全兼容。",
                tone: .warning
            )
            return
        }

        if activeModelConfiguration != nil {
            runtimeNotice = RuntimeNotice(
                text: "当前回复来自已连接模型。",
                tone: .success
            )
        } else {
            runtimeNotice = RuntimeNotice(
                text: "当前还没有配置可用模型。",
                tone: .warning
            )
        }
    }

    private func shouldPromptForModelSetup(beforeSending content: String) -> Bool {
        guard activeModelConfiguration == nil else { return false }
        guard hasSeenModelSetupPrompt == false else { return false }
        return content.isEmpty == false
    }

    private func restorePendingDraftIfNeeded() {
        guard appModel.shouldResumeChatComposer else { return }
        let restored = appModel.consumePendingChatDraft()
        if restored.isEmpty == false {
            draft = restored
        }
        appModel.shouldResumeChatComposer = false
        isComposerFocused = true
        composerFocusRequestID = UUID()
        composerFocusBridge.focus()
        runtimeNotice = RuntimeNotice(
            text: "模型已保存，你可以继续发送刚才那条消息了。",
            tone: .success
        )
    }

    private var chatBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.96, blue: 0.92),
                Color(red: 0.95, green: 0.97, blue: 0.99)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func keyboardInsetValue(from notification: Notification) -> CGFloat {
        guard
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
            let window = activeKeyboardWindow()
        else {
            return 0
        }

        let converted = window.convert(frame, from: nil)
        let intersection = window.bounds.intersection(converted)
        return max(0, intersection.height - window.safeAreaInsets.bottom)
    }

    private func activeKeyboardWindow() -> UIWindow? {
        if let composerWindow = composerFocusBridge.textView?.window {
            return composerWindow
        }

        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }

        for scene in scenes {
            if let keyWindow = scene.windows.first(where: \.isKeyWindow) {
                return keyWindow
            }
        }

        for scene in scenes {
            if let firstWindow = scene.windows.first {
                return firstWindow
            }
        }

        return nil
    }
}

private struct ModelSetupPrompt: Identifiable {
    let id = UUID()
    let pendingDraft: String
}

private struct ModelSetupPromptSheet: View {
    let pendingDraft: String
    let onGoToSettings: () -> Void
    let onSendNow: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 40, height: 5)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)

                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.orange.opacity(0.18),
                                        Color.yellow.opacity(0.12)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("先配置模型会更完整")
                            .font(.title3.bold())
                            .fixedSize(horizontal: false, vertical: true)
                        Text("现在就能进设置，也可以先按你的原话发出去试试看。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("你已经输入了一条消息。现在去设置模型 API，可以获得完整的 AI 理解能力；也可以先直接发送这条消息。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Label("待发送内容", systemImage: "message")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .bottom, spacing: 10) {
                        Circle()
                            .fill(Color.accentColor.opacity(0.16))
                            .frame(width: 28, height: 28)
                            .overlay {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }

                        Text(pendingDraft)
                            .font(.body)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.62))
                )

                Button("去设置模型", action: onGoToSettings)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                Button("先直接发送", action: onSendNow)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                Button("取消", action: onCancel)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.99, green: 0.98, blue: 0.95),
                    Color(red: 0.96, green: 0.97, blue: 0.99)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

#Preview {
    NavigationStack {
        ChatHomeView()
    }
    .environment(AppModel.previewFinished)
    .modelContainer(for: [ChatSession.self, ChatMessage.self, ActionLog.self], inMemory: true)
}

private struct ActionResultCardView: View {
    let log: ActionLog
    let onPrimaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(cardAccent.opacity(0.16))
                    Image(systemName: iconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(cardAccent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                statusPill
            }

            if payloadLines.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(payloadLines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(cardAccent.opacity(0.75))
                                .frame(width: 6, height: 6)
                                .padding(.top, 5)
                            Text(line)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }

            if let primaryActionTitle {
                Button(primaryActionTitle, action: onPrimaryAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(cardAccent.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
    }

    private var title: String {
        switch log.actionType {
        case "create_reminder":
            return log.executionStatus == "success" ? "记好了" : "正在记"
        case "create_list":
            return log.executionStatus == "success" ? "清单建好了" : "正在建清单"
        case "summarize_lists":
            return "我看过了"
        case "capture_message":
            return "我先接住了"
        case "move_reminder":
            return log.executionStatus == "success" ? "改好了" : "正在改"
        case "complete_reminder":
            return log.executionStatus == "success" ? "完成了" : "正在完成"
        default:
            return "我处理好了"
        }
    }

    private var subtitle: String {
        switch log.actionType {
        case "create_reminder":
            switch log.executionStatus {
            case "pending":
                return "我在帮你写进提醒事项"
            case "failed":
                return log.errorMessage.nonEmpty ?? "任务暂时还没创建成功"
            default:
                return "这条已经进提醒事项了"
            }
        case "create_list":
            switch log.executionStatus {
            case "pending":
                return "我在帮你建新清单"
            case "failed":
                return log.errorMessage.nonEmpty ?? "新列表暂时还没创建成功"
            default:
                return "新清单已经可以用了"
            }
        case "summarize_lists":
            return "我把你现在的提醒事项看了一遍"
        case "capture_message":
            return "我先替你记住了这句话"
        case "move_reminder":
            switch log.executionStatus {
            case "pending":
                return "我在帮你挪到目标清单"
            case "failed":
                return log.errorMessage.nonEmpty ?? "任务暂时还没移动成功"
            default:
                return "这条已经挪过去了"
            }
        case "complete_reminder":
            switch log.executionStatus {
            case "pending":
                return "我在帮你标记完成"
            case "failed":
                return log.errorMessage.nonEmpty ?? "任务暂时还没完成成功"
            default:
                return "这条已经标记完成了"
            }
        default:
            return "这次我已经处理好了"
        }
    }

    private var iconName: String {
        switch log.actionType {
        case "create_reminder":
            return "checklist.checked"
        case "create_list":
            return "folder.badge.plus"
        case "summarize_lists":
            return "text.alignleft"
        case "capture_message":
            return "tray.and.arrow.down"
        case "move_reminder":
            return "arrow.right.circle"
        case "complete_reminder":
            return "checkmark.circle"
        default:
            return "checkmark.circle.fill"
        }
    }

    private var cardAccent: Color {
        switch log.actionType {
        case "create_reminder":
            return .blue
        case "create_list":
            return .blue
        case "summarize_lists":
            return .teal
        case "capture_message":
            return .orange
        case "move_reminder":
            return .indigo
        case "complete_reminder":
            return .green
        default:
            return .green
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        let style = statusStyle
        Text(style.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(style.background)
            )
    }

    private var payloadLines: [String] {
        guard let payload = parsePayloadEnvelope() else { return [] }

        var lines: [String] = []

        switch log.actionType {
        case "create_reminder":
            if let title = payload.action.entities["title"]?.nonEmpty {
                lines.append("任务：\(title)")
            }
            if let dueDate = payload.action.entities["due_date"]?.nonEmpty {
                lines.append("时间：\(formattedDueDate(from: dueDate) ?? dueDate)")
            }
            if let listName = payload.action.entities["preferred_list_name"]?.nonEmpty {
                lines.append("清单：\(listName)")
            }
            if let note = payload.action.entities["note"]?.nonEmpty {
                lines.append("备注：\(note)")
            }
        case "create_list":
            if let name = payload.action.entities["list_name"]?.nonEmpty {
                lines.append("清单：\(name)")
            }
        case "summarize_lists":
            if let topItems = payload.action.entities["top_items"]?.nonEmpty {
                lines.append("先看到的：\(topItems)")
            }
            if let scope = payload.action.entities["scope"]?.nonEmpty {
                lines.append("范围：\(scope)")
            }
        case "capture_message":
            if let text = payload.action.entities["text"]?.nonEmpty {
                lines.append("内容：\(text)")
            }
        case "move_reminder":
            if let target = payload.action.entities["target"]?.nonEmpty {
                lines.append("任务：\(target)")
            }
            if let destination = payload.action.entities["destination_list"]?.nonEmpty {
                lines.append("清单：\(destination)")
            }
        case "complete_reminder":
            if let target = payload.action.entities["target"]?.nonEmpty {
                lines.append("任务：\(target)")
            }
        default:
            break
        }

        if let followUp = payload.followUpPrompt?.nonEmpty {
            lines.append("下一步：\(followUp)")
        }

        return lines
    }

    private func formattedDueDate(from value: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: value) else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天"
        }
        if calendar.isDateInTomorrow(date) {
            return "明天"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        cardAccent.opacity(0.08),
                        Color(.secondarySystemBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var statusStyle: (label: String, foreground: Color, background: Color) {
        switch log.executionStatus {
        case "success":
            return ("已办好", cardAccent, cardAccent.opacity(0.12))
        case "pending":
            return ("在处理", .orange, Color.orange.opacity(0.12))
        case "failed":
            return ("没成", .red, Color.red.opacity(0.12))
        default:
            return ("已接住", .secondary, Color.secondary.opacity(0.12))
        }
    }

    private var primaryActionTitle: String? {
        switch log.actionType {
        case "create_reminder", "create_list", "summarize_lists":
            return "去看清单"
        case "capture_message", "move_reminder", "complete_reminder":
            return "继续编辑"
        default:
            return nil
        }
    }

    private func parsePayloadEnvelope() -> MockAgentEnvelope? {
        guard let data = log.payloadJSON.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(MockAgentEnvelope.self, from: data) else {
            return nil
        }
        return envelope
    }
}

private struct ChatIntroCard: View {
    let isUsingRemoteModel: Bool
    let runtimeNotice: RuntimeNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(
                    isUsingRemoteModel ? "已连接模型" : "未配置模型",
                    systemImage: isUsingRemoteModel ? "bolt.horizontal.circle.fill" : "cpu"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(isUsingRemoteModel ? .green : .orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill((isUsingRemoteModel ? Color.green : Color.orange).opacity(0.12))
                )
            }

            Text("现在可以开始和 AIGTD 对话了。")
                .font(.headline)
            Text("你就像平时一样直接说事情就行。我会尽量先帮你记好、改好、安排好，再补一句必要说明。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let runtimeNotice {
                VStack(alignment: .leading, spacing: 8) {
                    Label(runtimeNotice.text, systemImage: runtimeNotice.tone.iconName)
                        .font(.footnote)
                        .foregroundStyle(runtimeNotice.tone.color)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }
}

private struct StarterPromptsCard: View {
    let onSelect: (String) -> Void

    private let prompts = [
        "明天提醒我给同事回信",
        "帮我建一个“报销”列表",
        "把这条移到“等待中”"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("试试这样说")
                .font(.headline)

            ForEach(prompts, id: \.self) { prompt in
                Button {
                    onSelect(prompt)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.orange)
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.left")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.72))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage
    let actionLog: ActionLog?
    let onPrimaryAction: (ActionLog) -> Void
    @State private var showsCopiedToast = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if isUserMessage {
                Spacer(minLength: 42)
            } else {
                avatar
            }

            VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 6) {
                Text(isUserMessage ? "你" : "AIGTD")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if shouldShowStreamingPlaceholder {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.secondary.opacity(0.66))
                            .frame(width: 6, height: 6)
                        Circle()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Circle()
                            .fill(Color.secondary.opacity(0.34))
                            .frame(width: 6, height: 6)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(isUserMessage ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(bubbleBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .textSelection(.enabled)
                        .contextMenu {
                            Button("复制这条消息") {
                                UIPasteboard.general.string = message.text
                                showsCopiedToast = true
                            }
                        }
                }

                if shouldShowActionSummary,
                   message.actionResultSummary.isEmpty == false {
                    Text(message.actionResultSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let actionLog, shouldShowActionCard(for: actionLog) {
                    ActionResultCardView(
                        log: actionLog,
                        onPrimaryAction: { onPrimaryAction(actionLog) }
                    )
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)

            if isUserMessage {
                avatar
            } else {
                Spacer(minLength: 42)
            }
        }
        .overlay(alignment: .top) {
            if showsCopiedToast {
                Text("已复制")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(1.2))
                        showsCopiedToast = false
                    }
            }
        }
    }

    private var isUserMessage: Bool {
        message.role == "user"
    }

    private var shouldShowActionSummary: Bool {
        guard let actionLog else { return false }
        return shouldShowActionCard(for: actionLog)
    }

    private var shouldShowStreamingPlaceholder: Bool {
        isUserMessage == false &&
        message.status == "streaming" &&
        message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func shouldShowActionCard(for log: ActionLog) -> Bool {
        switch log.actionType {
        case MockAgentIntent.createReminder.rawValue,
             MockAgentIntent.createList.rawValue,
             MockAgentIntent.moveReminder.rawValue,
             MockAgentIntent.completeReminder.rawValue:
            return true
        default:
            return false
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(isUserMessage ? Color.accentColor.opacity(0.18) : Color.orange.opacity(0.18))
            Text(isUserMessage ? "你" : "AI")
                .font(.caption.bold())
                .foregroundStyle(isUserMessage ? Color.accentColor : Color.orange)
        }
        .frame(width: 32, height: 32)
    }

    private var bubbleBackground: some View {
        Group {
            if isUserMessage {
                LinearGradient(
                    colors: [
                        Color.accentColor,
                        Color.accentColor.opacity(0.78)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.95),
                        Color(red: 0.97, green: 0.98, blue: 0.99)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}

private struct ChatComposer: View {
    @Binding var draft: String
    let isSending: Bool
    let isStreamingReply: Bool
    let isVoicePrimed: Bool
    let isRecordingVoice: Bool
    let isTranscribingVoice: Bool
    let isFinalizingVoice: Bool
    let tailHighlightLength: Int
    let tailAnimatedDotsCount: Int
    @Binding var focusRequestID: UUID
    @Binding var isFocused: Bool
    @ObservedObject var focusBridge: ComposerTextViewFocusBridge
    let onToggleVoice: () -> Void
    let onSend: () -> Void
    let onVoiceInputTakeoverByKeyboard: () -> Void
    @State private var composerHeight: CGFloat = 44
    private let composerHorizontalPadding: CGFloat = 12
    private let composerVerticalPadding: CGFloat = 0
    private let textContainerInset = UIEdgeInsets(top: 13, left: 14, bottom: 13, right: 14)

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(composerFieldBackground)

                GrowingComposerTextView(
                    text: $draft,
                    focusRequestID: $focusRequestID,
                    isFocused: $isFocused,
                    focusBridge: focusBridge,
                    measuredHeight: $composerHeight,
                    tailHighlightLength: tailHighlightLength,
                    tailAnimatedDotsCount: tailAnimatedDotsCount,
                    textContainerInset: textContainerInset,
                    shouldHideCaret: isVoicePrimed || isRecordingVoice || isTranscribingVoice,
                    // Keep keyboard alive during voice input. Making UITextView non-editable
                    // causes iOS to resign first responder and collapse the keyboard.
                    isEditable: true,
                    onSubmit: onSend,
                    isVoiceInputActive: isVoicePrimed || isRecordingVoice || isTranscribingVoice,
                    onVoiceInputTakeoverByKeyboard: onVoiceInputTakeoverByKeyboard
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, composerHorizontalPadding)
                .padding(.vertical, composerVerticalPadding)

                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(placeholderText)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, composerHorizontalPadding + textContainerInset.left)
                        .padding(.top, composerVerticalPadding + textContainerInset.top)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: max(44, composerHeight))
            .animation(
                shouldAnimateComposerHeight ? .easeOut(duration: 0.14) : nil,
                value: composerHeight
            )
            .contentShape(Rectangle())

            VoiceToggleButton(
                isVoicePrimed: isVoicePrimed,
                isRecordingVoice: isRecordingVoice,
                isTranscribingVoice: isTranscribingVoice,
                isFinalizingVoice: isFinalizingVoice,
                isDisabled: isSending || isFinalizingVoice,
                onTap: onToggleVoice
            )
            .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private var placeholderText: String {
        if isVoicePrimed {
            return "请说话…"
        }
        if isRecordingVoice {
            return "请说话…"
        }
        if isTranscribingVoice {
            return "正在识别…"
        }
        if isFinalizingVoice {
            return "正在整理这句话…"
        }
        return "直接告诉我你要做什么"
    }

    private var composerFieldBackground: Color {
        if isFinalizingVoice {
            return Color.blue.opacity(0.12)
        }
        return Color.white.opacity(0.94)
    }

    private var shouldAnimateComposerHeight: Bool {
        !(isVoicePrimed || isRecordingVoice || isTranscribingVoice || isFinalizingVoice)
    }
}

private struct GrowingComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focusRequestID: UUID
    @Binding var isFocused: Bool
    @ObservedObject var focusBridge: ComposerTextViewFocusBridge
    @Binding var measuredHeight: CGFloat
    let tailHighlightLength: Int
    let tailAnimatedDotsCount: Int
    let textContainerInset: UIEdgeInsets
    let shouldHideCaret: Bool
    let isEditable: Bool
    let onSubmit: () -> Void
    let isVoiceInputActive: Bool
    let onVoiceInputTakeoverByKeyboard: () -> Void

    private var minHeight: CGFloat {
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        return max(44, ceil(lineHeight + textContainerInset.top + textContainerInset.bottom))
    }

    private var maxHeight: CGFloat {
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        return ceil(lineHeight * 5 + textContainerInset.top + textContainerInset.bottom)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            measuredHeight: $measuredHeight,
            isFocused: $isFocused,
            minHeight: minHeight,
            maxHeight: maxHeight,
            onSubmit: onSubmit,
            onVoiceInputTakeoverByKeyboard: onVoiceInputTakeoverByKeyboard
        )
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = UIColor.label
        textView.tintColor = UIColor.systemBlue
        textView.returnKeyType = .send
        textView.textContainerInset = textContainerInset
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.textContainer.widthTracksTextView = true
        textView.contentInset = .zero
        textView.contentOffset = .zero
        textView.contentInsetAdjustmentBehavior = .never
        textView.scrollIndicatorInsets = .zero
        textView.allowsEditingTextAttributes = false
        textView.showsVerticalScrollIndicator = false
        textView.alwaysBounceVertical = false
        textView.isScrollEnabled = false
        textView.keyboardDismissMode = .interactive
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        focusBridge.textView = textView
        context.coordinator.recalculateHeight(for: textView, immediate: true)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        focusBridge.textView = uiView
        let didUpdateText = context.coordinator.applyDisplayedText(
            to: uiView,
            text: text,
            tailHighlightLength: tailHighlightLength,
            tailAnimatedDotsCount: tailAnimatedDotsCount,
            shouldHideCaret: shouldHideCaret
        )
        if uiView.textContainerInset != textContainerInset {
            uiView.textContainerInset = textContainerInset
        }
        let didBoundsChange = context.coordinator.noteBoundsChange(for: uiView)
        uiView.tintColor = UIColor.systemBlue
        if uiView.isEditable != isEditable {
            uiView.isEditable = isEditable
        }
        if uiView.isSelectable == false {
            uiView.isSelectable = true
        }
        context.coordinator.isVoiceInputActive = isVoiceInputActive

        if didUpdateText || didBoundsChange {
            context.coordinator.recalculateHeight(for: uiView, immediate: true)
            context.coordinator.scrollToBottomIfNeeded(for: uiView)
            DispatchQueue.main.async { [weak uiView, weak coordinator = context.coordinator] in
                guard let uiView, let coordinator else { return }
                coordinator.recalculateHeight(for: uiView, immediate: true)
                coordinator.scrollToBottomIfNeeded(for: uiView)
            }
        }
        context.coordinator.applyFocusIfNeeded(for: uiView, requestID: focusRequestID)

        if isFocused, uiView.window != nil, uiView.isFirstResponder == false {
            uiView.becomeFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var measuredHeight: CGFloat
        @Binding private var isFocused: Bool
        private let minHeight: CGFloat
        private let maxHeight: CGFloat
        private let onSubmit: () -> Void
        private let onVoiceInputTakeoverByKeyboard: () -> Void
        var isVoiceInputActive = false
        private var lastFocusRequestID = UUID()
        private var lastRenderedDisplayText = ""
        private var isApplyingDisplayUpdate = false
        private var cachedShouldScroll = false
        private var lastKnownWidth: CGFloat = 0
        private var hasPendingVoiceTakeoverDotCleanup = false

        init(
            text: Binding<String>,
            measuredHeight: Binding<CGFloat>,
            isFocused: Binding<Bool>,
            minHeight: CGFloat,
            maxHeight: CGFloat,
            onSubmit: @escaping () -> Void,
            onVoiceInputTakeoverByKeyboard: @escaping () -> Void
        ) {
            _text = text
            _measuredHeight = measuredHeight
            _isFocused = isFocused
            self.minHeight = minHeight
            self.maxHeight = maxHeight
            self.onSubmit = onSubmit
            self.onVoiceInputTakeoverByKeyboard = onVoiceInputTakeoverByKeyboard
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isFocused = false
        }

        func textViewDidChange(_ textView: UITextView) {
            if isApplyingDisplayUpdate {
                recalculateHeight(for: textView, immediate: true)
                scrollToBottomIfNeeded(for: textView)
                return
            }
            let rawText = textView.text ?? ""
            var committedText = rawText
            let hasMarkedText = textView.markedTextRange != nil
            if isVoiceInputActive {
                onVoiceInputTakeoverByKeyboard()
                isVoiceInputActive = false
                hasPendingVoiceTakeoverDotCleanup = true
            }
            if hasPendingVoiceTakeoverDotCleanup, hasMarkedText == false {
                committedText = removingVoiceIndicatorDots(from: rawText)
                hasPendingVoiceTakeoverDotCleanup = false
                if committedText != rawText {
                    let selection = textView.selectedRange
                    textView.text = committedText
                    let location = min(selection.location, committedText.count)
                    textView.selectedRange = NSRange(location: location, length: 0)
                }
            }
            _ = noteBoundsChange(for: textView)
            text = committedText
            lastRenderedDisplayText = committedText
            recalculateHeight(for: textView, immediate: true)
            scrollToBottomIfNeeded(for: textView)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            if replacement == "\n" {
                onSubmit()
                return false
            }
            // Keep IME composition stable (especially Chinese pinyin) by deferring
            // voice->keyboard takeover to `textViewDidChange`, after UIKit applies
            // the first input event.
            return true
        }

        @discardableResult
        func applyDisplayedText(
            to textView: UITextView,
            text: String,
            tailHighlightLength: Int,
            tailAnimatedDotsCount: Int,
            shouldHideCaret _: Bool
        ) -> Bool {
            if textView.markedTextRange != nil {
                lastRenderedDisplayText = textView.text ?? lastRenderedDisplayText
                return false
            }
            _ = max(0, min(tailHighlightLength, text.count))
            let clampedDots = max(0, min(3, tailAnimatedDotsCount))
            let shouldShowDots = clampedDots > 0 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let dotsSuffix = shouldShowDots ? String(repeating: ".", count: clampedDots) : ""
            let displayText = text + dotsSuffix

            if lastRenderedDisplayText == displayText {
                return false
            }

            let selection = textView.selectedRange
            isApplyingDisplayUpdate = true
            defer { isApplyingDisplayUpdate = false }

            textView.text = displayText
            textView.layoutManager.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: textView.textStorage.length),
                actualCharacterRange: nil
            )
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            textView.invalidateIntrinsicContentSize()
            textView.setNeedsLayout()
            textView.layoutIfNeeded()

            if shouldShowDots {
                textView.selectedRange = NSRange(location: text.count, length: 0)
            } else if textView.isFirstResponder {
                let location = min(selection.location, text.count)
                let length = min(selection.length, max(0, text.count - location))
                textView.selectedRange = NSRange(location: location, length: length)
            } else if selection.length > 0 {
                textView.selectedRange = NSRange(location: text.count, length: 0)
            }

            lastRenderedDisplayText = displayText
            return true
        }

        @discardableResult
        func noteBoundsChange(for textView: UITextView) -> Bool {
            let width = textView.bounds.width
            guard width > 1 else { return false }
            if abs(lastKnownWidth - width) <= 0.5 {
                return false
            }
            lastKnownWidth = width
            return true
        }

        func recalculateHeight(for textView: UITextView, immediate: Bool = false) {
            _ = noteBoundsChange(for: textView)
            let targetWidth = max(textView.bounds.width, lastKnownWidth)
            guard targetWidth > 1 else {
                DispatchQueue.main.async { [weak textView] in
                    guard let textView else { return }
                    self.recalculateHeight(for: textView, immediate: immediate)
                }
                return
            }

            syncTextContainerWidth(for: textView)
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            let usedRect = textView.layoutManager.usedRect(for: textView.textContainer)
            let rawHeight = ceil(usedRect.height + textView.textContainerInset.top + textView.textContainerInset.bottom)
            let clamped = min(max(minHeight, rawHeight), maxHeight)

            if abs(measuredHeight - clamped) > 0.5 {
                let applyHeight = { self.measuredHeight = clamped }
                if immediate {
                    applyHeight()
                } else {
                    DispatchQueue.main.async {
                        applyHeight()
                    }
                }
            }

            let shouldScroll = rawHeight > maxHeight + 0.5
            if textView.isScrollEnabled != shouldScroll {
                textView.isScrollEnabled = shouldScroll
            }
            cachedShouldScroll = shouldScroll

            if shouldScroll {
                scrollToBottomAligned(for: textView)
            } else if textView.contentOffset.y != 0 {
                textView.setContentOffset(.zero, animated: false)
            }
        }

        func scrollToBottomIfNeeded(for textView: UITextView) {
            guard cachedShouldScroll || textView.isScrollEnabled else { return }
            scrollToBottomAligned(for: textView)
        }

        func applyFocusIfNeeded(for textView: UITextView, requestID: UUID) {
            guard requestID != lastFocusRequestID else { return }
            lastFocusRequestID = requestID
            guard textView.window != nil else { return }
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
            }
        }

        private func scrollToBottomAligned(for textView: UITextView) {
            let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
            let scale = UIScreen.main.scale
            let alignedOffset = ceil(maxOffset * scale) / scale
            if abs(textView.contentOffset.y - alignedOffset) > 0.5 {
                textView.setContentOffset(CGPoint(x: 0, y: alignedOffset), animated: false)
            }
        }

        private func syncTextContainerWidth(for textView: UITextView) {
            let horizontalInsets =
                textView.textContainerInset.left +
                textView.textContainerInset.right +
                textView.textContainer.lineFragmentPadding * 2
            let targetContainerWidth = max(1, textView.bounds.width - horizontalInsets)
            let currentSize = textView.textContainer.size
            if abs(currentSize.width - targetContainerWidth) <= 0.5,
               currentSize.height == .greatestFiniteMagnitude {
                return
            }
            textView.textContainer.size = CGSize(
                width: targetContainerWidth,
                height: .greatestFiniteMagnitude
            )
        }

        private func removingVoiceIndicatorDots(from value: String) -> String {
            if value.hasSuffix("...") {
                return String(value.dropLast(3))
            }
            if value.hasSuffix("..") {
                return String(value.dropLast(2))
            }
            if value.hasSuffix(".") {
                return String(value.dropLast())
            }
            if let strayDotsRange = value.range(
                of: #"\.{2,3}(?=[^\s]{1,8}$)"#,
                options: .regularExpression
            ) {
                return value.replacingCharacters(in: strayDotsRange, with: "")
            }
            return value
        }
    }
}

private struct VoiceToggleButton: View {
    let isVoicePrimed: Bool
    let isRecordingVoice: Bool
    let isTranscribingVoice: Bool
    let isFinalizingVoice: Bool
    let isDisabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(backgroundColor)

                if isVoicePrimed || isRecordingVoice || isTranscribingVoice || isFinalizingVoice {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }

    private var backgroundColor: Color {
        if isFinalizingVoice {
            return Color.orange.opacity(0.92)
        }
        if isVoicePrimed || isRecordingVoice || isTranscribingVoice {
            return Color.blue.opacity(0.92)
        }
        return Color.orange.opacity(0.92)
    }
}

@MainActor
private final class ComposerTextViewFocusBridge: ObservableObject {
    weak var textView: UITextView?

    func focus() {
        textView?.becomeFirstResponder()
    }

    func blur() {
        textView?.resignFirstResponder()
    }
}


private struct RuntimeNotice {
    let text: String
    let tone: RuntimeNoticeTone
}

private enum RuntimeNoticeTone {
    case info
    case success
    case warning

    var color: Color {
        switch self {
        case .info:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        }
    }

    var iconName: String {
        switch self {
        case .info:
            return "info.circle"
        case .success:
            return "checkmark.seal"
        case .warning:
            return "exclamationmark.triangle"
        }
    }
}

private extension String {
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
