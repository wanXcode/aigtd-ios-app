import SwiftUI
import SwiftData

struct AgentHomeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AgentDocument.updatedAt, order: .forward) private var documents: [AgentDocument]
    @State private var showsModelSettings = false
    @State private var selectedDocumentID: UUID?
    @State private var debugSnapshot: RemoteResponseDebugSnapshot?

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

            if let snapshot = debugSnapshot {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("时间", value: snapshot.createdAt.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("Wire API", value: snapshot.wireAPI)
                        LabeledContent("状态码", value: snapshot.statusCode.map(String.init) ?? "无")
                        Text(snapshot.endpoint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        ScrollView {
                            Text(snapshot.body)
                                .font(.footnote.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 180)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button("清空这份调试响应") {
                            RemoteResponseDebugStore.shared.clear()
                            self.debugSnapshot = nil
                        }
                        .font(.footnote)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("远端返回调试")
                } footer: {
                    Text("这里保存的是最近一次模型连接测试或 Chat 远端调用的原始返回摘要。看到这里就不用再猜 provider 返回格式了。")
                }
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
            debugSnapshot = RemoteResponseDebugStore.shared.load()
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
            debugSnapshot = RemoteResponseDebugStore.shared.load()
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
