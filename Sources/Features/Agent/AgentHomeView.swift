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
    @State private var microphonePermission: AVAudioSession.RecordPermission = AVAudioSession.sharedInstance().recordPermission

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

            Section("执行策略") {
                Text("删除需要确认")
                Text("新建列表需要确认")
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
        microphonePermission = AVAudioSession.sharedInstance().recordPermission
        Task {
            await appModel.refreshReminderPermission()
        }
    }

    private func requestMicrophonePermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { _ in
            DispatchQueue.main.async {
                self.microphonePermission = AVAudioSession.sharedInstance().recordPermission
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
    }

    private var editorTitle: String {
        AIGTDAgentDocumentKind(rawValue: document.kind)?.title ?? document.kind
    }
}
