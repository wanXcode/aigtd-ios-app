import SwiftData
import SwiftUI
import EventKit
import AVFoundation
import UIKit

struct AgentHomeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query(sort: \AgentDocument.updatedAt, order: .forward) private var documents: [AgentDocument]
    @State private var showsModelSettings = false
    @State private var selectedDocumentID: UUID?
    @State private var microphonePermission = AVAudioApplication.shared.recordPermission
    @State private var isFullDebugEnabled = false
    @State private var diagnosticTraceCount = 0
    @State private var latestDiagnosticDate: Date?

    var body: some View {
        List {
            if appModel.pendingChatDraftAfterModelSetup.isEmpty == false {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("继续完成模型设置")
                                .font(.headline)
                            Text("保存后会自动回到 Chat，并保留你刚才准备发送的内容。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Button("不恢复这条消息") {
                            appModel.clearPendingChatDraft()
                        }
                        .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("模型") {
                Button {
                    showsModelSettings = true
                } label: {
                    Label(appModel.pendingChatDraftAfterModelSetup.isEmpty ? "模型设置" : "继续设置并返回 Chat", systemImage: "sparkles")
                }
                .buttonStyle(.plain)
            }

            Section("文档") {
                ForEach(documents) { document in
                    Button {
                        selectedDocumentID = document.id
                    } label: {
                        HStack {
                            Text(documentTitle(for: document))
                            Spacer()
                            Text(documentPreview(for: document))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                NavigationLink {
                    AgentContextPrivacyView()
                } label: {
                    LabeledContent("上下文与隐私", value: contextPrivacySummary)
                }
            } header: {
                Text("上下文与隐私")
            } footer: {
                Text("任务标题、清单和时间等上下文可能发送给你配置的远端模型服务商。任务备注和已完成事项默认不会发送。")
            }

            Section("执行策略") {
                Text("删除需要确认")
                Text("新建列表需要确认")
            }

            Section {
                NavigationLink {
                    AgentDiagnosticsListView()
                } label: {
                    LabeledContent("诊断记录", value: diagnosticStatusText)
                }

                Toggle("保存完整调试内容", isOn: $isFullDebugEnabled)
                    .onChange(of: isFullDebugEnabled) { _, enabled in
                        AgentTraceService.shared.isFullDebugEnabled = enabled
                        RemoteResponseDebugStore.shared.isFullDebugEnabled = enabled
                        refreshDiagnosticStatus()
                    }

                Text(fullDebugPrivacyHint)
                    .font(.footnote)
                    .foregroundStyle(isFullDebugEnabled ? .orange : .secondary)

                Button("立即清除诊断数据", role: .destructive) {
                    AgentTraceService.shared.clear()
                    RemoteResponseDebugStore.shared.clear()
                    refreshDiagnosticStatus()
                }
                .disabled(diagnosticTraceCount == 0 && RemoteResponseDebugStore.shared.load() == nil)
            } header: {
                Text("本机诊断")
            } footer: {
                Text("诊断数据仅保存在本机，最多保留 20 次请求或 7 天。API Key、Authorization 和语音凭证永远不会保存。")
            }

            Section("授权管理") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("提醒事项", value: remindersPermissionStatusText)
                    Text(remindersPermissionHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if canRequestRemindersPermission {
                        Button("请求提醒事项授权") {
                            Task {
                                await appModel.requestReminderPermission()
                                await appModel.refreshReminderPermission()
                            }
                        }
                        .buttonStyle(.bordered)
                    } else if shouldShowSettingsButtonForReminders {
                        Button("去系统设置开启提醒事项") {
                            openSystemSettings()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("麦克风", value: microphonePermissionStatusText)
                    Text(microphonePermissionHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if canRequestMicrophonePermission {
                        Button("请求麦克风授权") {
                            requestMicrophonePermission()
                        }
                        .buttonStyle(.bordered)
                    } else if shouldShowSettingsButtonForMicrophone {
                        Button("去系统设置开启麦克风") {
                            openSystemSettings()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Agent")
        .navigationDestination(isPresented: $showsModelSettings) {
            ModelSettingsView()
        }
        .navigationDestination(item: selectedDocumentBinding) { document in
            AgentDocumentEditorView(document: document)
        }
        .onAppear {
            AIGTDAgentDocumentStore.ensureDefaults(in: modelContext)
            refreshPermissionStatus()
            refreshDiagnosticStatus()
            if appModel.pendingChatDraftAfterModelSetup.isEmpty == false {
                showsModelSettings = true
            }
        }
        .onChange(of: appModel.pendingChatDraftAfterModelSetup) { _, newValue in
            if newValue.isEmpty == false {
                showsModelSettings = true
            }
        }
        .onChange(of: appModel.selectedTab) { _, newValue in
            guard newValue == .agent else { return }
            refreshPermissionStatus()
        }
    }

    private var selectedDocumentBinding: Binding<AgentDocument?> {
        Binding<AgentDocument?>(
            get: {
                guard let selectedDocumentID else { return nil }
                return documents.first(where: { $0.id == selectedDocumentID })
            },
            set: { newValue in
                selectedDocumentID = newValue?.id
            }
        )
    }

    private func documentTitle(for document: AgentDocument) -> String {
        AIGTDAgentDocumentKind(rawValue: document.kind)?.title ?? document.kind
    }

    private func documentPreview(for document: AgentDocument) -> String {
        document.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    private var canRequestRemindersPermission: Bool {
        appModel.reminderPermissionStatus == .notDetermined
    }

    private var shouldShowSettingsButtonForReminders: Bool {
        switch appModel.reminderPermissionStatus {
        case .denied, .restricted:
            return true
        default:
            return false
        }
    }

    private var remindersPermissionStatusText: String {
        switch appModel.reminderPermissionStatus {
        case .fullAccess, .writeOnly, .authorized:
            return "已允许"
        case .notDetermined:
            return "未授权"
        case .denied:
            return "已拒绝"
        case .restricted:
            return "受限制"
        @unknown default:
            return "未知"
        }
    }

    private var remindersPermissionHint: String {
        switch appModel.reminderPermissionStatus {
        case .fullAccess, .writeOnly, .authorized:
            return "当前已可读取和写入提醒事项。"
        case .notDetermined:
            return "你可以在这里发起首次授权。"
        case .denied:
            return "你之前点了“不允许”，需要到系统设置重新开启。"
        case .restricted:
            return "设备或家长控制限制了权限，需要在系统层处理。"
        @unknown default:
            return "权限状态未知，建议到系统设置检查。"
        }
    }

    private var canRequestMicrophonePermission: Bool {
        microphonePermission == .undetermined
    }

    private var shouldShowSettingsButtonForMicrophone: Bool {
        microphonePermission == .denied
    }

    private var microphonePermissionStatusText: String {
        switch microphonePermission {
        case .granted:
            return "已允许"
        case .undetermined:
            return "未授权"
        case .denied:
            return "已拒绝"
        @unknown default:
            return "未知"
        }
    }

    private var microphonePermissionHint: String {
        switch microphonePermission {
        case .granted:
            return "当前可进行语音输入。"
        case .undetermined:
            return "你可以在这里发起首次授权。"
        case .denied:
            return "你之前点了“不允许”，需要到系统设置重新开启。"
        @unknown default:
            return "权限状态未知，建议到系统设置检查。"
        }
    }

    private func refreshPermissionStatus() {
        microphonePermission = AVAudioApplication.shared.recordPermission
        Task {
            await appModel.refreshReminderPermission()
        }
    }

    private var diagnosticStatusText: String {
        guard diagnosticTraceCount > 0 else { return "暂无记录" }
        if let latestDiagnosticDate {
            return "\(diagnosticTraceCount) 条，最近 \(latestDiagnosticDate.formatted(date: .omitted, time: .shortened))"
        }
        return "\(diagnosticTraceCount) 条"
    }

    private var contextPrivacySummary: String {
        let settings = AgentContextPrivacyStore.shared.settings()
        return settings.includesNotes ? "备注已允许" : "默认保护"
    }

    private var fullDebugPrivacyHint: String {
        if isFullDebugEnabled {
            return "已开启：短期保存经过凭证过滤的响应与错误正文，其中仍可能包含私人聊天和任务内容。排查完成后请关闭或立即清除。"
        }
        return "默认保护已开启：只保存文本长度、哈希、结构字段和错误类型，无法还原完整聊天、任务标题或备注。"
    }

    private func refreshDiagnosticStatus() {
        let traces = AgentTraceService.shared.traces()
        diagnosticTraceCount = traces.count
        latestDiagnosticDate = traces.first?.updatedAt
        isFullDebugEnabled = AgentTraceService.shared.isFullDebugEnabled
    }

    private func requestMicrophonePermission() {
        AVAudioApplication.requestRecordPermission { _ in
            DispatchQueue.main.async {
                self.microphonePermission = AVAudioApplication.shared.recordPermission
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

#Preview {
    NavigationStack {
        AgentHomeView()
    }
    .environment(AppModel.previewFinished)
}

private struct AgentDocumentEditorView: View {
    @Bindable var document: AgentDocument
    @Environment(\.modelContext) private var modelContext
    @State private var showsRestoreConfirmation = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $document.content)
                    .frame(minHeight: 280)
                    .onChange(of: document.content) { _, _ in
                        document.updatedAt = .now
                    }
            } header: {
                Text(editorTitle)
            } footer: {
                Text("这里的内容会参与 AIGTD 的运行上下文，用来影响它的说话方式和事务处理习惯。")
            }
        }
        .navigationTitle(editorTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("恢复默认", role: .destructive) {
                        showsRestoreConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            document.kind == AIGTDAgentDocumentKind.memory.rawValue ? "清除长期记忆？" : "恢复默认内容？",
            isPresented: $showsRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(document.kind == AIGTDAgentDocumentKind.memory.rawValue ? "清除长期记忆" : "恢复默认", role: .destructive) {
                restoreDefault()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(document.kind == AIGTDAgentDocumentKind.memory.rawValue
                 ? "只会清除本机保存的长期偏好，不会删除聊天记录或提醒事项。"
                 : "当前编辑内容将替换为 AIGTD 的系统默认内容。")
        }
    }

    private var editorTitle: String {
        AIGTDAgentDocumentKind(rawValue: document.kind)?.title ?? document.kind
    }

    private func restoreDefault() {
        guard let kind = AIGTDAgentDocumentKind(rawValue: document.kind) else { return }
        document.content = kind.defaultContent
        document.updatedAt = .now
        try? modelContext.save()
    }
}

private struct AgentDiagnosticsListView: View {
    @State private var traces: [AgentTrace] = []

    var body: some View {
        Group {
            if traces.isEmpty {
                ContentUnavailableView(
                    "暂无诊断记录",
                    systemImage: "waveform.path.ecg",
                    description: Text("完成一次聊天或任务操作后，诊断阶段会显示在这里。")
                )
            } else {
                List(traces) { trace in
                    NavigationLink {
                        AgentDiagnosticDetailView(trace: trace)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(trace.resultTitle, systemImage: trace.resultSystemImage)
                                    .foregroundStyle(trace.resultColor)
                                Spacer()
                                Text(trace.updatedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text("\(trace.stages.count) 个阶段 · \(trace.actionSummary)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("诊断记录")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            traces = AgentTraceService.shared.traces()
        }
    }
}

private struct AgentDiagnosticDetailView: View {
    let trace: AgentTrace

    var body: some View {
        List {
            Section("请求") {
                LabeledContent("结果", value: trace.resultTitle)
                LabeledContent("开始", value: trace.createdAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent("结束", value: trace.updatedAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Trace ID", value: trace.id.uuidString)
                    .font(.caption)
            }

            Section("执行阶段") {
                ForEach(trace.stages) { stage in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(stage.stage.displayName, systemImage: stage.status.systemImage)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(stage.status.color)
                            Spacer()
                            Text(stage.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let actionType = stage.actionType, actionType.isEmpty == false {
                            diagnosticLine(title: "动作", value: actionType)
                        }
                        if let duration = stage.durationMilliseconds {
                            diagnosticLine(title: "耗时", value: "\(duration) ms")
                        }
                        if let errorCategory = stage.errorCategory, errorCategory.isEmpty == false {
                            diagnosticLine(title: "错误类型", value: errorCategory)
                        }
                        if let content = stage.content {
                            contentSummary(content, title: "内容摘要")
                        }
                        if let error = stage.userVisibleErrorSummary {
                            contentSummary(error, title: "错误摘要")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Text("默认仅展示长度、哈希和结构字段。只有主动开启“保存完整调试内容”后，才会显示经过凭证过滤的短期预览。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("诊断详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func diagnosticLine(title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func contentSummary(_ summary: AgentTraceContentSummary, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text("长度：\(summary.length) bytes")
            Text("哈希：\(String(summary.sha256.prefix(12)))…")
            if summary.structure.isEmpty == false {
                Text("结构：\(summary.structure.joined(separator: ", "))")
            }
            if let preview = summary.sanitizedPreview, preview.isEmpty == false {
                Text(preview)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private extension AgentTrace {
    var resultTitle: String {
        if stages.contains(where: { $0.status == .failure }) {
            return "失败"
        }
        if stages.last?.stage == .replyFinalized {
            return "已完成"
        }
        if stages.contains(where: { $0.stage == .structuredParseCompleted }) {
            return "已解析"
        }
        return "处理中"
    }

    var resultSystemImage: String {
        if stages.contains(where: { $0.status == .failure }) {
            return "xmark.circle.fill"
        }
        if stages.last?.stage == .replyFinalized {
            return "checkmark.circle.fill"
        }
        if stages.contains(where: { $0.stage == .structuredParseCompleted }) {
            return "checkmark.circle"
        }
        return "clock.fill"
    }

    var resultColor: Color {
        if stages.contains(where: { $0.status == .failure }) {
            return .red
        }
        if stages.last?.stage == .replyFinalized {
            return .green
        }
        if stages.contains(where: { $0.stage == .structuredParseCompleted }) {
            return .secondary
        }
        return .orange
    }

    var actionSummary: String {
        stages.reversed().compactMap(\.actionType).first ?? "无任务动作"
    }
}

private extension AgentTraceStage {
    var displayName: String {
        switch self {
        case .inputReceived: "收到输入"
        case .contextRefresh: "刷新上下文"
        case .contextBuild: "构建上下文"
        case .referenceResolution: "解析引用"
        case .sessionSummaryUpdate: "更新会话摘要"
        case .memoryUpdate: "更新长期记忆"
        case .localPreviewCompleted: "本地预判"
        case .remoteRequestStarted: "远端请求"
        case .remoteResponseReceived: "收到回复"
        case .structuredParseCompleted: "结构化解析"
        case .fallbackResolutionCompleted: "回退解析"
        case .actionExecutionStarted: "开始执行"
        case .actionExecutionCompleted: "执行完成"
        case .remindersRefreshCompleted: "刷新提醒事项"
        case .replyFinalized: "完成回复"
        }
    }
}

private extension AgentTraceStageStatus {
    var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .skipped: "minus.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .failure: .red
        case .skipped: .secondary
        }
    }
}
