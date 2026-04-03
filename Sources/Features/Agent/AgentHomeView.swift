import SwiftUI

struct AgentHomeView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showsModelSettings = false

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
                Text("Prompt")
                Text("Memory")
                Text("Solu")
                Text("Operating Guide")
            }

            Section("执行策略") {
                Text("删除需要确认")
                Text("新建列表需要确认")
            }
        }
        .navigationTitle("Agent")
        .navigationDestination(isPresented: $showsModelSettings) {
            ModelSettingsView()
        }
        .onAppear {
            if appModel.pendingChatDraftAfterModelSetup.isEmpty == false {
                showsModelSettings = true
            }
        }
        .onChange(of: appModel.pendingChatDraftAfterModelSetup) { _, newValue in
            if newValue.isEmpty == false {
                showsModelSettings = true
            }
        }
    }
}

#Preview {
    NavigationStack {
        AgentHomeView()
    }
    .environment(AppModel.previewFinished)
}
