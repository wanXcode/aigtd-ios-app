import SwiftData
import SwiftUI

struct AgentContextPrivacyView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]
    @Query(sort: \AgentDocument.updatedAt, order: .forward) private var documents: [AgentDocument]
    @State private var settings = AgentContextPrivacySettings.standard
    @State private var storedContext: StoredAgentSessionContext?
    @State private var memoryItems: [UserMemoryItem] = []
    @State private var editingMemoryItem: UserMemoryItem?
    @State private var showsClearContextConfirmation = false
    @State private var showsClearMemoryConfirmation = false

    var body: some View {
        Form {
            Section("当前会话") {
                LabeledContent("上下文状态", value: storedContext == nil ? "尚未建立" : "已建立")
                LabeledContent("最近引用", value: "\(referenceCount) 条")
                LabeledContent("会话摘要", value: summaryStatus)
                LabeledContent("长期记忆", value: "\(memoryItemCount) 条")
            }

            Section {
                Toggle("允许读取任务备注", isOn: includesNotesBinding)
                Toggle("允许包含已完成任务", isOn: includesCompletedBinding)
                Stepper("发送任务上限：\(settings.maximumReminderCount)", value: reminderLimitBinding, in: 5...100, step: 5)
            } header: {
                Text("发送给模型的任务数据")
            } footer: {
                Text("默认只发送必要的标题、清单和时间。设置会在下一次对话请求中生效。")
            }

            Section("本地数据") {
                Button("清除当前会话上下文", role: .destructive) {
                    showsClearContextConfirmation = true
                }
                .disabled(activeSessionID == nil || storedContext == nil)

                Button("清除长期记忆", role: .destructive) {
                    showsClearMemoryConfirmation = true
                }
            }

            if memoryItems.isEmpty == false {
                Section("已保存的长期记忆") {
                    ForEach(memoryItems) { item in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(memoryCategoryTitle(item.category))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(item.value)
                            }
                            Spacer()
                            Button("编辑") {
                                editingMemoryItem = item
                            }
                            .buttonStyle(.borderless)
                            Button(role: .destructive) {
                                AgentUserMemoryStore.shared.remove(id: item.id)
                                refresh()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("删除这条长期记忆")
                        }
                    }
                }
            }
        }
        .navigationTitle("上下文与隐私")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .confirmationDialog("清除当前会话上下文？", isPresented: $showsClearContextConfirmation, titleVisibility: .visible) {
            Button("清除上下文", role: .destructive, action: clearCurrentContext)
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清除摘要和最近任务引用，但不会删除聊天记录或系统提醒事项。")
        }
        .confirmationDialog("清除长期记忆？", isPresented: $showsClearMemoryConfirmation, titleVisibility: .visible) {
            Button("清除长期记忆", role: .destructive, action: clearMemory)
            Button("取消", role: .cancel) {}
        } message: {
            Text("会恢复为不含个人偏好的安全模板，不会删除聊天记录或系统提醒事项。")
        }
        .sheet(item: $editingMemoryItem) { item in
            AgentMemoryEditView(item: item) {
                refresh()
            }
        }
    }

    private var activeSessionID: UUID? { sessions.first?.id }

    private var referenceCount: Int {
        Set(storedContext?.references.allReferences.map(\.reminderID) ?? []).count
    }

    private var summaryStatus: String {
        guard let date = storedContext?.summary?.updatedAt else { return "暂无" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var memoryDocument: AgentDocument? {
        documents.first { $0.kind == AIGTDAgentDocumentKind.memory.rawValue }
    }

    private var memoryItemCount: Int {
        memoryItems.count
    }

    private var includesNotesBinding: Binding<Bool> {
        Binding(
            get: { settings.includesNotes },
            set: { value in
                settings.includesNotes = value
                persistSettings()
            }
        )
    }

    private var includesCompletedBinding: Binding<Bool> {
        Binding(
            get: { settings.includesCompletedReminders },
            set: { value in
                settings.includesCompletedReminders = value
                persistSettings()
            }
        )
    }

    private var reminderLimitBinding: Binding<Int> {
        Binding(
            get: { settings.maximumReminderCount },
            set: { value in
                settings.maximumReminderCount = value
                persistSettings()
            }
        )
    }

    private func refresh() {
        settings = AgentContextPrivacyStore.shared.settings()
        storedContext = activeSessionID.flatMap { AgentSessionContextStore.shared.context(for: $0) }
        memoryItems = AgentUserMemoryStore.shared.items()
    }

    private func persistSettings() {
        AgentContextPrivacyStore.shared.save(settings)
        settings = AgentContextPrivacyStore.shared.settings()
    }

    private func clearCurrentContext() {
        guard let activeSessionID else { return }
        AgentSessionContextStore.shared.remove(sessionID: activeSessionID)
        storedContext = nil
    }

    private func clearMemory() {
        AgentUserMemoryStore.shared.clear()
        if let memoryDocument {
            memoryDocument.content = AIGTDAgentDocumentKind.memory.defaultContent
            memoryDocument.updatedAt = .now
        } else {
            modelContext.insert(
                AgentDocument(
                    kind: AIGTDAgentDocumentKind.memory.rawValue,
                    content: AIGTDAgentDocumentKind.memory.defaultContent
                )
            )
        }
        try? modelContext.save()
        refresh()
    }

    private func memoryCategoryTitle(_ category: UserMemoryCategory) -> String {
        switch category {
        case .preferredName: "用户称呼"
        case .timeZone: "默认时区"
        case .defaultTaskTime: "默认任务时间"
        case .defaultList: "默认清单"
        case .workingSchedule: "工作时间偏好"
        case .transactionRule: "事务规则"
        }
    }
}

private struct AgentMemoryEditView: View {
    @Environment(\.dismiss) private var dismiss
    let item: UserMemoryItem
    let onSave: () -> Void
    @State private var value: String
    @State private var validationMessage: String?

    init(item: UserMemoryItem, onSave: @escaping () -> Void) {
        self.item = item
        self.onSave = onSave
        _value = State(initialValue: item.value)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $value)
                        .frame(minHeight: 120)
                } header: {
                    Text("偏好内容")
                } footer: {
                    Text(validationMessage ?? "只保存稳定、可复用的规则。敏感信息请不要写入长期记忆。")
                        .foregroundStyle(validationMessage == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("编辑长期记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let reason = AgentMemoryPolicy().validationErrorForEditedValue(value) {
                            validationMessage = reason.rawValue
                            return
                        }
                        AgentUserMemoryStore.shared.update(id: item.id, value: value)
                        onSave()
                        dismiss()
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
