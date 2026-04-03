import SwiftData
import SwiftUI

struct ChatHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]
    @Query(sort: \ChatMessage.createdAt) private var messages: [ChatMessage]
    @Query(sort: \ActionLog.createdAt) private var actionLogs: [ActionLog]
    @Query(sort: \ModelProfile.displayName) private var modelProfiles: [ModelProfile]
    @State private var draft = ""
    @State private var isSending = false
    @State private var runtimeNotice: RuntimeNotice?
    @State private var modelSetupPrompt: ModelSetupPrompt?
    @State private var hasSeenModelSetupPrompt = false
    @FocusState private var isComposerFocused: Bool
    private let agentRuntime = AgentRuntimeService()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ChatIntroCard(
                            modelName: activeModelDisplayName,
                            isUsingRemoteModel: activeModelConfiguration != nil,
                            runtimeNotice: runtimeNotice
                        )

                        if activeMessages.isEmpty {
                            StarterPromptsCard { prompt in
                                Task {
                                    await sendPrompt(prompt)
                                }
                            }
                        } else {
                            ForEach(activeMessages, id: \.id) { message in
                                ChatMessageRow(
                                    message: message,
                                    actionLog: latestActionLog(for: message),
                                    onPrimaryAction: handleCardPrimaryAction
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .background(chatBackground)
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .onTapGesture {
                    isComposerFocused = false
                }
                .onAppear {
                    scrollToLatestMessage(using: proxy, animated: false)
                }
                .onChange(of: activeMessages.count) { _, _ in
                    scrollToLatestMessage(using: proxy, animated: true)
                }
                .onChange(of: appModel.selectedTab) { _, newValue in
                    guard newValue == .chat else { return }
                    scrollToLatestMessage(using: proxy, animated: false)
                }
            }

            ChatComposer(
                draft: $draft,
                isSending: isSending,
                isFocused: $isComposerFocused,
                onSend: {
                    Task {
                        await sendDraft()
                    }
                }
            )
        }
        .navigationTitle(activeSession?.title ?? "Chat")
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
                onUseLocalMode: {
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
    }

    private var activeSession: ChatSession? {
        sessions.first
    }

    private var activeMessages: [ChatMessage] {
        guard let activeSession else { return [] }
        return messages.filter { $0.sessionID == activeSession.id }
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

    private var activeModelDisplayName: String {
        guard let profile = modelProfiles.first(where: \.isActive) else {
            return "本地规则"
        }
        return profile.modelID.nonEmpty ?? profile.displayName
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
            runtimeNotice = RuntimeNotice(
                text: "第一次发送前，先确认一下是否要配置模型。你也可以先用本地规则试试。",
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

        let result = await agentRuntime.respond(
            to: content,
            reminderLists: appModel.reminderLists,
            configuration: activeModelConfiguration
        )
        updateRuntimeNotice(using: result)
        let assistantMessage = ChatMessage(
            sessionID: session.id,
            role: "assistant",
            text: result.reply,
            actionResultSummary: result.summary
        )
        modelContext.insert(assistantMessage)
        var createdLogID: UUID?
        if let actionType = result.actionType {
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
                payloadJSON: result.payloadJSON,
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
        if session.title == "Main Session" || session.title == "主会话" {
            session.title = content.count > 12 ? String(content.prefix(12)) + "…" : content
        }

        try? modelContext.save()

        if let createdLogID {
            await executeResultAction(logID: createdLogID, result: result)
        }
    }

    private func sendWithoutPrompt(_ content: String, clearDraft: Bool) async {
        guard isSending == false else { return }
        isSending = true
        defer { isSending = false }
        await sendPrompt(content)
        if clearDraft {
            draft = ""
        }
    }

    private func latestActionLog(for message: ChatMessage) -> ActionLog? {
        actionLogs
            .filter { $0.messageID == message.id }
            .sorted { $0.createdAt > $1.createdAt }
            .first
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

    private func scrollToLatestMessage(using proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = activeMessages.last?.id else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
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
            }
        }
    }

    private func updateRuntimeNotice(using result: MockAgentResult) {
        if result.summary.contains("远端调用失败，已回退本地规则") {
            runtimeNotice = RuntimeNotice(
                text: "远端模型暂时不可用，这次已自动回退到本地规则。",
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
                text: "当前回复来自本地规则。",
                tone: .info
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
}

private struct ModelSetupPrompt: Identifiable {
    let id = UUID()
    let pendingDraft: String
}

private struct ModelSetupPromptSheet: View {
    let pendingDraft: String
    let onGoToSettings: () -> Void
    let onUseLocalMode: () -> Void
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

                Text("你已经输入了一条消息。现在去设置模型 API，可以获得完整的 AI 理解能力；如果你只是想先体验一下，也可以先用本地规则继续。")
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

                Button("先用本地模式发送", action: onUseLocalMode)
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

            if let executedAt = log.executedAt {
                Text("执行于 \(executedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
            return log.executionStatus == "success" ? "已创建任务" : "任务创建中"
        case "create_list":
            return log.executionStatus == "success" ? "已创建列表" : "列表创建中"
        case "summarize_lists":
            return "已生成列表摘要"
        case "capture_message":
            return "已记录输入"
        case "move_reminder":
            return log.executionStatus == "success" ? "已移动任务" : "任务移动中"
        case "complete_reminder":
            return log.executionStatus == "success" ? "已完成任务" : "任务完成中"
        default:
            return "已完成动作"
        }
    }

    private var subtitle: String {
        switch log.actionType {
        case "create_reminder":
            switch log.executionStatus {
            case "pending":
                return "正在把这条任务写入你的提醒事项"
            case "failed":
                return log.errorMessage.nonEmpty ?? "任务暂时还没创建成功"
            default:
                return "新的任务已经进入你的提醒事项"
            }
        case "create_list":
            switch log.executionStatus {
            case "pending":
                return "正在把新列表写入你的提醒事项"
            case "failed":
                return log.errorMessage.nonEmpty ?? "新列表暂时还没创建成功"
            default:
                return "新的列表已经进入你的提醒事项"
            }
        case "summarize_lists":
            return "当前提醒事项状态已整理完毕"
        case "capture_message":
            return "这条输入已经被本地保存"
        case "move_reminder":
            switch log.executionStatus {
            case "pending":
                return "正在把这条任务移动到目标列表"
            case "failed":
                return log.errorMessage.nonEmpty ?? "任务暂时还没移动成功"
            default:
                return "任务已经移动到目标列表"
            }
        case "complete_reminder":
            switch log.executionStatus {
            case "pending":
                return "正在把这条任务标记完成"
            case "failed":
                return log.errorMessage.nonEmpty ?? "任务暂时还没完成成功"
            default:
                return "任务已经标记为完成"
            }
        default:
            return "系统已处理这次操作"
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

        var lines: [String] = [
            "意图：\(payload.action.title)",
            "置信度：\(Int(payload.confidence * 100))%"
        ]

        switch log.actionType {
        case "create_reminder":
            if let title = payload.action.entities["title"]?.nonEmpty {
                lines.append("任务标题：\(title)")
            }
            if let dueDate = payload.action.entities["due_date"]?.nonEmpty {
                lines.append("提醒时间：\(dueDate)")
            }
            if let listName = payload.action.entities["preferred_list_name"]?.nonEmpty {
                lines.append("目标清单：\(listName)")
            }
            if let category = payload.action.entities["category"]?.nonEmpty {
                lines.append("分类判断：\(category)")
            }
            if let bucket = payload.action.entities["bucket"]?.nonEmpty {
                lines.append("时间桶：\(bucket)")
            }
            if let note = payload.action.entities["note"]?.nonEmpty {
                lines.append("备注：\(note)")
            }
            if let tags = payload.action.entities["tags"]?.nonEmpty {
                lines.append("标签：\(tags)")
            }
            if let matchedRule = payload.action.entities["matched_rule_id"]?.nonEmpty {
                lines.append("映射规则：\(matchedRule)")
            }
        case "create_list":
            if let name = payload.action.entities["list_name"]?.nonEmpty {
                lines.append("列表名称：\(name)")
            }
        case "summarize_lists":
            if let count = payload.action.entities["list_count"]?.nonEmpty {
                lines.append("列表数量：\(count)")
            }
        case "capture_message":
            if let text = payload.action.entities["text"]?.nonEmpty {
                lines.append("原始输入：\(text)")
            }
        case "move_reminder":
            if let target = payload.action.entities["target"]?.nonEmpty {
                lines.append("目标任务：\(target)")
            }
            if let destination = payload.action.entities["destination_list"]?.nonEmpty {
                lines.append("目标列表：\(destination)")
            }
        case "complete_reminder":
            if let target = payload.action.entities["target"]?.nonEmpty {
                lines.append("完成对象：\(target)")
            }
        default:
            break
        }

        if let followUp = payload.followUpPrompt?.nonEmpty {
            lines.append("后续建议：\(followUp)")
        }

        return lines
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
            return ("完成", cardAccent, cardAccent.opacity(0.12))
        case "pending":
            return ("处理中", .orange, Color.orange.opacity(0.12))
        case "failed":
            return ("失败", .red, Color.red.opacity(0.12))
        default:
            return ("已记录", .secondary, Color.secondary.opacity(0.12))
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
    let modelName: String
    let isUsingRemoteModel: Bool
    let runtimeNotice: RuntimeNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(
                    isUsingRemoteModel ? "已连接模型" : "本地模式",
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

                Text(modelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text("现在可以开始和 AIGTD 对话了。")
                .font(.headline)
            Text("这一版已经接上本地会话、结构化 mock agent 和提醒事项动作回执。你可以像平时一样直接说需求。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let runtimeNotice {
                Label(runtimeNotice.text, systemImage: runtimeNotice.tone.iconName)
                    .font(.footnote)
                    .foregroundStyle(runtimeNotice.tone.color)
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
        "明天提醒我给张闯回信",
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

                Text(message.text)
                    .font(.body)
                    .foregroundStyle(isUserMessage ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if message.actionResultSummary.isEmpty == false {
                    Text(message.actionResultSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let actionLog {
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
    }

    private var isUserMessage: Bool {
        message.role == "user"
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
    @FocusState.Binding var isFocused: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("直接告诉我你要做什么", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit {
                    onSend()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.92))
                )
                .lineLimit(1...5)
                .disabled(isSending)

            Button(action: onSend) {
                Group {
                    if isSending {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending ? Color.gray.opacity(0.45) : Color.accentColor)
                )
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
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
