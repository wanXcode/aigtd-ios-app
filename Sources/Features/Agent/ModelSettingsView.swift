import SwiftData
import SwiftUI

struct ModelSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ModelProfile.displayName) private var profiles: [ModelProfile]

    @State private var isTestingConnection = false
    @State private var testStatusMessage = ""
    @State private var testStatusTone: TestStatusTone = .idle

    @State private var displayName = "默认模型"
    @State private var provider = "OpenAI"
    @State private var wireAPI = WireAPIPreset.chatCompletions.rawValue
    @State private var modelID = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var temperature = 0.2
    @State private var maxTokens = 800
    @State private var timeoutSeconds = 30.0

    private let runtime = AgentRuntimeService()

    var body: some View {
        Form {
            Section("当前配置") {
                if let activeProfile {
                    LabeledContent("名称", value: activeProfile.displayName)
                    LabeledContent("Provider", value: activeProfile.provider.isEmpty ? "未设置" : activeProfile.provider)
                    LabeledContent("Wire API", value: activeProfile.wireAPI.isEmpty ? "chat_completions" : activeProfile.wireAPI)
                    LabeledContent("模型", value: activeProfile.modelID.isEmpty ? "未设置" : activeProfile.modelID)
                    LabeledContent("Base URL", value: activeProfile.baseURL.isEmpty ? "默认" : activeProfile.baseURL)
                    LabeledContent("API Key", value: activeProfile.apiKeyReference.isEmpty ? "未设置" : maskedKey(activeProfile.apiKeyReference))
                } else {
                    Text("还没有模型配置。")
                        .foregroundStyle(.secondary)
                }
            }

            Section("编辑配置") {
                TextField("显示名称", text: $displayName)
                Picker("Provider", selection: $provider) {
                    ForEach(ModelProviderPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset.rawValue)
                    }
                }
                Picker("Wire API", selection: $wireAPI) {
                    ForEach(WireAPIPreset.allCases) { preset in
                        Text(preset.label).tag(preset.rawValue)
                    }
                }
                TextField("模型 ID", text: $modelID)
                if selectedProviderPreset == .openAICompatible {
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    LabeledContent("Base URL", value: "默认 OpenAI 接口")
                }
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(temperature.formatted(.number.precision(.fractionLength(1))))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $temperature, in: 0...1, step: 0.1)

                Stepper("Max Tokens: \(maxTokens)", value: $maxTokens, in: 100...4000, step: 100)
                Stepper("超时: \(Int(timeoutSeconds)) 秒", value: $timeoutSeconds, in: 5...120, step: 5)

                Text(endpointHelpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("连接测试") {
                Button(isTestingConnection ? "正在测试…" : "测试连接") {
                    Task {
                        await runConnectionTest()
                    }
                }
                .disabled(isTestingConnection || connectionConfiguration == nil)

                if testStatusMessage.isEmpty == false {
                    Text(testStatusMessage)
                        .foregroundStyle(testStatusTone.color)
                        .font(.footnote)
                }
            }

            if appModel.pendingChatDraftAfterModelSetup.isEmpty == false {
                Section("继续刚才的消息") {
                    Text("保存模型后，我会带你回到 Chat，并保留你刚才准备发送的内容。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text(appModel.pendingChatDraftAfterModelSetup)
                        .font(.body)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            Section {
                Button(primarySaveButtonTitle) {
                    saveProfile()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaveDisabled)

                if let validationMessage {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if appModel.pendingChatDraftAfterModelSetup.isEmpty {
                    Text("保存后会把这组配置设为当前模型。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("保存后会自动切回 Chat，方便你继续刚才那条消息。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("模型设置")
        .onAppear {
            loadFromActiveProfile()
        }
        .onChange(of: provider) { _, newValue in
            guard let preset = ModelProviderPreset(rawValue: newValue) else { return }
            if preset == .openAI {
                baseURL = ""
            }
        }
    }

    private var activeProfile: ModelProfile? {
        profiles.first(where: \.isActive)
    }

    private func loadFromActiveProfile() {
        guard let activeProfile else { return }
        displayName = activeProfile.displayName
        provider = activeProfile.provider
        wireAPI = activeProfile.wireAPI.isEmpty ? WireAPIPreset.chatCompletions.rawValue : activeProfile.wireAPI
        modelID = activeProfile.modelID
        baseURL = activeProfile.baseURL
        apiKey = activeProfile.apiKeyReference
        temperature = activeProfile.temperature
        maxTokens = activeProfile.maxTokens
        timeoutSeconds = activeProfile.timeoutSeconds
    }

    private func saveProfile() {
        guard canSaveProfile else { return }

        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWireAPI = wireAPI.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = resolvedBaseURL
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        for profile in profiles {
            profile.isActive = false
        }

        if let activeProfile {
            activeProfile.displayName = trimmedDisplayName.isEmpty ? "默认模型" : trimmedDisplayName
            activeProfile.provider = trimmedProvider
            activeProfile.wireAPI = trimmedWireAPI
            activeProfile.modelID = trimmedModelID
            activeProfile.baseURL = trimmedBaseURL
            activeProfile.apiKeyReference = trimmedAPIKey
            activeProfile.temperature = temperature
            activeProfile.maxTokens = maxTokens
            activeProfile.timeoutSeconds = timeoutSeconds
            activeProfile.isActive = true
        } else {
            let profile = ModelProfile(
                displayName: trimmedDisplayName.isEmpty ? "默认模型" : trimmedDisplayName,
                provider: trimmedProvider,
                wireAPI: trimmedWireAPI,
                modelID: trimmedModelID,
                baseURL: trimmedBaseURL,
                apiKeyReference: trimmedAPIKey,
                temperature: temperature,
                maxTokens: maxTokens,
                timeoutSeconds: timeoutSeconds,
                isActive: true
            )
            modelContext.insert(profile)
        }

        do {
            try modelContext.save()
            if appModel.pendingChatDraftAfterModelSetup.isEmpty {
                appModel.markModelSetupComplete()
            } else {
                appModel.returnToChatAfterModelSetup()
                dismiss()
            }
        } catch {
            return
        }
    }

    private var primarySaveButtonTitle: String {
        appModel.pendingChatDraftAfterModelSetup.isEmpty ? "保存为当前模型" : "保存并返回 Chat"
    }

    private var selectedProviderPreset: ModelProviderPreset {
        ModelProviderPreset(rawValue: provider) ?? .openAI
    }

    private var connectionConfiguration: AgentModelConfiguration? {
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedProvider.isEmpty == false,
              trimmedModel.isEmpty == false,
              trimmedKey.isEmpty == false else {
            return nil
        }

        return AgentModelConfiguration(
            provider: trimmedProvider,
            wireAPI: wireAPI.trimmingCharacters(in: .whitespacesAndNewlines),
            modelID: trimmedModel,
            baseURL: resolvedBaseURL,
            apiKey: trimmedKey,
            temperature: temperature,
            maxTokens: maxTokens,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func runConnectionTest() async {
        guard let connectionConfiguration else { return }
        isTestingConnection = true
        testStatusMessage = ""
        defer { isTestingConnection = false }

        do {
            let message = try await runtime.testConnection(configuration: connectionConfiguration)
            testStatusTone = .success
            testStatusMessage = message
        } catch {
            testStatusTone = .failure
            testStatusMessage = "连接失败：\(readableErrorMessage(from: error))"
        }
    }

    private func maskedKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return "已填写" }
        return "\(trimmed.prefix(4))••••\(trimmed.suffix(4))"
    }

    private var resolvedBaseURL: String {
        selectedProviderPreset == .openAI ? "" : baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var endpointHelpText: String {
        switch selectedProviderPreset {
        case .openAI:
            return selectedWireAPIPreset == .responses
                ? "将使用默认 OpenAI Responses 接口，无需手动填写 Base URL。"
                : "将使用默认 OpenAI Chat Completions 接口，无需手动填写 Base URL。"
        case .openAICompatible:
            return selectedWireAPIPreset == .responses
                ? "填写兼容 OpenAI Responses 的服务地址，支持直接填到 `/responses`，也支持只填服务根地址。"
                : "填写兼容 OpenAI Chat Completions 的服务地址，支持直接填到 `/chat/completions`，也支持只填服务根地址。"
        }
    }

    private var canSaveProfile: Bool {
        guard provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        guard modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        guard apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }

        if selectedProviderPreset == .openAICompatible {
            return baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        return true
    }

    private var isSaveDisabled: Bool {
        !canSaveProfile
    }

    private var validationMessage: String? {
        if provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "先选择一个 Provider。"
        }
        if modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请输入模型 ID。"
        }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请输入 API Key。"
        }
        if selectedProviderPreset == .openAICompatible && baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "OpenAI-compatible 模式需要填写 Base URL。"
        }
        return nil
    }

    private var selectedWireAPIPreset: WireAPIPreset {
        WireAPIPreset(rawValue: wireAPI) ?? .chatCompletions
    }

    private func readableErrorMessage(from error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           description.isEmpty == false {
            return description
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "当前设备未连接网络。"
            case .timedOut:
                return "请求超时，请稍后重试。"
            case .cannotFindHost:
                return "找不到服务器，请检查 Base URL。"
            case .cannotConnectToHost:
                return "无法连接到服务器，请检查地址和端口是否可访问。"
            case .networkConnectionLost:
                return "网络连接中断，请重试。"
            case .secureConnectionFailed:
                return "TLS/HTTPS 握手失败，请检查证书或网关配置。"
            default:
                return urlError.localizedDescription
            }
        }

        let nsError = error as NSError
        if nsError.localizedDescription.isEmpty == false,
           nsError.localizedDescription != "The operation couldn’t be completed." &&
           nsError.localizedDescription != "The operation could not be completed." {
            return nsError.localizedDescription
        }

        return String(describing: error)
    }
}

#Preview {
    NavigationStack {
        ModelSettingsView()
    }
    .environment(AppModel.previewFinished)
    .modelContainer(for: ModelProfile.self, inMemory: true)
}

private enum TestStatusTone {
    case idle
    case success
    case failure

    var color: Color {
        switch self {
        case .idle:
            return .secondary
        case .success:
            return .green
        case .failure:
            return .red
        }
    }
}

private enum ModelProviderPreset: String, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case openAICompatible = "OpenAI-compatible"

    var id: String { rawValue }
}

private enum WireAPIPreset: String, CaseIterable, Identifiable {
    case chatCompletions = "chat_completions"
    case responses = "responses"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chatCompletions:
            return "chat_completions"
        case .responses:
            return "responses"
        }
    }
}
