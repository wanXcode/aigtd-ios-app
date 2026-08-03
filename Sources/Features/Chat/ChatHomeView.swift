import SwiftData
import SwiftUI
import AVFoundation
import UIKit

struct ReminderAdjustmentSelection: Equatable, Sendable {
    let reminderID: String
    let reminderTitle: String
}

private enum ChatComposerInputMode: Equatable {
    case text
    case voice
}

enum ReminderAdjustmentDraftPolicy {
    static func retainedSelection(
        _ selection: ReminderAdjustmentSelection?,
        in draft: String
    ) -> ReminderAdjustmentSelection? {
        guard let selection,
              referencesReminder(named: selection.reminderTitle, in: draft) else {
            return nil
        }
        return selection
    }

    static func referencesReminder(named title: String, in draft: String) -> Bool {
        let normalizedTitle = normalized(title)
        let normalizedDraft = normalized(draft)
        guard normalizedTitle.isEmpty == false, normalizedDraft.isEmpty == false else {
            return false
        }
        return normalizedDraft.contains(normalizedTitle)
    }

    private static func normalized(_ value: String) -> String {
        let ignored = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
        return value
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { ignored.contains($0) == false }
            .map(String.init)
            .joined()
    }
}

struct ChatHomeView: View {
    private static let bottomAnchorID = "chat-bottom-anchor"
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel
    @Environment(XiaomanWelcomeStore.self) private var welcomeStore
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]
    @Query(sort: \ChatMessage.createdAt) private var messages: [ChatMessage]
    @Query(sort: \ActionLog.createdAt) private var actionLogs: [ActionLog]
    @Query(sort: \ModelProfile.displayName) private var modelProfiles: [ModelProfile]
    @Query(sort: \AgentDocument.updatedAt, order: .forward) private var agentDocuments: [AgentDocument]
    @Query private var preferences: [UserPreference]
    @Query private var executionPolicies: [ExecutionPolicy]
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
    @State private var composerInputMode: ChatComposerInputMode = .text
    @State private var hasPositionedInitialTimeline = false
    @State private var executingActionIDs: Set<UUID> = []
    @State private var timelineIsNearBottom = true
    @State private var timelineIsUserInteracting = false
    @State private var viewportController = ChatViewportController()
    @State private var streamingTextBuffer = ChatStreamingTextBuffer()
    @State private var pendingReminderAdjustmentSelection: ReminderAdjustmentSelection?
    @StateObject private var voiceInteraction = VoiceInteractionState()
    private let agentRuntime = AgentRuntimeService()
    private let conversationCoordinator = AgentConversationCoordinator()
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
                                streamingText: streamingTextBuffer.text(for: message.id),
                                actionLog: latestActionLogByMessageID[message.id],
                                onPrimaryAction: handleCardPrimaryAction,
                                onAdjustAction: handleCardAdjustAction,
                                onCancelAction: handleCardCancelAction
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
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                return geometry.contentSize.height - visibleBottom <= 72
            } action: { _, isNearBottom in
                timelineIsNearBottom = isNearBottom
                viewportController.viewportDidChange(
                    isNearBottom: isNearBottom,
                    isUserInteracting: timelineIsUserInteracting
                )
            }
            .onScrollPhaseChange { _, newPhase in
                let wasUserInteracting = timelineIsUserInteracting
                let isUserInteracting = newPhase != .idle && newPhase != .animating
                timelineIsUserInteracting = isUserInteracting
                if isUserInteracting {
                    viewportController.viewportDidChange(
                        isNearBottom: timelineIsNearBottom,
                        isUserInteracting: true
                    )
                } else if newPhase == .idle, wasUserInteracting {
                    viewportController.userInteractionDidEnd(
                        isNearBottom: timelineIsNearBottom
                    )
                }
            }
            .onAppear {
                reconcileInterruptedStructuredLogs()
                viewportController.chatBecameVisible()
            }
            .onChange(of: activeMessages.count) { _, _ in
                viewportController.contentDidChange(.messageInserted)
            }
            .onChange(of: isComposerFocused) { _, focused in
                guard focused else { return }
                viewportController.composerFocused()
            }
            .onChange(of: appModel.selectedTab) { _, newValue in
                guard newValue == .chat else { return }
                viewportController.chatBecameVisible()
            }
            .onChange(of: streamingTextBuffer.revision) { _, _ in
                viewportController.contentDidChange(.streamingText)
            }
            .onChange(of: activeCardScrollSignature) { _, _ in
                viewportController.contentDidChange(.cardState)
            }
            .onChange(of: viewportController.scrollRequest.sequence) { _, _ in
                performScrollRequest(
                    viewportController.scrollRequest,
                    using: proxy
                )
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatComposer(
                    draft: $draft,
                    isSending: isSending,
                    isStreamingReply: isStreamingReply,
                    voiceState: voiceInteraction,
                    voiceConfiguration: activeVoiceConfiguration,
                    inputMode: $composerInputMode,
                    focusRequestID: $composerFocusRequestID,
                    isFocused: $isComposerFocused,
                    focusBridge: composerFocusBridge,
                    onSend: {
                        Task {
                            await sendDraft()
                        }
                    },
                    onVoiceUnavailable: {
                        runtimeNotice = RuntimeNotice(
                            text: "语音输入暂时不可用，请稍后再试。",
                            tone: .warning
                        )
                    }
                )
                .overlay(alignment: .topTrailing) {
                    if viewportController.showsReturnToLatest {
                        Button {
                            viewportController.returnToLatest()
                        } label: {
                            Label("回到最新", systemImage: "arrow.down")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16)
                        .offset(y: -42)
                        .accessibilityHint("滚动到最新一条消息")
                    }
                }
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
                    let explicitSelection = takeReminderAdjustmentSelection(
                        forSending: prompt.pendingDraft
                    )
                    Task {
                        await sendWithoutPrompt(
                            prompt.pendingDraft,
                            clearDraft: true,
                            explicitReminderSelection: explicitSelection
                        )
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
            insertWelcomeMessageIfNeeded()
            restorePendingDraftIfNeeded()
        }
        .task(id: initialTimelineSignature) {
            guard hasPositionedInitialTimeline == false,
                  activeSession != nil else { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(100))
            guard Task.isCancelled == false else { return }
            viewportController.positionInitialTimelineAtLatest()
            hasPositionedInitialTimeline = true
        }
        .onChange(of: appModel.selectedTab) { _, newValue in
            guard newValue == .chat else { return }
            restorePendingDraftIfNeeded()
        }
        .onChange(of: draft) { _, newValue in
            pendingReminderAdjustmentSelection = ReminderAdjustmentDraftPolicy.retainedSelection(
                pendingReminderAdjustmentSelection,
                in: newValue
            )
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
        .onChange(of: voiceInteraction.phase) { _, phase in
            if phase == .draftReady, let preparedDraft = voiceInteraction.takePreparedDraft() {
                draft = preparedDraft
                composerInputMode = .text
                isComposerFocused = true
                composerFocusRequestID = UUID()
                Task { @MainActor in
                    await Task.yield()
                    composerFocusBridge.focus()
                }
            } else if phase == .failed, let notice = voiceInteraction.noticeText {
                runtimeNotice = RuntimeNotice(text: notice, tone: .warning)
            } else if phase == .requestingPermission || phase == .starting || phase == .recording {
                isComposerFocused = false
                composerFocusBridge.blur()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                voiceInteraction.handleInterruption()
            }
        }
        .onChange(of: appModel.selectedTab) { _, tab in
            if tab != .chat {
                voiceInteraction.handleInterruption()
            }
        }
        .overlay(alignment: .bottom) {
            if voiceInteraction.showsCaptureOverlay {
                VoiceCaptureOverlay(
                    state: voiceInteraction,
                    onFinish: {
                        Task { await voiceInteraction.releaseCapture() }
                    },
                    onCancel: {
                        voiceInteraction.cancelCapture()
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 76)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.2), value: voiceInteraction.showsCaptureOverlay)
    }

    private var activeSession: ChatSession? {
        sessions.first
    }

    private var activeMessages: [ChatMessage] {
        guard let activeSession else { return [] }
        return messages.filter { $0.sessionID == activeSession.id }
    }

    private var initialTimelineSignature: String {
        let sessionID = activeSession?.id.uuidString ?? "no-session"
        let lastMessageID = activeMessages.last?.id.uuidString ?? "no-message"
        return "\(sessionID):\(lastMessageID):\(activeMessages.count)"
    }

    private var recentConversationHistory: [AgentConversationTurn] {
        Array(
            activeMessages
                .filter { message in
                    message.status != "streaming" &&
                    message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                }
                .suffix(8)
                .map { message in
                    AgentConversationTurn(
                        role: message.role,
                        text: message.text
                    )
                }
        )
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

    private var activeCardScrollSignature: String {
        guard let activeSession else { return "" }
        return actionLogs
            .filter { $0.sessionID == activeSession.id }
            .suffix(4)
            .map { "\($0.id.uuidString)-\($0.executionStatus)-\($0.errorMessage.count)" }
            .joined(separator: "|")
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

    private func insertWelcomeMessageIfNeeded() {
        guard let message = welcomeStore.pendingWelcomeMessage() else { return }
        let session: ChatSession
        var descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        if let fetched = try? modelContext.fetch(descriptor), let existing = fetched.first {
            session = existing
        } else {
            let created = ChatSession(title: "主会话")
            modelContext.insert(created)
            session = created
        }
        let welcomeMessage = ChatMessage(
            sessionID: session.id,
            role: "assistant",
            text: message
        )
        modelContext.insert(welcomeMessage)
        session.updatedAt = .now
        session.lastMessagePreview = message
        do {
            try modelContext.save()
            welcomeStore.markWelcomePresented()
        } catch {
            modelContext.rollback()
        }
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

        let explicitSelection = takeReminderAdjustmentSelection(forSending: content)
        await sendWithoutPrompt(
            content,
            clearDraft: true,
            explicitReminderSelection: explicitSelection
        )
    }

    private func sendPrompt(
        _ content: String,
        explicitReminderSelection: ReminderAdjustmentSelection? = nil
    ) async {
        let minimumPendingDisplayDuration = Duration.milliseconds(650)
        let traceID = UUID()
        let refreshesContext = shouldRefreshContext(for: content)
        if refreshesContext {
            await appModel.refreshReminderLists()
        }
        let contextRefreshError = refreshesContext ? appModel.reminderListsErrorMessage : ""
        AgentTraceService.shared.record(
            traceID: traceID,
            stage: .contextRefresh,
            status: refreshesContext
                ? (contextRefreshError.isEmpty ? .success : .failure)
                : .skipped,
            errorCategory: contextRefreshError.isEmpty ? nil : "reminders_refresh",
            userVisibleError: contextRefreshError.nonEmpty
        )
        let conversationHistory = recentConversationHistory
        let session: ChatSession
        if let existing = activeSession {
            session = existing
        } else {
            let created = ChatSession(title: "主会话")
            modelContext.insert(created)
            session = created
        }

        if await handleUndoCommand(content, session: session) {
            return
        }
        if await handlePendingInteractionCommand(content, session: session) {
            return
        }
        let pendingRevision = activePendingPresentation(for: session.id)?.confirmationPayload

        let userMessage = ChatMessage(
            sessionID: session.id,
            role: "user",
            text: content
        )
        modelContext.insert(userMessage)
        if let explicitReminderSelection {
            recordExplicitReminderSelection(
                explicitReminderSelection,
                sessionID: session.id,
                sourceMessageID: userMessage.id
            )
        }

        let assistantMessage = ChatMessage(
            sessionID: session.id,
            role: "assistant",
            text: "",
            actionResultSummary: "",
            status: "streaming"
        )
        modelContext.insert(assistantMessage)
        try? modelContext.save()

        let memoryDecision = AgentMemoryPolicy().evaluate(
            message: content,
            sourceMessageID: userMessage.id
        )
        let savedMemoryDescription: String?
        let pendingMemoryConfirmationDescription: String?
        let rejectedMemoryReply: String?
        if case let .candidate(candidate) = memoryDecision {
            if isExplicitMemorySaveCommand(content) {
                AgentUserMemoryStore.shared.upsert(
                    category: candidate.category,
                    value: candidate.value,
                    sourceMessageID: nil
                )
                savedMemoryDescription = candidate.readableDescription
                pendingMemoryConfirmationDescription = nil
            } else {
                savedMemoryDescription = nil
                pendingMemoryConfirmationDescription = candidate.readableDescription
            }
            rejectedMemoryReply = nil
        } else if case let .rejected(reason) = memoryDecision {
            savedMemoryDescription = nil
            pendingMemoryConfirmationDescription = nil
            rejectedMemoryReply = reason.userFacingReply
        } else {
            savedMemoryDescription = nil
            pendingMemoryConfirmationDescription = nil
            rejectedMemoryReply = nil
        }

        let runtimeContext = AIGTDAgentDocumentStore.runtimeContext(from: agentDocuments)
        let contextSnapshot = makeContextSnapshot(
            session: session,
            conversationHistory: conversationHistory,
            documents: runtimeContext
        )
        AgentTraceService.shared.record(
            traceID: traceID,
            stage: .contextBuild,
            status: .success,
            summaryText: "context snapshot",
            structure: [
                "schema:\(contextSnapshot.schemaVersion)",
                "turns:\(contextSnapshot.recentTurns.count)",
                "reminders:\(contextSnapshot.reminders.count)",
                "references:\(contextSnapshot.references.allReferences.count)",
                "preferences:\(contextSnapshot.preferences.count)",
                "stale:\(contextSnapshot.privacy.reminderSnapshotIsStale)"
            ]
        )
        var createdLogID: UUID?

        if rejectedMemoryReply == nil,
           savedMemoryDescription == nil,
           pendingMemoryConfirmationDescription == nil,
           let configuration = activeModelConfiguration {
            let presentation = await conversationCoordinator.run(
                userInput: content,
                configuration: configuration,
                contextSnapshot: contextSnapshot,
                sessionID: session.id,
                policySettings: executionPolicies.first.map { AgentExecutionPolicySettings(policy: $0) } ?? .init(),
                longTermRules: AgentExecutionPolicyLongTermRules(
                    memoryItems: AgentUserMemoryStore.shared.items()
                ),
                revisionOf: pendingRevision
            )
            if presentation.allowsLegacyFallback == false {
                await finalizeStructuredPresentation(
                    presentation,
                    assistantMessage: assistantMessage,
                    session: session,
                    userContent: content
                )
                return
            }
            runtimeNotice = RuntimeNotice(
                text: "结构化模型暂时不可用，这次已安全回退到单动作兼容模式。",
                tone: .warning
            )
        }

        let localReadResult = MockAgentService().respond(
            to: content,
            reminderLists: appModel.reminderLists,
            reminderItems: appModel.reminderItems,
            agentContext: runtimeContext,
            contextSnapshot: contextSnapshot
        )
        let result: MockAgentResult
        let localReadEnvelope = decodePayload(from: localReadResult.payloadJSON)
        if let rejectedMemoryReply,
           localReadResult.actionType == nil || localReadResult.actionType == MockAgentIntent.captureMessage.rawValue {
            AgentTraceService.shared.record(
                traceID: traceID,
                stage: .remoteRequestStarted,
                status: .skipped,
                structure: ["local_memory_policy_rejection"]
            )
            result = MockAgentResult(
                reply: rejectedMemoryReply,
                summary: "长期记忆写入已拒绝",
                actionType: nil,
                payloadJSON: "{}",
                confidence: 1,
                followUpPrompt: nil
            )
        } else if AgentResultArbitration.shouldBypassRemote(
            localActionType: localReadResult.actionType,
            hasExplicitOrdinal: localReadEnvelope?.action.entities["ordinal"]?.nonEmpty != nil
        ) {
            AgentTraceService.shared.record(
                traceID: traceID,
                stage: .remoteRequestStarted,
                status: .skipped,
                actionType: localReadResult.actionType,
                structure: ["authoritative_local_read"]
            )
            result = localReadResult
        } else {
            result = await agentRuntime.respond(
                to: content,
                reminderLists: appModel.reminderLists,
                reminderItems: appModel.reminderItems,
                configuration: activeModelConfiguration,
                agentContext: runtimeContext,
                conversationHistory: conversationHistory,
                contextSnapshot: contextSnapshot,
                traceID: traceID,
                onTextUpdate: { partialText in
                    if partialText.isEmpty == false {
                        isStreamingReply = true
                    }
                    streamingTextBuffer.enqueue(partialText, for: assistantMessage.id)
                }
            )
        }
        let normalizedRemoteResult = normalizeStructuredResult(result)
        let executionResult = resolveExecutionResult(
            userContent: content,
            remoteResult: normalizedRemoteResult,
            runtimeContext: runtimeContext,
            contextSnapshot: contextSnapshot
        )
        let displayResult = resolveDisplayResult(
            remoteResult: normalizedRemoteResult,
            executionResult: executionResult
        )
        let startsPending = [
            MockAgentIntent.createList.rawValue,
            MockAgentIntent.createReminder.rawValue,
            MockAgentIntent.updateReminder.rawValue,
            MockAgentIntent.moveReminder.rawValue,
            MockAgentIntent.completeReminder.rawValue,
            MockAgentIntent.deleteReminder.rawValue
        ].contains(executionResult.actionType ?? "")
        let awaitsConfirmation = startsPending && actionRequiresConfirmation(executionResult)
        updateRuntimeNotice(
            remoteResult: normalizedRemoteResult,
            executionResult: executionResult
        )
        let finalAssistantText = startsPending
            ? (awaitsConfirmation ? confirmationAssistantReply(for: executionResult) : pendingAssistantReply(for: executionResult))
            : savedMemoryDescription.map { "我记住了：\($0)。" }
                ?? pendingMemoryConfirmationDescription.map {
                    "我理解这是长期偏好：\($0)。为了避免误记，请用“记住：你的规则”再确认一次。"
                }
                ?? rejectedMemoryReply
                ?? displayResult.reply
        assistantMessage.text = finalAssistantText
        assistantMessage.actionResultSummary = executionResult.actionType == nil ? "" : executionResult.summary
        assistantMessage.status = "sent"
        streamingTextBuffer.removeText(for: assistantMessage.id)
        isStreamingReply = false
        if let actionType = executionResult.actionType {
            AgentTraceService.shared.record(
                traceID: traceID,
                stage: .fallbackResolutionCompleted,
                status: .success,
                actionType: actionType
            )
            let log = ActionLog(
                sessionID: session.id,
                messageID: assistantMessage.id,
                actionType: actionType,
                payloadJSON: executionResult.payloadJSON,
                executionStatus: awaitsConfirmation ? "awaiting_confirmation" : (startsPending ? "pending" : "success"),
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

        if startsPending && !awaitsConfirmation {
            AgentTraceService.shared.record(
                traceID: traceID,
                stage: .actionExecutionStarted,
                status: .success,
                actionType: executionResult.actionType
            )
            await Task.yield()
            try? await Task.sleep(for: minimumPendingDisplayDuration)
        }

        if let createdLogID, startsPending && !awaitsConfirmation {
            await Task.yield()
            if let outcome = await executeResultAction(logID: createdLogID, result: executionResult) {
                assistantMessage.text = outcome.reply
                assistantMessage.actionResultSummary = outcome.summary
                try? modelContext.save()
            }

            if let completedLog = actionLogs.first(where: { $0.id == createdLogID }) {
                let traceStatus: AgentTraceStageStatus = switch completedLog.executionStatus {
                case "success": .success
                case "needs_clarification": .skipped
                default: .failure
                }
                AgentTraceService.shared.record(
                    traceID: traceID,
                    stage: .actionExecutionCompleted,
                    status: traceStatus,
                    actionType: completedLog.actionType,
                    errorCategory: completedLog.errorMessage.isEmpty ? nil : "action_execution",
                    userVisibleError: completedLog.errorMessage.nonEmpty
                )
                AgentTraceService.shared.record(
                    traceID: traceID,
                    stage: .remindersRefreshCompleted,
                    status: appModel.reminderListsErrorMessage.isEmpty ? .success : .failure,
                    errorCategory: appModel.reminderListsErrorMessage.isEmpty ? nil : "refresh",
                    userVisibleError: appModel.reminderListsErrorMessage.nonEmpty
                )
            }
        }

        if let createdLogID,
           let completedLog = actionLogs.first(where: { $0.id == createdLogID }),
           completedLog.executionStatus == "success",
           recordReferenceOutcome(
               for: completedLog,
               shownReminderIDs: contextSnapshot.reminders.map(\.id)
           ) {
            AgentTraceService.shared.record(
                traceID: traceID,
                stage: .referenceResolution,
                status: .success,
                actionType: completedLog.actionType,
                structure: ["stable_reminder_id_recorded"]
            )
        }

        if updateSessionSummary(for: session.id) {
            AgentTraceService.shared.record(
                traceID: traceID,
                stage: .sessionSummaryUpdate,
                status: .success,
                structure: ["deterministic_local_summary"]
            )
        }


        AgentTraceService.shared.record(
            traceID: traceID,
            stage: .replyFinalized,
            status: .success,
            actionType: executionResult.actionType
        )
        if savedMemoryDescription != nil {
            AgentTraceService.shared.record(
                traceID: traceID,
                stage: .memoryUpdate,
                status: .success,
                structure: ["explicit_long_term_preference"]
            )
        }
    }

    private func sendWithoutPrompt(
        _ content: String,
        clearDraft: Bool,
        explicitReminderSelection: ReminderAdjustmentSelection? = nil
    ) async {
        guard isSending == false else { return }
        viewportController.prepareForUserSend()
        isSending = true
        isStreamingReply = false
        if clearDraft {
            draft = ""
        }
        defer {
            isSending = false
        }
        await sendPrompt(
            content,
            explicitReminderSelection: explicitReminderSelection
        )
    }

    @MainActor
    private func handleUndoCommand(
        _ content: String,
        session: ChatSession
    ) async -> Bool {
        guard AgentUndoCommandParser().matches(content) else { return false }

        let userMessage = ChatMessage(sessionID: session.id, role: "user", text: content)
        let assistantMessage = ChatMessage(
            sessionID: session.id,
            role: "assistant",
            text: "",
            status: "streaming"
        )
        modelContext.insert(userMessage)
        modelContext.insert(assistantMessage)

        let candidate = actionLogs.reversed().compactMap { log -> (ActionLog, AgentConversationPresentation)? in
            guard log.sessionID == session.id,
                  log.actionType == "agent_run",
                  ["success", "partial"].contains(log.executionStatus),
                  let presentation = structuredPresentation(from: log),
                  AgentUndoRecordStore.shared.record(
                    forwardRunID: presentation.result.runID
                  )?.status == .available else {
                return nil
            }
            return (log, presentation)
        }.first

        if let (log, presentation) = candidate {
            await undoStructuredRun(log, presentation: presentation)
            switch log.executionStatus {
            case "undone":
                assistantMessage.text = "已经恢复到刚才操作之前的状态。"
            case "undo_conflict":
                assistantMessage.text = "任务后来发生了变化，我没有覆盖你在 Reminders 中的新修改。"
            case "undo_partial":
                assistantMessage.text = "部分操作已经恢复，另一些项目没有处理。"
            default:
                assistantMessage.text = log.errorMessage.nonEmpty ?? "这次撤销没有完成。"
            }
        } else {
            assistantMessage.text = "当前没有可以撤销的操作。"
        }

        assistantMessage.status = "sent"
        session.updatedAt = .now
        session.lastMessagePreview = content
        try? modelContext.save()
        return true
    }

    @MainActor
    private func handlePendingInteractionCommand(
        _ content: String,
        session: ChatSession
    ) async -> Bool {
        let command = AgentPendingInteractionCommandParser().parse(content)
        guard command != .none else { return false }

        let userMessage = ChatMessage(sessionID: session.id, role: "user", text: content)
        let assistantMessage = ChatMessage(
            sessionID: session.id,
            role: "assistant",
            text: "",
            status: "streaming"
        )
        modelContext.insert(userMessage)
        modelContext.insert(assistantMessage)

        guard let active = AgentPendingInteractionStore.shared.active(for: session.id),
              let log = actionLogs.reversed().first(where: { log in
                  guard log.sessionID == session.id,
                        log.actionType == "agent_run",
                        log.executionStatus == "awaiting_confirmation",
                        let data = log.payloadJSON.data(using: .utf8),
                        let presentation = try? JSONDecoder().decode(
                            AgentConversationPresentation.self,
                            from: data
                        ) else { return false }
                  return presentation.confirmationPayload?.interactionID == active.interactionID
              }),
              let data = log.payloadJSON.data(using: .utf8),
              let pending = try? JSONDecoder().decode(AgentConversationPresentation.self, from: data) else {
            assistantMessage.text = "当前没有等待确认的方案。"
            assistantMessage.status = "sent"
            session.updatedAt = .now
            session.lastMessagePreview = content
            try? modelContext.save()
            return true
        }

        let completed: AgentConversationPresentation?
        switch command {
        case .confirm:
            completed = await executeStructuredRun(log, pending: pending, updatesOriginalMessage: false)
        case .cancel:
            let cancelled = conversationCoordinator.cancel(pending)
            applyStructuredPresentation(cancelled, to: log, updatesOriginalMessage: false)
            completed = cancelled
        case .none:
            completed = nil
        }

        assistantMessage.text = completed?.reply ?? "这份方案已经失效，请重新生成。"
        assistantMessage.status = "sent"
        session.updatedAt = .now
        session.lastMessagePreview = content
        try? modelContext.save()
        return true
    }

    private func activePendingPresentation(
        for sessionID: UUID
    ) -> AgentConversationPresentation? {
        guard let active = AgentPendingInteractionStore.shared.active(for: sessionID) else {
            return nil
        }
        return actionLogs.reversed().compactMap { log -> AgentConversationPresentation? in
            guard log.sessionID == sessionID,
                  log.actionType == "agent_run",
                  log.executionStatus == "awaiting_confirmation",
                  let data = log.payloadJSON.data(using: .utf8),
                  let presentation = try? JSONDecoder().decode(
                      AgentConversationPresentation.self,
                      from: data
                  ),
                  presentation.confirmationPayload?.interactionID == active.interactionID else {
                return nil
            }
            return presentation
        }.first
    }

    private func reconcileInterruptedStructuredLogs() {
        let successful: Set<AgentToolExecutionStatus> = [.success, .unchanged, .alreadyApplied]
        let terminal: Set<AgentToolExecutionStatus> = successful.union([.failed, .skipped, .cancelled, .timedOut])
        var changed = false

        for log in actionLogs where log.actionType == "agent_run" && log.executionStatus == "pending" {
            guard let presentation = structuredPresentation(from: log) else { continue }
            let writeResults = presentation.result.toolResults.filter { isWriteTool($0.tool) }
            guard writeResults.isEmpty == false,
                  writeResults.allSatisfy({ terminal.contains($0.status) }) else { continue }

            let successCount = writeResults.filter { successful.contains($0.status) }.count
            let failureCount = writeResults.count - successCount
            if failureCount == 0 {
                log.executionStatus = "success"
                log.errorMessage = ""
            } else if successCount > 0 {
                log.executionStatus = "partial"
                log.errorMessage = "部分操作没有完成，请核对 Reminders 中的实际结果。"
            } else {
                log.executionStatus = "failed"
                log.errorMessage = presentation.result.error?.userVisibleMessage
                    ?? "上次操作没有完成，请核对 Reminders 中的实际结果。"
            }
            log.executedAt = log.executedAt ?? .now
            changed = true
        }

        if changed {
            try? modelContext.save()
        }
    }

    @MainActor
    private func finalizeStructuredPresentation(
        _ presentation: AgentConversationPresentation,
        assistantMessage: ChatMessage,
        session: ChatSession,
        userContent: String
    ) async {
        assistantMessage.text = presentation.reply
        assistantMessage.status = "sent"
        isStreamingReply = false

        let writeResults = presentation.result.toolResults.filter { isWriteTool($0.tool) }
        let pendingWrites = presentation.result.pendingToolCalls.filter { isWriteTool($0.tool) }
        if writeResults.isEmpty == false || pendingWrites.isEmpty == false {
            if presentation.result.status == .awaitingConfirmation,
               let currentInteractionID = presentation.confirmationPayload?.interactionID {
                for existingLog in actionLogs where
                    existingLog.sessionID == session.id &&
                    existingLog.actionType == "agent_run" &&
                    existingLog.executionStatus == "awaiting_confirmation" {
                    let existingPresentation = existingLog.payloadJSON.data(using: .utf8)
                        .flatMap {
                            try? JSONDecoder().decode(AgentConversationPresentation.self, from: $0)
                        }
                    let existingInteractionID = existingPresentation?.confirmationPayload?.interactionID
                    if existingInteractionID != currentInteractionID {
                        existingLog.executionStatus = "cancelled"
                        existingLog.errorMessage = "已被新方案替代"
                    }
                }
            }
            let summary = structuredSummary(for: presentation.result)
            assistantMessage.actionResultSummary = summary
            if let data = try? JSONEncoder().encode(presentation) {
                let log = ActionLog(
                    sessionID: session.id,
                    messageID: assistantMessage.id,
                    actionType: "agent_run",
                    payloadJSON: String(decoding: data, as: UTF8.self),
                    executionStatus: actionStatus(for: presentation.result.status),
                    errorMessage: presentation.result.error?.userVisibleMessage ?? "",
                    executedAt: presentation.result.status == .awaitingConfirmation ? nil : .now
                )
                modelContext.insert(log)
            }
        }

        session.updatedAt = .now
        session.lastMessagePreview = userContent
        try? modelContext.save()

        if writeResults.contains(where: { [.success, .unchanged, .alreadyApplied].contains($0.status) }) {
            await appModel.refreshReminderLists()
        }
        _ = updateSessionSummary(for: session.id)
        runtimeNotice = RuntimeNotice(text: "当前回复由 0.5 结构化 Agent 完成。", tone: .success)
        try? modelContext.save()
    }

    private func isWriteTool(_ tool: AgentToolName) -> Bool {
        ![AgentToolName.searchReminders, .getReminderDetails, .proposeSchedule].contains(tool)
    }

    private func actionStatus(for status: AgentRunStatus) -> String {
        switch status {
        case .awaitingConfirmation: "awaiting_confirmation"
        case .succeeded: "success"
        case .partial: "partial"
        case .cancelled: "cancelled"
        case .failed: "failed"
        default: "pending"
        }
    }

    private func structuredSummary(for result: AgentRunResult) -> String {
        if result.status == .awaitingConfirmation,
           let proposal = result.toolResults.last(where: { $0.tool == .proposeSchedule }),
           case let .array(items)? = proposal.result?["items"] {
            return "等待确认 \(items.count) 项排期"
        }
        if let apply = result.toolResults.last(where: { $0.tool == .applySchedule }),
           case let .integer(success)? = apply.result?["successful_count"],
           case let .integer(failed)? = apply.result?["failed_count"] {
            return failed == 0 ? "已完成 \(success) 项操作" : "成功 \(success) 项，失败 \(failed) 项"
        }
        let successful: Set<AgentToolExecutionStatus> = [.success, .unchanged, .alreadyApplied]
        let successCount = result.toolResults.lazy.filter { successful.contains($0.status) && isWriteTool($0.tool) }.count
        if result.status == .awaitingConfirmation {
            return "等待确认 \(result.pendingToolCalls.filter { isWriteTool($0.tool) }.count) 项操作"
        }
        let failedCount = result.toolResults.lazy.filter { isWriteTool($0.tool) && !successful.contains($0.status) }.count
        return failedCount == 0 ? "已完成 \(successCount) 项操作" : "成功 \(successCount) 项，失败 \(failedCount) 项"
    }

    private func shouldRefreshContext(for content: String) -> Bool {
        if let lastSync = appModel.lastReminderSyncAt,
           Date().timeIntervalSince(lastSync) <= 5 {
            let taskSignals = ["今天", "明天", "后天", "清单", "任务", "提醒", "刚才", "上一条", "第一条", "第二条", "未完成"]
            return taskSignals.contains { content.contains($0) }
        }
        return true
    }

    private func makeContextSnapshot(
        session: ChatSession,
        conversationHistory: [AgentConversationTurn],
        documents: AgentDocumentContext
    ) -> AgentContextSnapshot {
        let stored = AgentSessionContextStore.shared.context(for: session.id)
        let listIDs = Dictionary(uniqueKeysWithValues: appModel.reminderLists.map { ($0.title, $0.id) })
        let now = Date()
        let calendar = Calendar.current
        let contextItems = appModel.reminderItems.map { item in
            var relevance: [ReminderContextRelevance] = []
            if let dueDate = item.dueDate {
                if calendar.isDateInToday(dueDate) {
                    relevance.append(.today)
                } else if dueDate < now, item.isCompleted == false {
                    relevance.append(.overdue)
                }
            }
            if item.isCompleted == false {
                relevance.append(.openItem)
            }
            return ReminderContextItem(
                id: item.id,
                title: item.title,
                listID: listIDs[item.listTitle],
                listTitle: item.listTitle,
                dueDate: item.dueDate,
                isCompleted: item.isCompleted,
                lastModifiedAt: nil,
                relevanceReasons: relevance,
                notesPreview: item.notes
            )
        }
        let documentInput = AgentContextDocumentsInput(
            prompt: documents.prompt,
            memory: documents.memory,
            solu: documents.solu,
            operatingGuide: documents.operatingGuide,
            fallback: documents
        )
        let snapshotIsStale = appModel.lastReminderSyncAt.map { now.timeIntervalSince($0) > 5 } ?? true
        return AgentContextBuilder().build(
            from: AgentContextBuildInput(
                generatedAt: now,
                timeZoneIdentifier: TimeZone.current.identifier,
                session: SessionContext(
                    id: session.id,
                    title: session.title,
                    createdAt: session.createdAt,
                    updatedAt: session.updatedAt
                ),
                recentTurns: conversationHistory,
                sessionSummary: stored?.summary,
                reminderLists: appModel.reminderLists.map {
                    ReminderListContextItem(id: $0.id, title: $0.title)
                },
                reminders: contextItems,
                references: stored?.references ?? .empty,
                preferences: AgentUserMemoryStore.shared.items(),
                documents: documentInput,
                privacy: AgentContextPrivacyStore.shared.settings(),
                reminderSnapshotIsStale: snapshotIsStale
            )
        )
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
                throw VoiceTranscriptionError.connectionFailed("语音整理超时了，请再试一次。")
            }

            guard let first = try await group.next() else {
                throw VoiceTranscriptionError.connectionFailed("语音整理失败了，请再试一次。")
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

    private struct ActionExecutionOutcome {
        let reply: String
        let summary: String
    }

    private enum RescheduleExecutionError: LocalizedError {
        case invalidDueDate(String)

        var errorDescription: String? {
            switch self {
            case let .invalidDueDate(title):
                return "“\(title)”的目标时间无效。"
            }
        }
    }

    private struct ResolvedReminderTarget {
        let targetText: String
        let identifier: String?
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
    ) async -> ActionExecutionOutcome? {
        guard let log = actionLogs.first(where: { $0.id == logID }) else { return nil }

        if result.actionType == MockAgentIntent.planReschedule.rawValue {
            guard let envelope = decodePayload(from: result.payloadJSON),
                  envelope.action.entities["phase"]?.nonEmpty == "apply",
                  let plan = decodeReschedulePlan(from: envelope.action.entities),
                  plan.items.isEmpty == false else {
                log.executionStatus = "failed"
                log.errorMessage = "无法解析要应用的重排方案。"
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要应用这份重排方案，但这次没能解析出可执行的计划。",
                    summary: "应用方案失败"
                )
            }

            guard log.executionStatus == "pending", log.executedAt == nil else {
                return nil
            }

            var report = ReminderBatchExecution.execute(items: plan.items) { item in
                guard let dueDate = parseISODate(item.dueDateISO8601) else {
                    throw RescheduleExecutionError.invalidDueDate(item.title)
                }
                try ReminderStoreService().updateReminderDueDate(
                    identifier: item.reminderID,
                    dueDate: dueDate
                )
            }

            await appModel.refreshReminderLists()
            if let refreshError = appModel.reminderListsErrorMessage.nonEmpty {
                report = report.recordingRefreshFailure(refreshError)
            }

            var resultEntities = envelope.action.entities
            if let reportData = try? JSONEncoder().encode(report),
               let reportJSON = String(data: reportData, encoding: .utf8) {
                resultEntities["execution_result_json"] = reportJSON
            }
            resultEntities["execution_total_count"] = String(report.totalCount)
            resultEntities["execution_success_count"] = String(report.successCount)
            resultEntities["execution_failure_count"] = String(report.failureCount)
            if let updatedPayload = encodePayload(
                MockAgentEnvelope(
                    action: MockAgentActionPayload(
                        intent: envelope.action.intent,
                        title: envelope.action.title,
                        entities: resultEntities,
                        requiresConfirmation: envelope.action.requiresConfirmation
                    ),
                    confidence: envelope.confidence,
                    summary: rescheduleExecutionSummary(for: report),
                    followUpPrompt: envelope.followUpPrompt,
                    matchedSignals: envelope.matchedSignals
                )
            ) {
                log.payloadJSON = updatedPayload
            }

            log.executionStatus = report.status.rawValue
            log.errorMessage = rescheduleExecutionErrorMessage(for: report)
            log.executedAt = .now
            try? modelContext.save()
            return ActionExecutionOutcome(
                reply: rescheduleExecutionReply(for: report),
                summary: rescheduleExecutionSummary(for: report)
            )
        }

        if result.actionType == MockAgentIntent.createList.rawValue {
            guard let envelope = decodePayload(from: result.payloadJSON),
                  let listName = envelope.action.entities["list_name"]?.nonEmpty else {
                log.executionStatus = "failed"
                log.errorMessage = "无法解析要创建的列表名称。"
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要新建清单，但这次没能解析出清单名称。",
                    summary: "创建清单失败"
                )
            }

            let created = await appModel.createReminderList(named: listName)
            log.executionStatus = created ? "success" : "failed"
            log.errorMessage = created ? "" : appModel.reminderListsErrorMessage.nonEmpty ?? "创建列表失败。"
            log.executedAt = .now
            try? modelContext.save()
            if created {
                return ActionExecutionOutcome(
                    reply: "好，“\(listName)”这个清单已经建好了。",
                    summary: "已创建清单：\(listName)"
                )
            }
            let errorText = log.errorMessage.nonEmpty ?? "创建列表失败。"
            return ActionExecutionOutcome(
                reply: "我理解的是要新建清单，但这次没有建成功：\(errorText)",
                summary: "创建清单失败"
            )
        }

        if result.actionType == MockAgentIntent.createReminder.rawValue {
            guard let envelope = decodePayload(from: result.payloadJSON),
                  let rawTitle = envelope.action.entities["title"]?.nonEmpty else {
                log.executionStatus = "failed"
                log.errorMessage = "无法解析要创建的任务标题。"
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要新建任务，但这次没能解析出任务标题。",
                    summary: "创建任务失败"
                )
            }

            let title = ReminderCommandSanitizer.title(
                modelTitle: rawTitle,
                sourceText: envelope.action.entities["source_text"] ?? ""
            )
            guard title.isEmpty == false else {
                log.executionStatus = "failed"
                log.errorMessage = "解析后的任务标题为空。"
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要新建任务，但这次没能解析出有效标题。",
                    summary: "创建任务失败"
                )
            }

            let sourceText = envelope.action.entities["source_text"] ?? ""
            let schedule = ReminderCreationSchedule.resolve(
                parsedDueDate: parseISODate(envelope.action.entities["due_date"]),
                sourceText: sourceText,
                preferences: AgentUserMemoryStore.shared.items()
            )
            let dueDate = schedule.dueDate
            let preferredListName = envelope.action.entities["preferred_list_name"]?.nonEmpty
            let note = envelope.action.entities["note"]?.nonEmpty ?? sourceText

            do {
                let reminderID = try ReminderStoreService().createReminder(
                    input: ReminderCreateInput(
                        title: title,
                        notes: note,
                        dueDate: dueDate,
                        includesTime: schedule.includesTime,
                        preferredListName: preferredListName
                    )
                )
                await appModel.refreshReminderLists()
                appModel.prepareReminderFocus(identifier: reminderID)
                log.executionStatus = "success"
                log.errorMessage = ""
                log.undoToken = reminderID
                let actualListName = appModel.reminderItems
                    .first(where: { $0.id == reminderID })?
                    .listTitle
                    .nonEmpty ?? preferredListName
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: createReminderSuccessReply(
                        title: title,
                        dueDate: dueDate,
                        listName: actualListName
                    ),
                    summary: "已创建任务：\(title)"
                )
            } catch {
                log.executionStatus = "failed"
                log.errorMessage = error.localizedDescription
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要新建任务，但这次没有写进提醒事项：\(error.localizedDescription)",
                    summary: "创建任务失败"
                )
            }
        }

        if result.actionType == MockAgentIntent.updateReminder.rawValue {
            guard let envelope = decodePayload(from: result.payloadJSON),
                  let dueDateValue = actionEntityValue(
                    in: envelope.action.entities,
                    keys: ["due_date", "target_date", "datetime"]
                  ),
                  let parsedDueDate = parseISODate(dueDateValue),
                  let resolvedReference = resolveUpdateReminderReference(
                    rawTarget: actionEntityValue(
                        in: envelope.action.entities,
                        keys: ["target", "title", "task_title", "task", "object"]
                    ) ?? "",
                    sourceText: envelope.action.entities["source_text"] ?? "",
                    entities: envelope.action.entities,
                    sessionID: log.sessionID
                  ) else {
                log.executionStatus = "failed"
                log.errorMessage = "无法解析要修改的任务或目标时间。"
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要修改任务时间，但这次没能解析出具体任务或时间。",
                    summary: "修改任务时间失败"
                )
            }

            let target = resolvedReference.targetText
            let dueDate = updateDueDate(
                parsedDueDate,
                entities: envelope.action.entities,
                reminderIdentifier: resolvedReference.identifier
            )
            do {
                let updatedIdentifier: String
                if let identifier = resolvedReference.identifier {
                    updatedIdentifier = try ReminderStoreService().updateReminderDueDate(
                        identifier: identifier,
                        dueDate: dueDate
                    )
                } else {
                    updatedIdentifier = try await ReminderStoreService().updateReminderDueDate(
                        targetText: target,
                        dueDate: dueDate
                    )
                }
                await appModel.refreshReminderLists()
                var updatedEntities = envelope.action.entities
                updatedEntities["target"] = target
                updatedEntities["due_date"] = ISO8601DateFormatter().string(from: dueDate)
                if let payloadJSON = encodePayload(
                    MockAgentEnvelope(
                        action: MockAgentActionPayload(
                            intent: envelope.action.intent,
                            title: envelope.action.title,
                            entities: updatedEntities,
                            requiresConfirmation: false
                        ),
                        confidence: envelope.confidence,
                        summary: "已修改任务时间：\(target)",
                        followUpPrompt: nil,
                        matchedSignals: envelope.matchedSignals
                    )
                ) {
                    log.payloadJSON = payloadJSON
                }
                log.executionStatus = "success"
                log.errorMessage = ""
                log.undoToken = updatedIdentifier
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "好，“\(target)”的时间已经改好了。",
                    summary: "已修改任务时间：\(target)"
                )
            } catch {
                log.executionStatus = "failed"
                log.errorMessage = error.localizedDescription
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "这次还不能直接修改：\(error.localizedDescription)",
                    summary: "修改任务时间失败"
                )
            }
        }

        if result.actionType == MockAgentIntent.moveReminder.rawValue {
            guard let envelope = decodePayload(from: result.payloadJSON),
                  let destination = actionEntityValue(
                    in: envelope.action.entities,
                    keys: ["destination_list", "preferred_list_name", "list_name", "destination"]
                  ),
                  let resolvedReference = resolveReminderReference(
                    entities: envelope.action.entities,
                    rawTarget: actionEntityValue(
                        in: envelope.action.entities,
                        keys: ["target", "title", "task_title", "task", "object"]
                    ) ?? "",
                    sessionID: log.sessionID
                  ) else {
                log.executionStatus = "failed"
                log.errorMessage = "无法解析要移动的任务或目标列表。"
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要移动任务，但这次没能解析出任务或目标清单。",
                    summary: "移动任务失败"
                )
            }

            let target = resolvedReference.targetText
            do {
                guard let identifier = resolvedReference.identifier else {
                    throw ReminderStoreError.reminderNotFound(target)
                }
                let movedIdentifier = try ReminderStoreService().moveReminder(
                    identifier: identifier,
                    destinationListName: destination
                )
                await appModel.refreshReminderLists()
                log.executionStatus = "success"
                log.errorMessage = ""
                log.undoToken = movedIdentifier
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "好，“\(target)”这条我已经移到“\(destination)”了。",
                    summary: "已移动任务：\(target)"
                )
            } catch {
                log.executionStatus = "failed"
                log.errorMessage = error.localizedDescription
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要移动任务，但这次没有改成功：\(error.localizedDescription)",
                    summary: "移动任务失败"
                )
            }
        }

        if result.actionType == MockAgentIntent.completeReminder.rawValue {
            guard let envelope = decodePayload(from: result.payloadJSON),
                  let resolvedReference = resolveReminderReference(
                    entities: envelope.action.entities,
                    rawTarget: actionEntityValue(
                        in: envelope.action.entities,
                        keys: ["target", "title", "task_title", "task", "object"]
                    ) ?? "",
                    sessionID: log.sessionID
                  ) else {
                log.executionStatus = "failed"
                log.errorMessage = "无法解析要完成的任务。"
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要完成一条任务，但这次没能解析出具体目标。",
                    summary: "完成任务失败"
                )
            }

            let target = resolvedReference.targetText
            do {
                guard let identifier = resolvedReference.identifier else {
                    throw ReminderStoreError.reminderNotFound(target)
                }
                let completedIdentifier = try ReminderStoreService().updateReminderCompletion(
                    identifier: identifier,
                    isCompleted: true
                )
                await appModel.refreshReminderLists()
                log.executionStatus = "success"
                log.errorMessage = ""
                log.undoToken = completedIdentifier
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "好，“\(target)”这条已经标记完成了。",
                    summary: "已完成任务：\(target)"
                )
            } catch {
                log.executionStatus = "failed"
                log.errorMessage = error.localizedDescription
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要完成任务，但这次没有改成功：\(error.localizedDescription)",
                    summary: "完成任务失败"
                )
            }
        }

        if result.actionType == MockAgentIntent.deleteReminder.rawValue {
            guard let envelope = decodePayload(from: result.payloadJSON) else {
                log.executionStatus = "failed"
                log.errorMessage = "无法解析要删除的任务。"
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要删除一条任务，但这次没能解析出具体目标。",
                    summary: "删除任务失败"
                )
            }

            let rawTarget = actionEntityValue(
                in: envelope.action.entities,
                keys: ["target", "title", "task_title", "task", "object"]
            ) ?? ""
            let resolvedReference = resolveReminderReference(
                entities: envelope.action.entities,
                rawTarget: rawTarget,
                sessionID: log.sessionID
            )
            guard let target = resolvedReference?.targetText.nonEmpty ?? rawTarget.nonEmpty else {
                log.executionStatus = "failed"
                log.errorMessage = "无法解析要删除的任务。"
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要删除一条任务，但这次没能解析出具体目标。",
                    summary: "删除任务失败"
                )
            }
            let targetDueDate = parseISODate(
                actionEntityValue(
                    in: envelope.action.entities,
                    keys: ["due_date", "target_date", "datetime"]
                )
            )
            do {
                let deletedIdentifier: String
                if let identifier = resolvedReference?.identifier {
                    let deleted = await appModel.deleteReminder(identifier: identifier)
                    guard deleted else {
                        throw ReminderStoreError.reminderNotFound(target)
                    }
                    deletedIdentifier = identifier
                } else {
                    deletedIdentifier = try await ReminderStoreService().deleteReminder(
                        targetText: target,
                        dueDate: targetDueDate
                    )
                    await appModel.refreshReminderLists()
                }
                log.executionStatus = "success"
                log.errorMessage = ""
                log.undoToken = deletedIdentifier
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "好，“\(target)”这条我已经帮你删掉了。",
                    summary: "已删除任务：\(target)"
                )
            } catch let error as ReminderStoreError {
                if case .reminderAmbiguous = error {
                    log.executionStatus = "needs_clarification"
                    log.errorMessage = error.localizedDescription
                    log.executedAt = .now
                    try? modelContext.save()
                    return ActionExecutionOutcome(
                        reply: error.localizedDescription,
                        summary: "需要确认要删除的任务"
                    )
                }
                log.executionStatus = "failed"
                log.errorMessage = error.localizedDescription
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要删除任务，但这次没有删成功：\(error.localizedDescription)",
                    summary: "删除任务失败"
                )
            } catch {
                log.executionStatus = "failed"
                log.errorMessage = error.localizedDescription
                log.executedAt = .now
                try? modelContext.save()
                return ActionExecutionOutcome(
                    reply: "我理解的是要删除任务，但这次没有删成功：\(error.localizedDescription)",
                    summary: "删除任务失败"
                )
            }
        }

        log.executionStatus = "success"
        log.executedAt = .now
        try? modelContext.save()
        return nil
    }

    private func decodePayload(from json: String) -> MockAgentEnvelope? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MockAgentEnvelope.self, from: data)
    }

    private func encodePayload(_ envelope: MockAgentEnvelope) -> String? {
        guard let data = try? JSONEncoder().encode(envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value, value.isEmpty == false else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func updateDueDate(
        _ parsedDueDate: Date,
        entities: [String: String],
        reminderIdentifier: String?
    ) -> Date {
        guard entities["preserve_existing_date"] == "true",
              let reminderIdentifier,
              let existingDueDate = appModel.reminderItems.first(where: { $0.id == reminderIdentifier })?.dueDate else {
            return parsedDueDate
        }

        let calendar = Calendar.current
        let existingDay = calendar.dateComponents([.year, .month, .day], from: existingDueDate)
        let requestedTime = calendar.dateComponents([.hour, .minute, .second], from: parsedDueDate)
        return calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: existingDay.year,
                month: existingDay.month,
                day: existingDay.day,
                hour: requestedTime.hour,
                minute: requestedTime.minute,
                second: requestedTime.second
            )
        ) ?? parsedDueDate
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

    private func resolveReminderReference(
        entities: [String: String],
        rawTarget: String,
        sessionID: UUID
    ) -> ResolvedReminderTarget? {
        let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetID = entities["target_id"]?.nonEmpty
        let ordinal = entities["ordinal"].flatMap(Int.init)
        let referenceSource = entities["reference_source"]
            .flatMap(AgentReferenceSource.init(rawValue:))
        let storedReferences = AgentSessionContextStore.shared.context(for: sessionID)?.references ?? .empty
        let request = AgentReferenceResolutionRequest(
            targetID: targetID,
            target: trimmed.nonEmpty,
            ordinal: ordinal,
            referenceSource: referenceSource,
            dueDate: parseISODate(entities["due_date"]),
            listID: entities["list_id"]?.nonEmpty,
            listTitle: entities["list_title"]?.nonEmpty
        )
        let resolution = AgentReferenceResolver().resolve(
            request,
            references: storedReferences,
            reminders: currentReminderContextItems()
        )
        if case let .resolved(item) = resolution {
            return ResolvedReminderTarget(targetText: item.title, identifier: item.id)
        }

        // Upgrade bridge: v0.3 stored only the most recently created ID in ActionLog.
        if targetID == nil, ordinal == nil, isRelativeReminderReference(trimmed),
           let recent = latestCreatedReminderReference(in: sessionID) {
            return recent
        }
        return nil
    }

    private func resolveUpdateReminderReference(
        rawTarget: String,
        sourceText: String,
        entities: [String: String],
        sessionID: UUID
    ) -> ResolvedReminderTarget? {
        let normalizedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let relativeOnlyPrefixes = [
            "改到", "再改到", "调整到", "再调整到", "延后到", "推迟到", "延期到"
        ]
        let relativeSignals = [
            "它", "这条", "那条", "上一条", "刚才", "刚刚", "刚创建", "刚建"
        ]
        let targetsRecentReminder = relativeOnlyPrefixes.contains { normalizedSource.hasPrefix($0) } ||
            relativeSignals.contains { normalizedSource.contains($0) }

        if entities["target_id"]?.nonEmpty == nil,
           entities["ordinal"]?.nonEmpty == nil,
           targetsRecentReminder,
           let recent = latestCreatedReminderReference(in: sessionID) {
            return recent
        }
        var targetEntities = entities
        // For an update action, due_date is the destination time, not a constraint on the current item.
        targetEntities["due_date"] = nil
        targetEntities["target_date"] = nil
        targetEntities["datetime"] = nil
        return resolveReminderReference(
            entities: targetEntities,
            rawTarget: rawTarget,
            sessionID: sessionID
        )
    }

    private func isRelativeReminderReference(_ value: String) -> Bool {
        let hints = [
            "当前这条", "这条", "那条", "上一条", "上一个", "刚才", "刚刚",
            "最新那条", "刚建", "新建的那条", "刚创建", "刚创建的那条"
        ]
        return hints.contains { value.contains($0) }
    }

    private func latestCreatedReminderReference(in sessionID: UUID) -> ResolvedReminderTarget? {
        let latestLog = actionLogs
            .filter {
                $0.sessionID == sessionID &&
                $0.actionType == MockAgentIntent.createReminder.rawValue &&
                $0.executionStatus == "success"
            }
            .sorted { $0.createdAt > $1.createdAt }
            .first

        guard let latestLog,
              let envelope = decodePayload(from: latestLog.payloadJSON),
              let title = envelope.action.entities["title"]?.nonEmpty else {
            return nil
        }

        return ResolvedReminderTarget(
            targetText: title,
            identifier: latestLog.undoToken.nonEmpty
        )
    }

    private func currentReminderContextItems() -> [ReminderContextItem] {
        let listIDs = Dictionary(uniqueKeysWithValues: appModel.reminderLists.map { ($0.title, $0.id) })
        return appModel.reminderItems.map { item in
            ReminderContextItem(
                id: item.id,
                title: item.title,
                listID: listIDs[item.listTitle],
                listTitle: item.listTitle,
                dueDate: item.dueDate,
                isCompleted: item.isCompleted,
                lastModifiedAt: nil,
                relevanceReasons: item.isCompleted ? [] : [.openItem],
                notesPreview: nil
            )
        }
    }

    @discardableResult
    private func recordReferenceOutcome(
        for log: ActionLog,
        shownReminderIDs: [String] = []
    ) -> Bool {
        let existing = AgentSessionContextStore.shared.context(for: log.sessionID)?.references ?? .empty
        let sourceMessageID = log.messageID
        let event: AgentReferenceEvent

        switch log.actionType {
        case MockAgentIntent.createReminder.rawValue:
            guard let identifier = log.undoToken.nonEmpty else { return false }
            event = .created(reminderID: identifier, sourceMessageID: sourceMessageID)
        case MockAgentIntent.updateReminder.rawValue:
            guard let identifier = log.undoToken.nonEmpty else { return false }
            event = .modified(reminderID: identifier, sourceMessageID: sourceMessageID)
        case MockAgentIntent.moveReminder.rawValue:
            guard let identifier = log.undoToken.nonEmpty else { return false }
            event = .moved(reminderID: identifier, sourceMessageID: sourceMessageID)
        case MockAgentIntent.completeReminder.rawValue:
            guard let identifier = log.undoToken.nonEmpty else { return false }
            event = .completed(reminderID: identifier, sourceMessageID: sourceMessageID)
        case MockAgentIntent.deleteReminder.rawValue:
            guard let identifier = log.undoToken.nonEmpty else { return false }
            event = .deleted(reminderID: identifier)
        case MockAgentIntent.summarizeLists.rawValue:
            let payloadIdentifiers = decodePayload(from: log.payloadJSON)?
                .action.entities["shown_ids"]?
                .split(separator: ",")
                .map(String.init) ?? []
            let identifiers = payloadIdentifiers.isEmpty ? shownReminderIDs : payloadIdentifiers
            guard identifiers.isEmpty == false else { return false }
            event = .shown(reminderIDs: identifiers, sourceMessageID: sourceMessageID)
        default:
            return false
        }

        let references = AgentReferenceRecorder().recording(event, in: existing)
        AgentSessionContextStore.shared.update(sessionID: log.sessionID, references: references)
        return true
    }

    @discardableResult
    private func updateSessionSummary(for sessionID: UUID) -> Bool {
        let sessionMessages = messages
            .filter { $0.sessionID == sessionID && $0.status != "streaming" }
            .sorted { $0.createdAt < $1.createdAt }
        let summaryMessages = sessionMessages.map { message in
            let role: AgentSummaryMessageRole = switch message.role {
            case "user": .user
            case "assistant": .assistant
            default: .system
            }
            let userText = role == .user ? message.text : ""
            return AgentSummaryMessage(
                id: message.id,
                role: role,
                currentGoal: inferredSummaryGoal(from: userText),
                taskScope: inferredTaskScope(from: userText),
                confirmedConstraints: inferredConstraints(from: userText),
                pendingQuestions: []
            )
        }
        let summaryByMessageID = Dictionary(uniqueKeysWithValues: sessionMessages.map { ($0.id, $0.actionResultSummary) })
        let facts = actionLogs
            .filter { $0.sessionID == sessionID && $0.executionStatus == "success" }
            .compactMap { log -> AgentActionSummaryFact? in
                guard let kind = successfulActionKind(for: log.actionType) else { return nil }
                return AgentActionSummaryFact(
                    messageID: log.messageID,
                    kind: kind,
                    succeeded: true,
                    readableFact: log.messageID.flatMap { summaryByMessageID[$0]?.nonEmpty },
                    reminderIDs: log.undoToken.nonEmpty.map { [$0] } ?? []
                )
            }
        let store = AgentSessionContextStore.shared
        let existing = store.context(for: sessionID)
        let service = AgentSessionSummaryService()
        guard service.shouldUpdate(existing: existing?.summary, messages: summaryMessages, actionFacts: facts),
              let summary = service.update(
                existing: existing?.summary,
                messages: summaryMessages,
                actionFacts: facts
              ) else {
            return false
        }
        store.update(sessionID: sessionID, summary: summary, references: existing?.references ?? .empty)
        return true
    }

    private func successfulActionKind(for actionType: String) -> AgentSuccessfulActionKind? {
        switch actionType {
        case MockAgentIntent.createReminder.rawValue: .create
        case MockAgentIntent.updateReminder.rawValue: .modify
        case MockAgentIntent.moveReminder.rawValue: .move
        case MockAgentIntent.completeReminder.rawValue: .complete
        case MockAgentIntent.deleteReminder.rawValue: .delete
        case MockAgentIntent.summarizeLists.rawValue: .show
        default: nil
        }
    }

    private func inferredSummaryGoal(from text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.isEmpty == false else { return nil }
        let signals = ["整理", "重排", "规划", "安排", "查看", "处理", "清理"]
        guard signals.contains(where: cleaned.contains) else { return nil }
        return String(cleaned.prefix(240))
    }

    private func inferredTaskScope(from text: String) -> String? {
        let scopes = ["收集箱", "项目", "下一步行动", "等待中", "也许以后", "未完成事项", "今天", "明天"]
        return scopes.first { text.contains($0) }
    }

    private func inferredConstraints(from text: String) -> [String] {
        let signals = ["不要", "只处理", "以内", "之前", "之后", "必须"]
        guard signals.contains(where: text.contains) else { return [] }
        return [String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))]
    }

    private func hydratedReschedulePlan(from entities: [String: String]) -> ReschedulePlan? {
        if let existing = decodeReschedulePlan(from: entities) {
            return existing
        }
        return ReschedulePlanner().makePlan(
            entities: entities,
            reminderItems: appModel.reminderItems
        )
    }

    private func decodeReschedulePlan(from entities: [String: String]) -> ReschedulePlan? {
        guard let value = entities["plan_json"]?.nonEmpty,
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ReschedulePlan.self, from: data)
    }

    private func enrichedRescheduleEntities(
        from entities: [String: String],
        plan: ReschedulePlan
    ) -> [String: String] {
        var updated = entities
        updated["phase"] = entities["phase"]?.nonEmpty ?? "plan"
        if entities["plan_json"]?.nonEmpty == nil {
            let data = try? JSONEncoder().encode(plan)
            updated["plan_json"] = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        updated["plan_item_count"] = String(plan.items.count)
        updated["scope_label"] = plan.scopeLabel
        updated["window_days"] = String(plan.windowDays)
        updated["start_date"] = plan.startDateISO8601
        updated["end_date"] = plan.endDateISO8601
        return updated
    }

    private func reschedulePlanReply(for plan: ReschedulePlan) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        let isoFormatter = ISO8601DateFormatter()

        var lines = [
            "我先给你排了一个方案，你看下合不合适。"
        ]

        for item in plan.items.prefix(6) {
            let dueLabel: String
            if let date = isoFormatter.date(from: item.dueDateISO8601) {
                dueLabel = formatter.string(from: date)
            } else {
                dueLabel = item.dueDateISO8601
            }
            lines.append("• \(item.title)：\(dueLabel)")
        }

        if plan.items.count > 6 {
            lines.append("• 另外还有 \(plan.items.count - 6) 条，已经一起排进方案里了。")
        }

        lines.append("确认的话，点卡片里的“应用这个方案”就行。")
        return lines.joined(separator: "\n")
    }

    private func rescheduleExecutionSummary(for report: ReminderBatchExecutionReport) -> String {
        "重排共 \(report.totalCount) 条：成功 \(report.successCount) 条，失败 \(report.failureCount) 条"
    }

    private func rescheduleExecutionReply(for report: ReminderBatchExecutionReport) -> String {
        var parts: [String] = []
        switch report.status {
        case .success:
            parts.append("已经按方案重排了 \(report.totalCount) 条任务。")
        case .partial:
            if report.failureCount > 0 {
                parts.append("这次重排共 \(report.totalCount) 条，成功 \(report.successCount) 条，失败 \(report.failureCount) 条。")
                parts.append(rescheduleFailureTitlesText(for: report))
            } else {
                parts.append("\(report.successCount) 条任务已经写入提醒事项。")
            }
        case .failed:
            parts.append("这次方案没有应用成功。共 \(report.totalCount) 条，成功 0 条，失败 \(report.failureCount) 条。")
            parts.append(rescheduleFailureTitlesText(for: report))
        }

        if let refreshError = report.refreshErrorMessage {
            parts.append("任务列表刷新失败：\(refreshError) 你可以稍后重新同步查看。")
        }
        return parts.filter { $0.isEmpty == false }.joined(separator: " ")
    }

    private func rescheduleFailureTitlesText(for report: ReminderBatchExecutionReport) -> String {
        let titles = report.failureTitles(limit: 3)
        guard titles.isEmpty == false else { return "" }
        let quotedTitles = titles.map { "“\($0)”" }.joined(separator: "、")
        let remainingCount = report.failureCount - titles.count
        if remainingCount > 0 {
            return "失败的是 \(quotedTitles) 等 \(report.failureCount) 条任务。"
        }
        return "失败的是 \(quotedTitles)。"
    }

    private func rescheduleExecutionErrorMessage(for report: ReminderBatchExecutionReport) -> String {
        var details = report.failedItems.prefix(3).map { item in
            "\(item.title)：\(item.errorMessage ?? "写入失败")"
        }
        if report.failureCount > 3 {
            details.append("另有 \(report.failureCount - 3) 条写入失败")
        }
        if let refreshError = report.refreshErrorMessage {
            details.append("刷新失败：\(refreshError)")
        }
        return details.joined(separator: "；")
    }

    private func resolveExecutionResult(
        userContent: String,
        remoteResult: MockAgentResult,
        runtimeContext: AIGTDAgentRuntimeContext?,
        contextSnapshot: AgentContextSnapshot?
    ) -> MockAgentResult {
        let localFallback = MockAgentService().respond(
            to: userContent,
            reminderLists: appModel.reminderLists,
            reminderItems: appModel.reminderItems,
            agentContext: runtimeContext,
            contextSnapshot: contextSnapshot
        )
        if isStructuredResult(remoteResult) {
            if AgentResultArbitration.shouldPreferLocalResult(
                remoteActionType: remoteResult.actionType,
                localActionType: localFallback.actionType
            ) {
                return normalizeStructuredResult(localFallback)
            }
            if remoteResult.actionType == MockAgentIntent.planReschedule.rawValue,
               localFallback.actionType == MockAgentIntent.updateReminder.rawValue {
                return normalizeStructuredResult(localFallback)
            }
            return normalizeStructuredResult(remoteResult)
        }

        if isStructuredResult(localFallback) {
            return normalizeStructuredResult(localFallback)
        }

        return remoteResult
    }

    private func resolveDisplayResult(
        remoteResult: MockAgentResult,
        executionResult: MockAgentResult
    ) -> MockAgentResult {
        if isStructuredResult(remoteResult) {
            return remoteResult
        }
        if isStructuredResult(executionResult) {
            return executionResult
        }
        return remoteResult
    }

    private func isStructuredResult(_ result: MockAgentResult) -> Bool {
        guard let actionType = result.actionType,
              actionType.isEmpty == false,
              decodePayload(from: result.payloadJSON) != nil else {
            return false
        }
        return true
    }

    private func normalizeStructuredResult(_ result: MockAgentResult) -> MockAgentResult {
        if result.actionType == MockAgentIntent.createReminder.rawValue,
           let envelope = decodePayload(from: result.payloadJSON),
           let rawTitle = envelope.action.entities["title"]?.nonEmpty {
            let sanitizedTitle = ReminderCommandSanitizer.title(
                modelTitle: rawTitle,
                sourceText: envelope.action.entities["source_text"] ?? ""
            )
            guard sanitizedTitle.isEmpty == false else {
                return result
            }

            var entities = envelope.action.entities
            entities["title"] = sanitizedTitle
            let sourceText = entities["source_text"] ?? ""
            let schedule = ReminderCreationSchedule.resolve(
                parsedDueDate: parseISODate(entities["due_date"]),
                sourceText: sourceText,
                preferences: AgentUserMemoryStore.shared.items()
            )
            entities["due_date"] = schedule.dueDate.map {
                ISO8601DateFormatter().string(from: $0)
            } ?? ""
            entities["due_date_has_time"] = schedule.includesTime ? "true" : "false"
            let updatedEnvelope = MockAgentEnvelope(
                action: MockAgentActionPayload(
                    intent: envelope.action.intent,
                    title: envelope.action.title,
                    entities: entities,
                    requiresConfirmation: envelope.action.requiresConfirmation
                ),
                confidence: envelope.confidence,
                summary: "准备创建任务：\(sanitizedTitle)",
                followUpPrompt: envelope.followUpPrompt,
                matchedSignals: envelope.matchedSignals
            )
            guard let payloadJSON = encodePayload(updatedEnvelope) else { return result }
            return MockAgentResult(
                reply: result.reply,
                summary: "准备创建任务：\(sanitizedTitle)",
                actionType: result.actionType,
                payloadJSON: payloadJSON,
                confidence: result.confidence,
                followUpPrompt: result.followUpPrompt
            )
        }

        guard result.actionType == MockAgentIntent.planReschedule.rawValue,
              let envelope = decodePayload(from: result.payloadJSON) else {
            return result
        }
        guard let plan = hydratedReschedulePlan(from: envelope.action.entities),
              plan.items.isEmpty == false else {
            return MockAgentResult(
                reply: "我看了一下，目前没有找到符合条件的未完成任务，所以没有生成空的重排方案。",
                summary: "没有可重排的任务",
                actionType: nil,
                payloadJSON: "{}",
                confidence: result.confidence,
                followUpPrompt: result.followUpPrompt
            )
        }

        let reply = reschedulePlanReply(for: plan)
        let summary = "已生成重排方案：\(plan.items.count) 条"
        var planEntities = envelope.action.entities
        planEntities["phase"] = "plan"
        let updatedEntities = enrichedRescheduleEntities(
            from: planEntities,
            plan: plan
        )
        let updatedEnvelope = MockAgentEnvelope(
            action: MockAgentActionPayload(
                intent: envelope.action.intent,
                title: envelope.action.title,
                entities: updatedEntities,
                requiresConfirmation: envelope.action.requiresConfirmation
            ),
            confidence: envelope.confidence,
            summary: summary,
            followUpPrompt: envelope.followUpPrompt,
            matchedSignals: envelope.matchedSignals
        )
        guard let payloadJSON = encodePayload(updatedEnvelope) else {
            return result
        }

        return MockAgentResult(
            reply: reply,
            summary: summary,
            actionType: result.actionType,
            payloadJSON: payloadJSON,
            confidence: result.confidence,
            followUpPrompt: result.followUpPrompt
        )
    }

    private func performScrollRequest(
        _ request: ChatViewportController.ScrollRequest,
        using proxy: ScrollViewProxy
    ) {
        DispatchQueue.main.async {
            switch request.behavior {
            case .animated:
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            case .immediate:
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
             MockAgentIntent.summarizeLists.rawValue,
             MockAgentIntent.updateReminder.rawValue:
            appModel.selectedTab = .reminders
        case MockAgentIntent.deleteReminder.rawValue:
            if log.executionStatus == "awaiting_confirmation" {
                Task { await confirmPendingAction(log) }
            } else if log.executionStatus == "needs_clarification" {
                isComposerFocused = true
                composerFocusRequestID = UUID()
                composerFocusBridge.focus()
            } else {
                appModel.selectedTab = .reminders
            }
        case MockAgentIntent.planReschedule.rawValue:
            if let phase = decodePayload(from: log.payloadJSON)?.action.entities["phase"]?.nonEmpty,
               phase == "plan",
               log.executionStatus == "success",
               executingActionIDs.contains(log.id) == false {
                Task {
                    await applyReschedulePlan(log)
                }
            } else if ["success", "partial"].contains(log.executionStatus) {
                appModel.selectedTab = .reminders
            } else if let followUp = decodePayload(from: log.payloadJSON)?.followUpPrompt?.nonEmpty {
                draft = followUp
                isComposerFocused = true
                composerFocusRequestID = UUID()
                composerFocusBridge.focus()
            }
        case "agent_run":
            if log.executionStatus == "awaiting_confirmation" {
                Task { await confirmStructuredRun(log) }
            } else if let presentation = structuredPresentation(from: log),
                      AgentRecoveryPlanner().makePlan(from: presentation.result.toolResults)
                        .hasRetryableFailures {
                Task { await retryStructuredRun(log, presentation: presentation) }
            } else if let presentation = structuredPresentation(from: log),
                      AgentUndoRecordStore.shared.record(
                        forwardRunID: presentation.result.runID
                      )?.status == .available {
                Task { await undoStructuredRun(log, presentation: presentation) }
            } else {
                appModel.selectedTab = .reminders
            }
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

    private func handleCardAdjustAction(_ log: ActionLog) {
        guard log.actionType == "agent_run",
              log.executionStatus == "awaiting_confirmation" else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = "请把这份方案调整为："
        }
        isComposerFocused = true
        composerFocusRequestID = UUID()
        DispatchQueue.main.async {
            composerFocusBridge.focus()
        }
    }

    private func handleCardCancelAction(_ log: ActionLog) {
        guard log.actionType == "agent_run",
              log.executionStatus == "awaiting_confirmation",
              let data = log.payloadJSON.data(using: .utf8),
              let pending = try? JSONDecoder().decode(AgentConversationPresentation.self, from: data) else {
            return
        }
        let cancelled = conversationCoordinator.cancel(pending)
        applyStructuredPresentation(cancelled, to: log, updatesOriginalMessage: true)
    }

    @MainActor
    private func confirmStructuredRun(_ log: ActionLog) async {
        guard log.executionStatus == "awaiting_confirmation",
              let data = log.payloadJSON.data(using: .utf8),
              let pending = try? JSONDecoder().decode(AgentConversationPresentation.self, from: data) else {
            return
        }

        _ = await executeStructuredRun(log, pending: pending, updatesOriginalMessage: true)
    }

    @MainActor
    private func executeStructuredRun(
        _ log: ActionLog,
        pending: AgentConversationPresentation,
        updatesOriginalMessage: Bool
    ) async -> AgentConversationPresentation? {
        guard log.executionStatus == "awaiting_confirmation",
              executingActionIDs.insert(log.id).inserted else { return nil }
        defer { executingActionIDs.remove(log.id) }

        log.executionStatus = "pending"
        log.errorMessage = ""
        try? modelContext.save()

        let completed = await conversationCoordinator.confirm(
            pending,
            configuration: activeModelConfiguration
        )
        applyStructuredPresentation(
            completed,
            to: log,
            updatesOriginalMessage: updatesOriginalMessage
        )
        if completed.result.toolResults.contains(where: {
            isWriteTool($0.tool) && [.success, .unchanged, .alreadyApplied].contains($0.status)
        }) {
            await appModel.refreshReminderLists()
        }
        return completed
    }

    @MainActor
    private func retryStructuredRun(
        _ log: ActionLog,
        presentation: AgentConversationPresentation
    ) async {
        guard ["partial", "failed"].contains(log.executionStatus),
              executingActionIDs.insert(log.id).inserted else { return }
        defer { executingActionIDs.remove(log.id) }

        log.executionStatus = "pending"
        log.errorMessage = ""
        try? modelContext.save()

        let completed = await conversationCoordinator.retryFailed(
            presentation,
            configuration: activeModelConfiguration
        )
        applyStructuredPresentation(completed, to: log, updatesOriginalMessage: true)
        if completed.result.toolResults.contains(where: {
            isWriteTool($0.tool) && [.success, .unchanged, .alreadyApplied].contains($0.status)
        }) {
            await appModel.refreshReminderLists()
        }
    }

    @MainActor
    private func undoStructuredRun(
        _ log: ActionLog,
        presentation: AgentConversationPresentation
    ) async {
        guard ["success", "partial"].contains(log.executionStatus),
              let record = AgentUndoRecordStore.shared.record(
                forwardRunID: presentation.result.runID
              ),
              record.status == .available,
              executingActionIDs.insert(log.id).inserted else { return }
        defer { executingActionIDs.remove(log.id) }

        log.executionStatus = "pending"
        log.errorMessage = ""
        try? modelContext.save()

        do {
            let executor = AgentUndoExecutor(
                gateway: EventKitReminderStoreGateway(),
                writer: EventKitReminderToolWriter(),
                store: .shared
            )
            let result = try await executor.execute(recordID: record.id)
            switch result.record.status {
            case .undone:
                log.executionStatus = "undone"
                log.errorMessage = ""
            case .conflict:
                log.executionStatus = "undo_conflict"
                log.errorMessage = "任务已发生变化，未覆盖 Reminders 中的新内容。"
            case .partiallyFailed:
                log.executionStatus = "undo_partial"
                log.errorMessage = "部分操作未能恢复，请查看 Reminders 中的实际结果。"
            default:
                log.executionStatus = "undo_failed"
                log.errorMessage = "这次撤销没有完成。"
            }
            if let messageID = log.messageID,
               let assistantMessage = messages.first(where: { $0.id == messageID }) {
                assistantMessage.text = undoReply(for: result.record)
                assistantMessage.actionResultSummary = undoSummary(for: result.record)
            }
        } catch AgentUndoRecordStoreError.unavailable(.expired) {
            log.executionStatus = "undo_failed"
            log.errorMessage = "撤销时间已超过 10 分钟。"
        } catch {
            log.executionStatus = "undo_failed"
            log.errorMessage = "这次撤销没有完成，请查看 Reminders 中的实际状态。"
        }
        log.executedAt = .now
        try? modelContext.save()
        await appModel.refreshReminderLists()
    }

    private func undoReply(for record: AgentUndoRecord) -> String {
        switch record.status {
        case .undone:
            return "已经恢复到这次操作之前的状态。"
        case .conflict:
            return "任务后来发生了变化，我没有覆盖你在 Reminders 中的新修改。"
        case .partiallyFailed:
            return "部分操作已经恢复，另一些项目因为变化或写入失败没有处理。"
        default:
            return "这次撤销没有完成。"
        }
    }

    private func undoSummary(for record: AgentUndoRecord) -> String {
        let restored = record.outcomes.filter { $0.status == .undone }.count
        let unresolved = record.outcomes.count - restored
        return unresolved == 0 ? "已恢复 \(restored) 项操作" : "已恢复 \(restored) 项，未恢复 \(unresolved) 项"
    }

    private func structuredPresentation(from log: ActionLog) -> AgentConversationPresentation? {
        guard log.actionType == "agent_run",
              let data = log.payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentConversationPresentation.self, from: data)
    }

    @MainActor
    private func applyStructuredPresentation(
        _ completed: AgentConversationPresentation,
        to log: ActionLog,
        updatesOriginalMessage: Bool
    ) {
        log.executionStatus = actionStatus(for: completed.result.status)
        log.errorMessage = completed.result.error?.userVisibleMessage ?? ""
        log.executedAt = .now
        if let encoded = try? JSONEncoder().encode(completed) {
            log.payloadJSON = String(decoding: encoded, as: UTF8.self)
        }
        if updatesOriginalMessage,
           let messageID = log.messageID,
           let assistantMessage = messages.first(where: { $0.id == messageID }) {
            assistantMessage.text = completed.reply
            assistantMessage.actionResultSummary = structuredSummary(for: completed.result)
            assistantMessage.status = "sent"
        }
        try? modelContext.save()
    }

    @MainActor
    private func confirmPendingAction(_ log: ActionLog) async {
        guard log.executionStatus == "awaiting_confirmation",
              executingActionIDs.insert(log.id).inserted else { return }
        defer { executingActionIDs.remove(log.id) }

        log.executionStatus = "pending"
        log.errorMessage = ""
        try? modelContext.save()
        let result = MockAgentResult(
            reply: "",
            summary: "",
            actionType: log.actionType,
            payloadJSON: log.payloadJSON,
            confidence: 1,
            followUpPrompt: nil
        )
        if let outcome = await executeResultAction(logID: log.id, result: result),
           let messageID = log.messageID,
           let assistantMessage = messages.first(where: { $0.id == messageID }) {
            assistantMessage.text = outcome.reply
            assistantMessage.actionResultSummary = outcome.summary
        }
        if log.executionStatus == "success" {
            _ = recordReferenceOutcome(for: log)
            _ = updateSessionSummary(for: log.sessionID)
        }
        try? modelContext.save()
    }

    @MainActor
    private func applyReschedulePlan(_ log: ActionLog) async {
        guard let envelope = decodePayload(from: log.payloadJSON),
              envelope.action.entities["phase"]?.nonEmpty == "plan",
              log.executionStatus == "success",
              log.executedAt != nil,
              executingActionIDs.insert(log.id).inserted,
              let plan = decodeReschedulePlan(from: envelope.action.entities),
              plan.items.isEmpty == false else {
            return
        }
        defer { executingActionIDs.remove(log.id) }

        let applyEntities = enrichedRescheduleEntities(
            from: envelope.action.entities.merging(["phase": "apply"]) { _, new in new },
            plan: plan
        )
        let applyEnvelope = MockAgentEnvelope(
            action: MockAgentActionPayload(
                intent: MockAgentIntent.planReschedule.rawValue,
                title: envelope.action.title,
                entities: applyEntities,
                requiresConfirmation: false
            ),
            confidence: envelope.confidence,
            summary: "准备应用重排方案",
            followUpPrompt: envelope.followUpPrompt,
            matchedSignals: envelope.matchedSignals
        )
        guard let payloadJSON = encodePayload(applyEnvelope) else { return }

        log.payloadJSON = payloadJSON
        log.executionStatus = "pending"
        log.errorMessage = ""
        log.executedAt = nil

        if let messageID = log.messageID,
           let message = messages.first(where: { $0.id == messageID }) {
            message.text = "我来按这个方案重新排一下。"
            message.actionResultSummary = "准备应用重排方案"
            message.status = "sent"
        }
        try? modelContext.save()

        let applyResult = MockAgentResult(
            reply: "我来按这个方案重新排一下。",
            summary: "准备应用重排方案",
            actionType: MockAgentIntent.planReschedule.rawValue,
            payloadJSON: payloadJSON,
            confidence: envelope.confidence,
            followUpPrompt: envelope.followUpPrompt
        )
        if let outcome = await executeResultAction(logID: log.id, result: applyResult),
           let messageID = log.messageID,
           let message = messages.first(where: { $0.id == messageID }) {
            message.text = outcome.reply
            message.actionResultSummary = outcome.summary
            message.status = "sent"
            try? modelContext.save()
        }
    }

    private func updateRuntimeNotice(
        remoteResult: MockAgentResult,
        executionResult: MockAgentResult
    ) {
        if isStructuredResult(remoteResult) == false,
           isStructuredResult(executionResult) {
            runtimeNotice = RuntimeNotice(
                text: "这次我按本地规则直接接住并处理了这条消息。",
                tone: .success
            )
            return
        }

        if remoteResult.summary.contains("远端模型暂时不可用") {
            runtimeNotice = RuntimeNotice(
                text: "远端模型暂时不可用，这次未能完成回复。",
                tone: .warning
            )
            return
        }

        if remoteResult.summary.contains("远端返回格式暂未兼容") {
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
#if DEBUG || INTERNAL
        guard activeModelConfiguration == nil else { return false }
        guard hasSeenModelSetupPrompt == false else { return false }
        return content.isEmpty == false
#else
        return false
#endif
    }

    private func restorePendingDraftIfNeeded() {
        guard appModel.shouldResumeChatComposer else { return }
        let source = appModel.chatComposerResumeSource
        let restored = appModel.consumePendingChatDraft()
        if source == .reminderAdjustment {
            pendingReminderAdjustmentSelection = nil
            if let item = appModel.consumePendingReminderAdjustmentContext() {
                pendingReminderAdjustmentSelection = ReminderAdjustmentSelection(
                    reminderID: item.id,
                    reminderTitle: item.title
                )
            }
        }
        if restored.isEmpty == false {
            draft = restored
        }
        pendingReminderAdjustmentSelection = ReminderAdjustmentDraftPolicy.retainedSelection(
            pendingReminderAdjustmentSelection,
            in: restored
        )
        appModel.shouldResumeChatComposer = false
        appModel.chatComposerResumeSource = nil
        isComposerFocused = true
        composerFocusRequestID = UUID()
        composerFocusBridge.focus()
        if source == .modelSetup {
            runtimeNotice = RuntimeNotice(
                text: "设置已保存，可以继续刚才的消息了。",
                tone: .success
            )
        }
    }

    private func takeReminderAdjustmentSelection(
        forSending content: String
    ) -> ReminderAdjustmentSelection? {
        let selection = ReminderAdjustmentDraftPolicy.retainedSelection(
            pendingReminderAdjustmentSelection,
            in: content
        )
        pendingReminderAdjustmentSelection = nil
        return selection
    }

    private func recordExplicitReminderSelection(
        _ selection: ReminderAdjustmentSelection,
        sessionID: UUID,
        sourceMessageID: UUID
    ) {
        let store = AgentSessionContextStore.shared
        let existing = store.context(for: sessionID)?.references ?? .empty
        let references = AgentReferenceRecorder().recording(
            .selected(
                reminderID: selection.reminderID,
                sourceMessageID: sourceMessageID
            ),
            in: existing
        )
        store.update(sessionID: sessionID, references: references)
    }

    private func pendingAssistantReply(for result: MockAgentResult) -> String {
        switch result.actionType {
        case MockAgentIntent.createReminder.rawValue:
            return "我来帮你记一下这条任务。"
        case MockAgentIntent.updateReminder.rawValue:
            return "我来帮你修改这条任务的时间。"
        case MockAgentIntent.createList.rawValue:
            return "我来帮你建这个清单。"
        case MockAgentIntent.moveReminder.rawValue:
            return "我来帮你调整这条任务。"
        case MockAgentIntent.completeReminder.rawValue:
            return "我来帮你把这条标记完成。"
        case MockAgentIntent.deleteReminder.rawValue:
            return "我先核对一下你要删除的是哪条任务。"
        default:
            return result.reply
        }
    }

    private func confirmationAssistantReply(for result: MockAgentResult) -> String {
        switch result.actionType {
        case MockAgentIntent.deleteReminder.rawValue:
            return "我已经找到要删除的任务。按你的规则，需要你在卡片上确认后我才会删除。"
        default:
            return "这个操作需要你确认。确认后我再执行。"
        }
    }

    private func actionRequiresConfirmation(_ result: MockAgentResult) -> Bool {
        guard result.actionType == MockAgentIntent.deleteReminder.rawValue else { return false }
        if decodePayload(from: result.payloadJSON)?.action.requiresConfirmation == true {
            return true
        }
        return AgentUserMemoryStore.shared.items().contains { item in
            guard item.category == .transactionRule else { return false }
            let rule = item.value.lowercased()
            let mentionsDeletion = rule.contains("删除") || rule.contains("删") || rule.contains("delete")
            let requiresConfirmation = rule.contains("确认") || rule.contains("confirm")
            return mentionsDeletion && requiresConfirmation
        }
    }

    private func isExplicitMemorySaveCommand(_ content: String) -> Bool {
        let normalized = content.lowercased()
        return ["记住", "请保存", "保存为长期偏好", "remember", "please remember"].contains {
            normalized.contains($0)
        }
    }

    private func createReminderSuccessReply(
        title: String,
        dueDate: Date?,
        listName: String?
    ) -> String {
        var lines: [String] = ["好，已经记上了：\(title)。"]

        if let dueDate {
            let dueLabel: String
            let calendar = Calendar.current
            if calendar.isDateInToday(dueDate) {
                dueLabel = "今天"
            } else if calendar.isDateInTomorrow(dueDate) {
                dueLabel = "明天"
            } else {
                dueLabel = dueDate.formatted(date: .abbreviated, time: .omitted)
            }
            lines.append("时间我放到\(dueLabel)了。")
        }

        if let listName, listName.isEmpty == false {
            lines.append("我先放在“\(listName)”里。")
        }

        return lines.joined(separator: "\n")
    }

    private var chatBackground: some View {
        LinearGradient(
            colors: [
                AIGTDColor.background,
                AIGTDColor.brand.opacity(0.055)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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

enum AgentActionCardStatusCopy {
    static func title(for executionStatus: String) -> String {
        switch executionStatus {
        case "awaiting_confirmation": return "准备好了"
        case "cancelled": return "已取消"
        case "success": return "处理好了"
        case "partial": return "部分处理好了"
        case "failed": return "没有处理完"
        case "undone": return "已恢复"
        case "undo_conflict": return "没有覆盖外部修改"
        case "undo_partial": return "部分恢复"
        case "undo_failed": return "未能恢复"
        default: return "正在处理"
        }
    }

    static func subtitle(for executionStatus: String, errorMessage: String) -> String {
        switch executionStatus {
        case "awaiting_confirmation": return "确认后才会执行这些修改"
        case "cancelled": return "这份方案不会再执行"
        case "partial": return "部分操作已完成，未成功的项目不会显示成已完成"
        case "failed": return errorMessage.nonEmpty ?? "这次操作没有执行成功"
        case "pending": return "正在按确认过的计划逐项执行"
        case "undone": return "已经恢复到这次操作之前的状态"
        case "undo_conflict": return "任务已发生变化，没有覆盖外部修改"
        case "undo_partial": return "部分操作已恢复，其余项目保持当前状态"
        case "undo_failed": return errorMessage.nonEmpty ?? "这次操作暂时无法恢复"
        default: return "执行结果已按真实工具返回更新"
        }
    }
}

private struct ActionResultCardView: View {
    let log: ActionLog
    let onPrimaryAction: () -> Void
    let onAdjustAction: () -> Void
    let onCancelAction: () -> Void

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
                HStack(spacing: 10) {
                    Button(primaryActionTitle, action: onPrimaryAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(log.executionStatus == "pending")

                    if showsPendingPlanActions {
                        Button("调整", action: onAdjustAction)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("取消", action: onCancelAction)
                            .buttonStyle(.plain)
                            .controlSize(.small)
                            .foregroundStyle(.secondary)
                    }
                }
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
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.24), value: log.executionStatus)
    }

    private var title: String {
        switch log.actionType {
        case "create_reminder":
            return log.executionStatus == "success" ? "记好了" : "正在记"
        case "update_reminder":
            return log.executionStatus == "success" ? "时间改好了" : "正在改时间"
        case "create_list":
            return log.executionStatus == "success" ? "清单建好了" : "正在建清单"
        case "plan_reschedule":
            switch (reschedulePhase, log.executionStatus) {
            case ("apply", "success"):
                return "排好了"
            case ("apply", "partial"):
                return "部分排好了"
            case ("apply", "failed"):
                return "没排成"
            case ("apply", _):
                return "正在重排"
            default:
                return "排了个方案"
            }
        case "summarize_lists":
            return "我看过了"
        case "capture_message":
            return "我先接住了"
        case "move_reminder":
            return log.executionStatus == "success" ? "改好了" : "正在改"
        case "complete_reminder":
            return log.executionStatus == "success" ? "完成了" : "正在完成"
        case "delete_reminder":
            switch log.executionStatus {
            case "success":
                return "删掉了"
            case "awaiting_confirmation":
                return "需要确认"
            case "needs_clarification":
                return "需要确认"
            case "failed":
                return "删除失败"
            default:
                return "正在核对"
            }
        case "agent_run":
            return AgentActionCardStatusCopy.title(for: log.executionStatus)
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
        case "update_reminder":
            switch log.executionStatus {
            case "pending":
                return "我在帮你修改任务时间"
            case "failed":
                return log.errorMessage.nonEmpty ?? "任务时间暂时还没修改成功"
            default:
                return "新的时间已经写进提醒事项了"
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
        case "plan_reschedule":
            switch (reschedulePhase, log.executionStatus) {
            case ("apply", "pending"):
                return "我在按确认过的方案改任务时间"
            case ("apply", "partial"):
                return rescheduleResultSubtitle ?? "部分任务已改好，另一些没有改成"
            case ("apply", "failed"):
                return rescheduleResultSubtitle ?? "这份重排方案暂时还没应用成功"
            case ("apply", "success"):
                return rescheduleResultSubtitle ?? "这份方案已经写进提醒事项了"
            case ("apply", _):
                return "我在核对这份方案的执行结果"
            default:
                return "先看看这份安排合不合适，再决定要不要应用"
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
        case "delete_reminder":
            switch log.executionStatus {
            case "awaiting_confirmation":
                return "确认后才会从提醒事项中删除"
            case "pending":
                return "我在核对具体要删除哪一条"
            case "needs_clarification":
                return log.errorMessage.nonEmpty ?? "找到了多个同名任务，请说得更具体一点"
            case "failed":
                return log.errorMessage.nonEmpty ?? "任务暂时还没删除成功"
            default:
                return "这条已经从提醒事项里删掉了"
            }
        case "agent_run":
            return AgentActionCardStatusCopy.subtitle(
                for: log.executionStatus,
                errorMessage: log.errorMessage
            )
        default:
            return "这次我已经处理好了"
        }
    }

    private var iconName: String {
        switch log.actionType {
        case "create_reminder":
            return "checklist.checked"
        case "update_reminder":
            return "calendar.badge.clock"
        case "create_list":
            return "folder.badge.plus"
        case "plan_reschedule":
            return reschedulePhase == "apply" ? "calendar.badge.clock" : "calendar.day.timeline.leading"
        case "summarize_lists":
            return "text.alignleft"
        case "capture_message":
            return "tray.and.arrow.down"
        case "move_reminder":
            return "arrow.right.circle"
        case "complete_reminder":
            return "checkmark.circle"
        case "delete_reminder":
            return "trash"
        case "agent_run":
            return "wand.and.sparkles.inverse"
        default:
            return "checkmark.circle.fill"
        }
    }

    private var cardAccent: Color {
        switch log.actionType {
        case "create_reminder":
            return .blue
        case "update_reminder":
            return .indigo
        case "create_list":
            return .blue
        case "plan_reschedule":
            return .purple
        case "summarize_lists":
            return .teal
        case "capture_message":
            return .orange
        case "move_reminder":
            return .indigo
        case "complete_reminder":
            return .green
        case "delete_reminder":
            return .red
        case "agent_run":
            return .blue
        default:
            return .green
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        let style = statusStyle
        HStack(spacing: 6) {
            if log.executionStatus == "pending" {
                ProgressView()
                    .controlSize(.mini)
                    .tint(style.foreground)
            }

            Text(style.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(style.foreground)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(style.background)
        )
    }

    private var payloadLines: [String] {
        if log.actionType == "agent_run" {
            return structuredPayloadLines
        }
        guard let payload = parsePayloadEnvelope() else { return [] }

        var lines: [String] = []

        switch log.actionType {
        case "create_reminder":
            if let title = payload.action.entities["title"]?.nonEmpty {
                lines.append("任务：\(title)")
            }
            if let dueDate = payload.action.entities["due_date"]?.nonEmpty {
                let hasTime = payload.action.entities["due_date_has_time"] != "false"
                let formatted = hasTime
                    ? formattedDueDate(from: dueDate)
                    : formattedDueDateOnly(from: dueDate)
                lines.append("时间：\(formatted ?? dueDate)")
            }
            if let listName = payload.action.entities["preferred_list_name"]?.nonEmpty {
                lines.append("清单：\(listName)")
            }
            if let note = payload.action.entities["note"]?.nonEmpty {
                lines.append("备注：\(note)")
            }
        case "update_reminder":
            if let target = payload.action.entities["target"]?.nonEmpty {
                lines.append("任务：\(target)")
            }
            if let dueDate = payload.action.entities["due_date"]?.nonEmpty {
                lines.append("新时间：\(formattedDueDate(from: dueDate) ?? dueDate)")
            }
        case "create_list":
            if let name = payload.action.entities["list_name"]?.nonEmpty {
                lines.append("清单：\(name)")
            }
        case "plan_reschedule":
            if let plan = parsedReschedulePlan {
                lines.append("范围：\(plan.scopeLabel)")
                lines.append("任务：共 \(plan.items.count) 条")
                if reschedulePhase == "apply", let report = parsedRescheduleExecutionReport {
                    lines.append("结果：成功 \(report.successCount) 条，失败 \(report.failureCount) 条")
                    for item in report.failedItems.prefix(3) {
                        lines.append("失败：\(item.title)")
                    }
                    if report.failureCount > 3 {
                        lines.append("另外还有 \(report.failureCount - 3) 条失败任务。")
                    }
                    if report.refreshErrorMessage != nil {
                        lines.append("提醒事项已写入，但列表刷新失败，请稍后重新同步。")
                    }
                } else {
                    for item in plan.items.prefix(6) {
                        let dueLabel = formattedDueDate(from: item.dueDateISO8601) ?? item.dueDateISO8601
                        lines.append("\(item.title) -> \(dueLabel)")
                    }
                    if plan.items.count > 6 {
                        lines.append("另外还有 \(plan.items.count - 6) 条，已经一起排进方案里了。")
                    }
                }
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
        case "delete_reminder":
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
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return "今天 \(time)"
        }
        if calendar.isDateInTomorrow(date) {
            return "明天 \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func formattedDueDateOnly(from value: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: value) else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天"
        }
        if calendar.isDateInTomorrow(date) {
            return "明天"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
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
        if log.actionType == MockAgentIntent.planReschedule.rawValue,
           reschedulePhase == "plan",
           log.executionStatus == "success" {
            return ("待确认", .purple, Color.purple.opacity(0.12))
        }
        switch log.executionStatus {
        case "success":
            return ("已办好", cardAccent, cardAccent.opacity(0.12))
        case "partial":
            return ("部分完成", .orange, Color.orange.opacity(0.12))
        case "pending":
            return ("在处理", .orange, Color.orange.opacity(0.12))
        case "awaiting_confirmation":
            return ("待确认", .orange, Color.orange.opacity(0.12))
        case "cancelled":
            return ("已取消", .secondary, Color.secondary.opacity(0.12))
        case "failed":
            return ("没成", .red, Color.red.opacity(0.12))
        case "undone":
            return ("已恢复", .green, Color.green.opacity(0.12))
        case "undo_conflict":
            return ("有变化", .orange, Color.orange.opacity(0.12))
        case "undo_partial":
            return ("部分恢复", .orange, Color.orange.opacity(0.12))
        case "undo_failed":
            return ("未恢复", .red, Color.red.opacity(0.12))
        case "needs_clarification":
            return ("待确认", .orange, Color.orange.opacity(0.12))
        default:
            return ("已接住", .secondary, Color.secondary.opacity(0.12))
        }
    }

    private var primaryActionTitle: String? {
        switch log.actionType {
        case "create_reminder", "update_reminder", "create_list", "summarize_lists":
            return "去看清单"
        case "delete_reminder":
            if log.executionStatus == "awaiting_confirmation" {
                return "确认删除"
            }
            return log.executionStatus == "needs_clarification" ? "继续说明" : "去看清单"
        case "plan_reschedule":
            if reschedulePhase == "plan" {
                return "应用这个方案"
            }
            switch log.executionStatus {
            case "pending":
                return "正在应用"
            case "success":
                return "去看清单"
            case "partial":
                return "查看结果"
            default:
                return "继续编辑"
            }
        case "capture_message", "move_reminder", "complete_reminder":
            return "继续编辑"
        case "agent_run":
            if log.executionStatus == "awaiting_confirmation" {
                return "执行这个计划"
            }
            if let presentation = structuredPresentation,
               AgentRecoveryPlanner().makePlan(from: presentation.result.toolResults)
                .hasRetryableFailures {
                return "重试失败项"
            }
            if let presentation = structuredPresentation,
               AgentUndoRecordStore.shared.record(
                forwardRunID: presentation.result.runID
               )?.status == .available {
                return "撤销"
            }
            return ["success", "partial"].contains(log.executionStatus) ? "去看清单" : nil
        default:
            return nil
        }
    }

    private var showsPendingPlanActions: Bool {
        log.actionType == "agent_run" && log.executionStatus == "awaiting_confirmation"
    }

    private func parsePayloadEnvelope() -> MockAgentEnvelope? {
        guard let data = log.payloadJSON.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(MockAgentEnvelope.self, from: data) else {
            return nil
        }
        return envelope
    }

    private var structuredPresentation: AgentConversationPresentation? {
        guard log.actionType == "agent_run",
              let data = log.payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentConversationPresentation.self, from: data)
    }

    private var structuredPayloadLines: [String] {
        guard let presentation = structuredPresentation else { return [] }
        let result = presentation.result
        var lines = ["目标：\(result.goal)"]
        let visiblePendingCalls = result.pendingToolCalls.filter {
            isStructuredUserVisibleTool($0.tool)
        }
        let visibleResults = result.toolResults.filter {
            isStructuredUserVisibleTool($0.tool)
        }
        lines.append(contentsOf: scheduleProposalLines(from: result.toolResults))
        if visiblePendingCalls.isEmpty == false {
            lines.append(contentsOf: visiblePendingCalls.enumerated().map { index, call in
                "操作 \(index + 1)：\(toolLabel(call.tool))（待确认）"
            })
        } else {
            lines.append(contentsOf: visibleResults.enumerated().map { index, toolResult in
                "结果 \(index + 1)：\(toolLabel(toolResult.tool))（\(toolStatusLabel(toolResult))）"
            })
        }
        return lines
    }

    private func scheduleProposalLines(from results: [AgentToolResult]) -> [String] {
        let execution = results.last(where: { $0.tool == .applySchedule })
        let source = execution ?? results.last(where: { $0.tool == .proposeSchedule })
        guard let source,
              case let .array(items)? = source.result?["items"] else {
            return []
        }
        return items.prefix(8).compactMap { value in
            guard case let .object(item) = value,
                  case let .string(target)? = item["target_due_date"] else {
                return nil
            }
            let label: String
            if case let .string(title)? = item["title"], title.nonEmpty != nil {
                label = title
            } else if case let .string(itemID)? = item["item_id"] {
                label = itemID
            } else {
                label = "任务"
            }
            var line = "\(label) -> \(formattedDueDate(from: target) ?? target)"
            if execution != nil, case let .string(status)? = item["status"] {
                let outcome: String = switch status {
                case "applied": "成功"
                case "unchanged": "无需修改"
                case "failed": "失败"
                case "skipped": "已跳过"
                case "cancelled": "已取消"
                default: "处理中"
                }
                line += "（\(outcome)）"
                if case let .string(message)? = item["error_message"], message.nonEmpty != nil {
                    line += "：\(message)"
                }
            }
            return line
        }
    }

    private func isStructuredUserVisibleTool(_ tool: AgentToolName) -> Bool {
        tool != .searchReminders && tool != .getReminderDetails
    }

    private func toolStatusLabel(_ result: AgentToolResult) -> String {
        if result.tool == .applySchedule,
           case let .string(planStatus)? = result.result?["plan_status"],
           planStatus == "partial" {
            return "部分完成"
        }
        switch result.status {
        case .success: return "成功"
        case .unchanged: return "无需修改"
        case .alreadyApplied: return "已执行过"
        case .skipped: return "已跳过"
        case .cancelled: return "已取消"
        case .timedOut: return "超时"
        case .failed: return result.error?.userVisibleMessage.nonEmpty ?? "失败"
        default: return "处理中"
        }
    }

    private func toolLabel(_ tool: AgentToolName) -> String {
        switch tool {
        case .createReminder: "新建任务"
        case .createList: "新建清单"
        case .updateReminder: "修改任务"
        case .moveReminder: "移动任务"
        case .completeReminder: "完成任务"
        case .deleteReminder: "删除任务"
        case .applySchedule: "应用排期"
        case .proposeSchedule: "生成排期"
        case .searchReminders: "查询任务"
        case .getReminderDetails: "读取详情"
        default: tool.rawValue
        }
    }

    private var reschedulePhase: String {
        parsePayloadEnvelope()?.action.entities["phase"]?.nonEmpty ?? "plan"
    }

    private var parsedReschedulePlan: ReschedulePlan? {
        guard let payload = parsePayloadEnvelope(),
              let value = payload.action.entities["plan_json"]?.nonEmpty,
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ReschedulePlan.self, from: data)
    }

    private var parsedRescheduleExecutionReport: ReminderBatchExecutionReport? {
        guard let payload = parsePayloadEnvelope(),
              let value = payload.action.entities["execution_result_json"]?.nonEmpty,
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ReminderBatchExecutionReport.self, from: data)
    }

    private var rescheduleResultSubtitle: String? {
        guard let report = parsedRescheduleExecutionReport else { return nil }
        if report.refreshErrorMessage != nil {
            return "共 \(report.totalCount) 条，成功 \(report.successCount) 条，失败 \(report.failureCount) 条；列表刷新失败"
        }
        return "共 \(report.totalCount) 条，成功 \(report.successCount) 条，失败 \(report.failureCount) 条"
    }
}

private struct ChatIntroCard: View {
    let isUsingRemoteModel: Bool
    let runtimeNotice: RuntimeNotice?

    var body: some View {
#if DEBUG || INTERNAL
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
#else
        if let runtimeNotice, runtimeNotice.tone.shouldShowPublicly {
            Label(runtimeNotice.publicText, systemImage: runtimeNotice.tone.iconName)
                .font(.footnote)
                .foregroundStyle(runtimeNotice.tone.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .textSelection(.enabled)
        }
#endif
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
    let streamingText: String?
    let actionLog: ActionLog?
    let onPrimaryAction: (ActionLog) -> Void
    let onAdjustAction: (ActionLog) -> Void
    let onCancelAction: (ActionLog) -> Void
    @State private var showsCopiedToast = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if isUserMessage {
                Spacer(minLength: 42)
            } else {
                avatar
            }

            VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 6) {
                Text(isUserMessage ? "你" : "小满")
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
                    Text(renderedText)
                        .font(.body)
                        .foregroundStyle(isUserMessage ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(bubbleBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .textSelection(.enabled)
                        .contextMenu {
                            Button("复制这条消息") {
                                UIPasteboard.general.string = renderedText
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
                        onPrimaryAction: { onPrimaryAction(actionLog) },
                        onAdjustAction: { onAdjustAction(actionLog) },
                        onCancelAction: { onCancelAction(actionLog) }
                    )
                    .id(actionLog.id)
                    .transition(.opacity)
                    .contentTransition(.interpolate)
                    .padding(.top, 2)
                    .animation(.smooth(duration: 0.22), value: actionLog.executionStatus)
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

    private var renderedText: String {
        streamingText ?? message.text
    }

    private var shouldShowActionSummary: Bool {
        guard let actionLog else { return false }
        return shouldShowActionCard(for: actionLog)
    }

    private var shouldShowStreamingPlaceholder: Bool {
        isUserMessage == false &&
        message.status == "streaming" &&
        renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func shouldShowActionCard(for log: ActionLog) -> Bool {
        switch log.actionType {
        case MockAgentIntent.createReminder.rawValue,
             MockAgentIntent.updateReminder.rawValue,
             MockAgentIntent.createList.rawValue,
             MockAgentIntent.planReschedule.rawValue,
             MockAgentIntent.moveReminder.rawValue,
             MockAgentIntent.completeReminder.rawValue,
             MockAgentIntent.deleteReminder.rawValue,
             "agent_run":
            return true
        default:
            return false
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(isUserMessage ? AIGTDColor.brand.opacity(0.16) : AIGTDColor.assistantAccent.opacity(0.18))
            Text(isUserMessage ? "你" : "满")
                .font(.caption.bold())
                .foregroundStyle(isUserMessage ? AIGTDColor.brand : AIGTDColor.assistantAccent)
        }
        .frame(width: 32, height: 32)
    }

    private var bubbleBackground: some View {
        Group {
            if isUserMessage {
                LinearGradient(
                    colors: [
                        Color.accentColor,
                        AIGTDColor.brand.opacity(0.78)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                LinearGradient(
                    colors: [
                        AIGTDColor.surface.opacity(0.98),
                        AIGTDColor.raisedSurface.opacity(0.96)
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
    @ObservedObject var voiceState: VoiceInteractionState
    let voiceConfiguration: VoiceTranscriptionConfiguration?
    @Binding var inputMode: ChatComposerInputMode
    @Binding var focusRequestID: UUID
    @Binding var isFocused: Bool
    @ObservedObject var focusBridge: ComposerTextViewFocusBridge
    let onSend: () -> Void
    let onVoiceUnavailable: () -> Void
    @State private var composerHeight: CGFloat = 44
    private let composerHorizontalPadding: CGFloat = 12
    private let composerVerticalPadding: CGFloat = 0
    private let textContainerInset = UIEdgeInsets(top: 13, left: 4, bottom: 13, right: 8)

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            switch inputMode {
            case .text:
                textComposerField

                if trimmedDraft.isEmpty == false {
                    ComposerAccessoryButton(
                        mode: .send,
                        isDisabled: isSending || isStreamingReply,
                        onTap: onSend
                    )
                    .frame(width: 44, height: 44)
                    .transition(.scale.combined(with: .opacity))
                }
            case .voice:
                voiceComposerField
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .animation(.easeOut(duration: 0.16), value: trimmedDraft.isEmpty)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var textComposerField: some View {
        HStack(alignment: .bottom, spacing: 2) {
            microphoneButton

            ZStack(alignment: .topLeading) {
                GrowingComposerTextView(
                    text: $draft,
                    focusRequestID: $focusRequestID,
                    isFocused: $isFocused,
                    focusBridge: focusBridge,
                    measuredHeight: $composerHeight,
                    tailHighlightLength: 0,
                    tailAnimatedDotsCount: 0,
                    textContainerInset: textContainerInset,
                    shouldHideCaret: false,
                    isEditable: true,
                    isVoiceInputActive: false,
                    onVoiceInputTakeoverByKeyboard: {}
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.trailing, composerHorizontalPadding)
                .padding(.vertical, composerVerticalPadding)

                if trimmedDraft.isEmpty {
                    Text(isFocused ? VoiceInteractionState.focusedComposerPrompt : VoiceInteractionState.composerPrompt)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.leading, textContainerInset.left)
                        .padding(.top, textContainerInset.top)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.leading, 4)
        .frame(height: max(44, composerHeight))
        .background(AIGTDColor.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.black.opacity(0.035))
        }
        .animation(.easeOut(duration: 0.14), value: composerHeight)
        .contentShape(Rectangle())
        .voiceHoldToTalk(
            state: voiceState,
            configuration: voiceConfiguration,
            draft: $draft,
            isEnabled: trimmedDraft.isEmpty,
            onUnavailable: onVoiceUnavailable
        )
    }

    private var voiceComposerField: some View {
        HStack(spacing: 2) {
            keyboardButton

            ZStack {
                Color.clear

                Text("按住 说话")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .voiceHoldToTalk(
                    state: voiceState,
                    configuration: voiceConfiguration,
                    draft: $draft,
                    onUnavailable: onVoiceUnavailable
                )
                .accessibilityLabel("按住说话")
                .accessibilityHint("按住开始录音，松手后文字进入输入框")
        }
        .padding(.leading, 4)
        .frame(height: 44)
        .background(AIGTDColor.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.black.opacity(0.035))
        }
    }

    private var microphoneButton: some View {
        Button {
            inputMode = .voice
            isFocused = false
            focusBridge.blur()
        } label: {
            Image(systemName: "waveform.circle")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSending || voiceState.phase == .finalizing)
        .accessibilityLabel("切换到语音输入")
        .accessibilityHint("显示按住说话按钮")
    }

    private var keyboardButton: some View {
        Button {
            inputMode = .text
            isFocused = true
            focusRequestID = UUID()
            Task { @MainActor in
                await Task.yield()
                focusBridge.focus()
            }
        } label: {
            Image(systemName: "keyboard")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSending || voiceState.phase == .finalizing)
        .accessibilityLabel("切换到键盘输入")
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
        textView.returnKeyType = .default
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
        context.coordinator.scheduleHeightUpdate(for: textView)
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
            context.coordinator.scheduleHeightUpdate(for: uiView)
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
        private let onVoiceInputTakeoverByKeyboard: () -> Void
        var isVoiceInputActive = false
        private var lastFocusRequestID = UUID()
        private var lastRenderedDisplayText = ""
        private var isApplyingDisplayUpdate = false
        private var lastKnownWidth: CGFloat = 0
        private var hasPendingVoiceTakeoverDotCleanup = false
        private var heightUpdateScheduled = false

        init(
            text: Binding<String>,
            measuredHeight: Binding<CGFloat>,
            isFocused: Binding<Bool>,
            minHeight: CGFloat,
            maxHeight: CGFloat,
            onVoiceInputTakeoverByKeyboard: @escaping () -> Void
        ) {
            _text = text
            _measuredHeight = measuredHeight
            _isFocused = isFocused
            self.minHeight = minHeight
            self.maxHeight = maxHeight
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
                scheduleHeightUpdate(for: textView)
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
            scheduleHeightUpdate(for: textView)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
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
            textView.invalidateIntrinsicContentSize()
            textView.setNeedsLayout()

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

        func scheduleHeightUpdate(for textView: UITextView) {
            guard heightUpdateScheduled == false else { return }
            heightUpdateScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.heightUpdateScheduled = false
                guard let textView else { return }
                self.recalculateHeight(for: textView)
            }
        }

        private func recalculateHeight(for textView: UITextView) {
            _ = noteBoundsChange(for: textView)
            let targetWidth = max(textView.bounds.width, lastKnownWidth)
            guard targetWidth > 1 else { return }

            syncTextContainerWidth(for: textView)
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            let usedRect = textView.layoutManager.usedRect(for: textView.textContainer)
            let rawHeight = ceil(usedRect.height + textView.textContainerInset.top + textView.textContainerInset.bottom)
            let clamped = min(max(minHeight, rawHeight), maxHeight)

            if abs(measuredHeight - clamped) > 0.5 {
                measuredHeight = clamped
            }

            let shouldScroll = rawHeight > maxHeight + 0.5
            if textView.isScrollEnabled != shouldScroll {
                textView.isScrollEnabled = shouldScroll
            }
            if shouldScroll {
                scrollToBottomAligned(for: textView)
            } else if textView.contentOffset.y != 0 {
                textView.setContentOffset(.zero, animated: false)
            }
        }

        func applyFocusIfNeeded(for textView: UITextView, requestID: UUID) {
            guard requestID != lastFocusRequestID, textView.window != nil else { return }
            lastFocusRequestID = requestID
            if textView.isFirstResponder == false {
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

private struct ComposerAccessoryButton: View {
    enum Mode {
        case voice
        case stop
        case send
    }

    let mode: Mode
    let isDisabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(backgroundColor)

                if mode == .stop {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                } else if mode == .send {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
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
        switch mode {
        case .voice:
            return Color.orange.opacity(0.92)
        case .stop:
            return Color.blue.opacity(0.92)
        case .send:
            return Color.blue.opacity(0.92)
        }
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

    var publicText: String {
        if text.localizedCaseInsensitiveContains("模型") ||
            text.localizedCaseInsensitiveContains("API") {
            return "小满暂时没有连接好，请稍后再试。"
        }
        return text
    }
}

private enum RuntimeNoticeTone {
    case info
    case success
    case warning

    var shouldShowPublicly: Bool {
        self == .warning
    }

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
