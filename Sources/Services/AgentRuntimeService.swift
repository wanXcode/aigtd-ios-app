import Foundation

struct AgentModelConfiguration: Sendable {
    let provider: String
    let wireAPI: String
    let modelID: String
    let baseURL: String
    let apiKey: String
    let temperature: Double
    let maxTokens: Int
    let timeoutSeconds: Double
}

struct AgentRuntimeService {
    private let fallback = MockAgentService()

    func respond(
        to content: String,
        reminderLists: [ReminderListInfo],
        configuration: AgentModelConfiguration?
    ) async -> MockAgentResult {
        let localInterpretation = fallback.respond(to: content, reminderLists: reminderLists)

        guard let configuration,
              configuration.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return localInterpretation
        }

        do {
            let remoteResult = try await requestRemoteResponse(
                content: content,
                reminderLists: reminderLists,
                configuration: configuration
            )
            return reconcile(remoteResult: remoteResult, localResult: localInterpretation)
        } catch {
            return MockAgentResult(
                reply: localInterpretation.reply,
                summary: "\(localInterpretation.summary) · 远端调用失败，已回退本地规则",
                actionType: localInterpretation.actionType,
                payloadJSON: localInterpretation.payloadJSON,
                confidence: localInterpretation.confidence,
                followUpPrompt: localInterpretation.followUpPrompt
            )
        }
    }

    func testConnection(configuration: AgentModelConfiguration) async throws -> String {
        guard configuration.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentRuntimeError.invalidConfiguration
        }

        let request = try makeHealthCheckRequest(configuration: configuration)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = min(configuration.timeoutSeconds, 15)
        sessionConfiguration.timeoutIntervalForResource = min(configuration.timeoutSeconds, 15)

        let (data, response) = try await URLSession(configuration: sessionConfiguration).data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentRuntimeError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AgentRuntimeError.httpStatus(
                httpResponse.statusCode,
                responseBodySummary(from: data)
            )
        }

        let returnedText = try parseReturnedText(from: data, configuration: configuration)
        guard returnedText.isEmpty == false else {
            throw AgentRuntimeError.invalidPayload
        }

        return "连接成功，可正常访问 \(configuration.modelID)"
    }

    private func requestRemoteResponse(
        content: String,
        reminderLists: [ReminderListInfo],
        configuration: AgentModelConfiguration
    ) async throws -> MockAgentResult {
        let request = try makeRequest(
            content: content,
            reminderLists: reminderLists,
            configuration: configuration
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = configuration.timeoutSeconds

        let (data, response) = try await URLSession(configuration: sessionConfiguration).data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentRuntimeError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AgentRuntimeError.httpStatus(
                httpResponse.statusCode,
                responseBodySummary(from: data)
            )
        }

        let content = try parseReturnedText(from: data, configuration: configuration)
        guard let payload = extractJSONPayload(from: content),
              let payloadData = payload.data(using: .utf8) else {
            throw AgentRuntimeError.invalidPayload
        }

        let envelope = try JSONDecoder().decode(RemoteAgentEnvelope.self, from: payloadData)
        return MockAgentResult(
            reply: envelope.reply,
            summary: envelope.summary,
            actionType: envelope.action.intent,
            payloadJSON: encodePayload(envelope.toMockEnvelope()),
            confidence: envelope.confidence,
            followUpPrompt: envelope.followUpPrompt
        )
    }

    private func makeRequest(
        content: String,
        reminderLists: [ReminderListInfo],
        configuration: AgentModelConfiguration
    ) throws -> URLRequest {
        let endpoint = normalizedEndpoint(from: configuration)
        guard let url = URL(string: endpoint) else {
            throw AgentRuntimeError.invalidURL
        }

        let availableLists = reminderLists.map(\.title).joined(separator: "、")
        let systemPrompt = """
        你是一个 iOS Reminders 助手。你必须把用户输入解析成结构化 JSON。
        可用 intent 只有：
        - create_reminder
        - create_list
        - summarize_lists
        - capture_message
        - move_reminder
        - complete_reminder

        当前用户已有的提醒事项列表：\(availableLists.isEmpty ? "无" : availableLists)

        你必须只输出 JSON，不要输出 Markdown，不要输出解释。JSON 结构如下：
        {
          "reply": "给用户看的自然语言回复",
          "summary": "简短执行摘要",
          "confidence": 0.0,
          "followUpPrompt": "可选，后续建议",
          "matchedSignals": ["signal"],
          "action": {
            "intent": "create_reminder",
            "title": "动作标题",
            "entities": {
              "title": "任务标题",
              "due_date": "可选，ISO8601 时间",
              "preferred_list_name": "可选，目标列表名",
              "note": "可选，备注",
              "bucket": "today/tomorrow/future",
              "category": "inbox/project/next_action/waiting_for/maybe",
              "source_text": "原始输入"
            },
            "requiresConfirmation": false
          }
        }

        规则：
        - 只要用户明显是在创建一条提醒事项或任务，就优先返回 create_reminder，不要返回 capture_message。
        - 如果用户说了今天、明天、后天、下周几、具体日期，要尽量填 due_date。
        - 如果用户提到了已有提醒事项列表名，要填 preferred_list_name。
        - 只有在你确实无法判断用户想执行什么时，才返回 capture_message。
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try makeRequestBody(
            systemPrompt: systemPrompt,
            userContent: content,
            configuration: configuration
        )
        return request
    }

    private func makeHealthCheckRequest(
        configuration: AgentModelConfiguration
    ) throws -> URLRequest {
        let endpoint = normalizedEndpoint(from: configuration)
        guard let url = URL(string: endpoint) else {
            throw AgentRuntimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try makeRequestBody(
            systemPrompt: "Reply with a short JSON object.",
            userContent: "{\"ok\":true}",
            configuration: configuration,
            maxTokensOverride: 60,
            temperatureOverride: 0
        )
        return request
    }

    private func normalizedEndpoint(from configuration: AgentModelConfiguration) -> String {
        let custom = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if custom.isEmpty == false {
            if custom.hasSuffix("/chat/completions") || custom.hasSuffix("/responses") {
                return custom
            }
            let path = normalizedWireAPI(from: configuration) == .responses ? "v1/responses" : "v1/chat/completions"
            return custom.hasSuffix("/") ? "\(custom)\(path)" : "\(custom)/\(path)"
        }
        let path = normalizedWireAPI(from: configuration) == .responses ? "responses" : "chat/completions"
        return "https://api.openai.com/v1/\(path)"
    }

    private func normalizedWireAPI(from configuration: AgentModelConfiguration) -> WireAPIMode {
        WireAPIMode(rawValue: configuration.wireAPI.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .chatCompletions
    }

    private func makeRequestBody(
        systemPrompt: String,
        userContent: String,
        configuration: AgentModelConfiguration,
        maxTokensOverride: Int? = nil,
        temperatureOverride: Double? = nil
    ) throws -> Data {
        switch normalizedWireAPI(from: configuration) {
        case .chatCompletions:
            let requestBody = OpenAICompatibleChatRequest(
                model: configuration.modelID,
                messages: [
                    .init(role: "system", content: systemPrompt),
                    .init(role: "user", content: userContent)
                ],
                temperature: temperatureOverride ?? configuration.temperature,
                maxTokens: maxTokensOverride ?? configuration.maxTokens,
                responseFormat: .init(type: "json_object")
            )
            return try JSONEncoder().encode(requestBody)
        case .responses:
            let requestBody = OpenAIResponsesRequest(
                model: configuration.modelID,
                input: [
                    .init(role: "system", content: [.init(type: "input_text", text: systemPrompt)]),
                    .init(role: "user", content: [.init(type: "input_text", text: userContent)])
                ],
                temperature: temperatureOverride ?? configuration.temperature,
                maxOutputTokens: maxTokensOverride ?? configuration.maxTokens
            )
            return try JSONEncoder().encode(requestBody)
        }
    }

    private func parseReturnedText(from data: Data, configuration: AgentModelConfiguration) throws -> String {
        switch normalizedWireAPI(from: configuration) {
        case .chatCompletions:
            let completion = try JSONDecoder().decode(OpenAICompatibleChatResponse.self, from: data)
            guard let content = completion.choices.first?.message.content else {
                throw AgentRuntimeError.invalidPayload
            }
            return content
        case .responses:
            let response = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
            let text = response.output
                .flatMap(\.content)
                .filter { $0.type == "output_text" }
                .compactMap(\.text)
                .joined(separator: "\n")
            guard text.isEmpty == false else {
                throw AgentRuntimeError.invalidPayload
            }
            return text
        }
    }

    private func extractJSONPayload(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "{" && trimmed.last == "}" {
            return trimmed
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return nil
        }
        return String(trimmed[start...end])
    }

    private func encodePayload(_ envelope: MockAgentEnvelope) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(envelope),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func responseBodySummary(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              text.isEmpty == false else {
            return "无返回内容"
        }

        if text.count > 280 {
            return String(text.prefix(280)) + "…"
        }
        return text
    }

    private func reconcile(
        remoteResult: MockAgentResult,
        localResult: MockAgentResult
    ) -> MockAgentResult {
        guard remoteResult.actionType == MockAgentIntent.captureMessage.rawValue,
              localResult.actionType != MockAgentIntent.captureMessage.rawValue else {
            return remoteResult
        }

        return MockAgentResult(
            reply: localResult.reply,
            summary: "\(localResult.summary) · 已用本地规则替换保守解析",
            actionType: localResult.actionType,
            payloadJSON: localResult.payloadJSON,
            confidence: localResult.confidence,
            followUpPrompt: localResult.followUpPrompt
        )
    }
}

private enum AgentRuntimeError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidPayload
    case invalidConfiguration
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "请求地址无效，请检查 Base URL。"
        case .invalidResponse:
            return "服务返回了无法识别的响应。"
        case .invalidPayload:
            return "服务返回成功，但内容格式不是当前 App 可解析的结果。"
        case .invalidConfiguration:
            return "模型配置不完整。"
        case let .httpStatus(statusCode, body):
            return "HTTP \(statusCode)：\(body)"
        }
    }
}

private struct OpenAICompatibleChatRequest: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let temperature: Double
    let maxTokens: Int
    let responseFormat: OpenAIResponseFormat

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

private struct OpenAIMessage: Encodable {
    let role: String
    let content: String
}

private struct OpenAIResponseFormat: Encodable {
    let type: String
}

private struct OpenAICompatibleChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}

private struct OpenAIResponsesRequest: Encodable {
    let model: String
    let input: [OpenAIResponsesInputItem]
    let temperature: Double
    let maxOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case temperature
        case maxOutputTokens = "max_output_tokens"
    }
}

private struct OpenAIResponsesInputItem: Encodable {
    let role: String
    let content: [OpenAIResponsesContentItem]
}

private struct OpenAIResponsesContentItem: Encodable {
    let type: String
    let text: String
}

private struct OpenAIResponsesResponse: Decodable {
    let output: [OutputItem]

    struct OutputItem: Decodable {
        let content: [ContentItem]
    }

    struct ContentItem: Decodable {
        let type: String
        let text: String?
    }
}

private enum WireAPIMode: String {
    case chatCompletions = "chat_completions"
    case responses = "responses"
}

private struct RemoteAgentEnvelope: Decodable {
    let reply: String
    let summary: String
    let confidence: Double
    let followUpPrompt: String?
    let matchedSignals: [String]
    let action: RemoteAgentAction

    func toMockEnvelope() -> MockAgentEnvelope {
        MockAgentEnvelope(
            action: MockAgentActionPayload(
                intent: action.intent,
                title: action.title,
                entities: action.entities,
                requiresConfirmation: action.requiresConfirmation
            ),
            confidence: confidence,
            summary: summary,
            followUpPrompt: followUpPrompt,
            matchedSignals: matchedSignals
        )
    }
}

private struct RemoteAgentAction: Decodable {
    let intent: String
    let title: String
    let entities: [String: String]
    let requiresConfirmation: Bool
}
