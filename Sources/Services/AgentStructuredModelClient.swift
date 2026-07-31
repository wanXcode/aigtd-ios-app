import Foundation

protocol AgentStructuredModelTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionAgentStructuredModelTransport: AgentStructuredModelTransport {
    private let session: URLSession

    init(timeoutSeconds: Double) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

enum AgentStructuredModelClientError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidURL(String)
    case network(String)
    case invalidResponse
    case httpStatus(Int, String)
    case invalidEnvelope(String)
    case invalidDecision(String)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message),
             let .network(message),
             let .invalidEnvelope(message),
             let .invalidDecision(message):
            return message
        case let .invalidURL(value):
            return "模型地址无效：\(value)"
        case .invalidResponse:
            return "模型服务返回了无法识别的网络响应。"
        case let .httpStatus(status, message):
            return message.isEmpty
                ? "模型服务返回 HTTP \(status)。"
                : "模型服务返回 HTTP \(status)：\(message)"
        }
    }
}

struct AgentStructuredModelClient: AgentModelClient, Sendable {
    private enum WireAPI: String {
        case chatCompletions = "chat_completions"
        case responses
    }

    private let configuration: AgentModelConfiguration
    private let transport: any AgentStructuredModelTransport
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone

    init(
        configuration: AgentModelConfiguration,
        transport: (any AgentStructuredModelTransport)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.configuration = configuration
        self.transport = transport ?? URLSessionAgentStructuredModelTransport(
            timeoutSeconds: configuration.timeoutSeconds
        )
        self.now = now
        self.timeZone = timeZone
    }

    func decide(_ modelRequest: AgentModelRequest) async throws -> AgentModelDecision {
        do {
            return try await requestDecision(modelRequest, repairFeedback: nil)
        } catch let error as AgentStructuredModelClientError {
            switch error {
            case .invalidEnvelope, .invalidDecision:
                return try await requestDecision(
                    modelRequest,
                    repairFeedback: error.localizedDescription
                )
            default:
                throw error
            }
        }
    }

    private func requestDecision(
        _ modelRequest: AgentModelRequest,
        repairFeedback: String?
    ) async throws -> AgentModelDecision {
        let request = try makeURLRequest(for: modelRequest, repairFeedback: repairFeedback)
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            let message = error.code == .timedOut
                ? "模型请求超时，请稍后重试。"
                : "模型网络请求失败：\(error.localizedDescription)"
            throw AgentStructuredModelClientError.network(message)
        } catch {
            throw AgentStructuredModelClientError.network(
                "模型网络请求失败：\(error.localizedDescription)"
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentStructuredModelClientError.invalidResponse
        }
        await MainActor.run {
            RemoteResponseDebugStore.shared.saveRaw(
                endpoint: request.url?.absoluteString ?? configuration.baseURL,
                wireAPI: configuration.wireAPI,
                statusCode: httpResponse.statusCode,
                data: data,
                knownSecrets: [configuration.apiKey]
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AgentStructuredModelClientError.httpStatus(
                httpResponse.statusCode,
                responseMessage(from: data)
            )
        }

        let decisionText = try extractDecisionText(from: data)
        return try decodeDecision(
            decisionText,
            expectedRunID: modelRequest.runID,
            contextSnapshot: modelRequest.contextSnapshot
        )
    }

    private func makeURLRequest(
        for modelRequest: AgentModelRequest,
        repairFeedback: String?
    ) throws -> URLRequest {
        try validateConfiguration()
        let endpoint = normalizedEndpoint()
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            throw AgentStructuredModelClientError.invalidURL(endpoint)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let userData = try encoder.encode(modelRequest)
        guard let userContent = String(data: userData, encoding: .utf8) else {
            throw AgentStructuredModelClientError.invalidDecision("无法编码模型决策输入。")
        }
        let systemPrompt = try makeSystemPrompt(
            toolResults: modelRequest.toolResults,
            contextSnapshot: modelRequest.contextSnapshot,
            encoder: encoder,
            repairFeedback: repairFeedback
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        switch wireAPI {
        case .chatCompletions:
            request.httpBody = try encoder.encode(
                ChatRequestBody(
                    model: configuration.modelID,
                    messages: [
                        .init(role: "system", content: systemPrompt),
                        .init(role: "user", content: userContent)
                    ],
                    temperature: repairFeedback == nil ? configuration.temperature : 0,
                    maxTokens: max(configuration.maxTokens, 2_048),
                    responseFormat: .init(type: "json_object")
                )
            )
        case .responses:
            request.httpBody = try encoder.encode(
                ResponsesRequestBody(
                    model: configuration.modelID,
                    instructions: systemPrompt,
                    input: userContent,
                    // Some OpenAI-compatible Responses proxies reject json_object here.
                    // The prompt and local decoder still enforce a strict JSON decision.
                    text: .init(format: .init(type: "text")),
                    temperature: repairFeedback == nil ? configuration.temperature : 0,
                    maxOutputTokens: max(configuration.maxTokens, 4_096),
                    store: false
                )
            )
        }
        return request
    }

    private func validateConfiguration() throws {
        let provider = configuration.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.isEmpty == false, model.isEmpty == false, key.isEmpty == false else {
            throw AgentStructuredModelClientError.invalidConfiguration("模型配置不完整。")
        }
        guard configuration.maxTokens > 0,
              configuration.timeoutSeconds > 0,
              configuration.temperature.isFinite else {
            throw AgentStructuredModelClientError.invalidConfiguration("模型参数无效。")
        }
    }

    private var wireAPI: WireAPI {
        WireAPI(rawValue: configuration.wireAPI.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? .chatCompletions
    }

    private func normalizedEndpoint() -> String {
        let baseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.isEmpty {
            let path = wireAPI == .responses ? "responses" : "chat/completions"
            return "https://api.openai.com/v1/\(path)"
        }
        if baseURL.hasSuffix("/chat/completions") || baseURL.hasSuffix("/responses") {
            return baseURL
        }
        let path = wireAPI == .responses ? "v1/responses" : "v1/chat/completions"
        return baseURL.hasSuffix("/") ? "\(baseURL)\(path)" : "\(baseURL)/\(path)"
    }

    private func makeSystemPrompt(
        toolResults: [AgentToolResult],
        contextSnapshot: AgentContextSnapshot?,
        encoder: JSONEncoder,
        repairFeedback: String?
    ) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        let timestamp = formatter.string(from: now())
        let resultsData = try encoder.encode(toolResults)
        let resultsJSON = String(data: resultsData, encoding: .utf8) ?? "[]"
        let contextJSON: String
        if let contextSnapshot {
            let contextData = try encoder.encode(contextSnapshot)
            contextJSON = String(data: contextData, encoding: .utf8) ?? "null"
        } else {
            contextJSON = "null"
        }

        let repairInstruction = repairFeedback.map {
            "上一次输出未通过本地协议校验：\($0) 这是唯一一次纠错机会。请重新生成完整决策，只输出可被 JSONDecoder 解析的 JSON。"
        } ?? ""

        return """
        你是 AIGTD 0.5 的结构化决策器。只能依据用户输入和真实工具结果决定下一步，不能声称尚未成功的操作已经完成。

        当前本地时间：\(timestamp)
        当前时区：\(timeZone.identifier)

        只允许输出一个 AgentModelDecision JSON 对象。禁止 markdown、代码围栏、前后解释、推理过程、analysis、reasoning 或隐藏思考。不得输出 JSON 之外的任何字符。
        顶层字段必须且只能是：schema_version、run_id、goal、phase、assistant_draft、tool_calls、final_reply。
        schema_version 必须为 1，run_id 必须原样复用输入。phase 仅允许 tool_calls、awaiting_clarification、awaiting_confirmation、final。
        phase=tool_calls 时 tool_calls 必须非空且 final_reply 必须为 null；phase=final 时 tool_calls 必须为空且 final_reply 必须是非空字符串。
        每个工具调用必须包含唯一非空 call_id、tool 和 arguments。可选 depends_on 只能引用同一计划中更早的 call_id；前置调用失败时后续调用会被跳过。只能使用下列工具 schema：
        \(Self.toolSchemas)
        propose_schedule 必须在 items 中逐项提供 reminder_id 与 target_due_date；不能只传 reminder_ids、start_date 或 strategy，也不能提交空 items。用户指定了每项时间时必须原样映射到对应任务。
        任何基于 search_reminders 或 get_reminder_details 结果的写操作，都必须把读取到的当前值放入 expected_list_id、expected_due_date、expected_completion，并设置 must_exist=true。字段没有值时可省略对应 expected 字段，但不得省略 must_exist。这样确认期间发生的系统外部修改才能被本地拒绝覆盖。
        reminderLists 是完整的系统提醒清单目录，空清单也会包含在内。用户明确指定清单时：目录中已有该清单必须优先使用其 list_id；目录中没有该清单必须先调用 create_list，并让后续 create_reminder 或 move_reminder 通过 depends_on 依赖该 create_list。禁止把任务静默放入默认清单。

        当前会话与任务上下文（已由客户端按隐私设置过滤）：
        \(contextJSON)
        “刚才那条”“第二条”等指代必须优先使用 references 与 recent_turns；目标仍不唯一时必须澄清，禁止自行选择。

        历史真实 tool results（只可据此陈述执行结果）：
        \(resultsJSON)

        \(repairInstruction)
        """
    }

    private func extractDecisionText(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentStructuredModelClientError.invalidEnvelope("模型响应不是有效 JSON 信封。")
        }
        if root["status"] as? String == "incomplete" {
            let details = root["incomplete_details"] as? [String: Any]
            let reason = details?["reason"] as? String ?? "output_incomplete"
            throw AgentStructuredModelClientError.invalidEnvelope(
                "模型结构化输出被截断（\(reason)）。"
            )
        }

        switch wireAPI {
        case .chatCompletions:
            guard let choices = root["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = textContent(message["content"]),
                  content.isEmpty == false else {
                throw AgentStructuredModelClientError.invalidEnvelope("模型响应缺少 choices[0].message.content。")
            }
            return content
        case .responses:
            if let outputText = root["output_text"] as? String, outputText.isEmpty == false {
                return outputText
            }
            guard let output = root["output"] as? [[String: Any]] else {
                throw AgentStructuredModelClientError.invalidEnvelope("模型响应缺少 output_text。")
            }
            let parts = output.flatMap { item -> [String] in
                guard let content = item["content"] as? [[String: Any]] else { return [] }
                return content.compactMap { part in
                    guard let type = part["type"] as? String,
                          type == "output_text" || type == "text" else { return nil }
                    return part["text"] as? String
                }
            }
            guard parts.isEmpty == false else {
                throw AgentStructuredModelClientError.invalidEnvelope("模型响应缺少可读取的 output_text。")
            }
            return parts.joined()
        }
    }

    private func textContent(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let parts = value as? [[String: Any]] else { return nil }
        let text = parts.compactMap { part -> String? in
            if let value = part["text"] as? String { return value }
            if let nested = part["text"] as? [String: Any] { return nested["value"] as? String }
            return nil
        }
        return text.isEmpty ? nil : text.joined()
    }

    private func decodeDecision(
        _ rawText: String,
        expectedRunID: UUID,
        contextSnapshot: AgentContextSnapshot?
    ) throws -> AgentModelDecision {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              trimmed.contains("```") == false else {
            throw AgentStructuredModelClientError.invalidDecision(
                "模型决策必须是纯 JSON 对象，不能包含 markdown 或解释文本。"
            )
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentStructuredModelClientError.invalidDecision("模型决策 JSON 无法解析。")
        }

        let allowedKeys: Set<String> = [
            "schema_version", "run_id", "goal", "phase",
            "assistant_draft", "tool_calls", "final_reply"
        ]
        let actualKeys = Set(object.keys)
        let unknownKeys = actualKeys.subtracting(allowedKeys)
        guard unknownKeys.isEmpty else {
            throw AgentStructuredModelClientError.invalidDecision(
                "模型决策包含不允许的字段：\(unknownKeys.sorted().joined(separator: ", "))。"
            )
        }
        let missingKeys = allowedKeys.subtracting(actualKeys)
        guard missingKeys.isEmpty else {
            throw AgentStructuredModelClientError.invalidDecision(
                "模型决策缺少字段：\(missingKeys.sorted().joined(separator: ", "))。"
            )
        }
        try validateToolCallObjects(
            object["tool_calls"],
            contextSnapshot: contextSnapshot
        )

        let decision: AgentModelDecision
        do {
            decision = try JSONDecoder().decode(AgentModelDecision.self, from: data)
        } catch {
            throw AgentStructuredModelClientError.invalidDecision(
                "模型决策字段不符合协议：\(error.localizedDescription)"
            )
        }
        try validate(decision, expectedRunID: expectedRunID)
        return decision
    }

    private func validateToolCallObjects(
        _ value: Any?,
        contextSnapshot: AgentContextSnapshot?
    ) throws {
        guard let calls = value as? [[String: Any]] else {
            throw AgentStructuredModelClientError.invalidDecision("模型决策 tool_calls 必须是数组。")
        }
        let requiredKeys: Set<String> = ["call_id", "tool", "arguments"]
        let allowedKeys = requiredKeys.union(["depends_on"])
        let allowedTools: Set<String> = [
            AgentToolName.searchReminders.rawValue,
            AgentToolName.getReminderDetails.rawValue,
            AgentToolName.createList.rawValue,
            AgentToolName.createReminder.rawValue,
            AgentToolName.updateReminder.rawValue,
            AgentToolName.moveReminder.rawValue,
            AgentToolName.completeReminder.rawValue,
            AgentToolName.deleteReminder.rawValue,
            AgentToolName.proposeSchedule.rawValue,
            AgentToolName.applySchedule.rawValue
        ]
        var earlierCallIDs = Set<String>()
        var createdListCallIDs: [String: String] = [:]
        for call in calls {
            guard Set(call.keys).isSubset(of: allowedKeys),
                  requiredKeys.isSubset(of: Set(call.keys)),
                  call["call_id"] is String,
                  let tool = call["tool"] as? String,
                  let arguments = call["arguments"] as? [String: Any] else {
                throw AgentStructuredModelClientError.invalidDecision("工具调用字段不符合协议。")
            }
            if let dependencies = call["depends_on"], dependencies is [String] == false {
                throw AgentStructuredModelClientError.invalidDecision("工具 depends_on 必须是 call_id 数组。")
            }
            if let dependencies = call["depends_on"] as? [String],
               Set(dependencies).isSubset(of: earlierCallIDs) == false {
                throw AgentStructuredModelClientError.invalidDecision("工具 depends_on 只能引用更早的 call_id。")
            }
            guard allowedTools.contains(tool) else {
                throw AgentStructuredModelClientError.invalidDecision("模型请求了未知工具：\(tool)。")
            }
            try validateRequiredArguments(tool: tool, arguments: arguments)
            if let callID = call["call_id"] as? String {
                if tool == AgentToolName.createList.rawValue,
                   let title = arguments["title"] as? String {
                    createdListCallIDs[normalizedListTitle(title)] = callID
                }
                try validateListDependency(
                    tool: tool,
                    arguments: arguments,
                    dependencies: call["depends_on"] as? [String] ?? [],
                    createdListCallIDs: createdListCallIDs,
                    contextSnapshot: contextSnapshot
                )
                earlierCallIDs.insert(callID)
            }
        }
    }

    private func validateListDependency(
        tool: String,
        arguments: [String: Any],
        dependencies: [String],
        createdListCallIDs: [String: String],
        contextSnapshot: AgentContextSnapshot?
    ) throws {
        guard tool == AgentToolName.createReminder.rawValue || tool == AgentToolName.moveReminder.rawValue,
              contextSnapshot?.privacy.reminderSnapshotIsStale == false,
              let lists = contextSnapshot?.reminderLists,
              let listTitle = arguments["list_title"] as? String,
              listTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        let normalizedTitle = normalizedListTitle(listTitle)
        if lists.contains(where: { normalizedListTitle($0.title) == normalizedTitle }) {
            return
        }
        guard let createCallID = createdListCallIDs[normalizedTitle],
              dependencies.contains(createCallID) else {
            throw AgentStructuredModelClientError.invalidDecision(
                "清单“\(listTitle)”不存在。必须先调用 create_list，并让该操作通过 depends_on 依赖它。"
            )
        }
    }

    private func normalizedListTitle(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func validateRequiredArguments(tool: String, arguments: [String: Any]) throws {
        func requiresString(_ key: String) throws {
            guard let value = arguments[key] as? String,
                  value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw AgentStructuredModelClientError.invalidDecision(
                    "工具 \(tool) 缺少必填参数：\(key)。"
                )
            }
        }

        switch tool {
        case AgentToolName.getReminderDetails.rawValue:
            guard let ids = arguments["reminder_ids"] as? [String],
                  ids.isEmpty == false,
                  ids.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
                throw AgentStructuredModelClientError.invalidDecision(
                    "工具 get_reminder_details 缺少有效的 reminder_ids。"
                )
            }
        case AgentToolName.createList.rawValue, AgentToolName.createReminder.rawValue:
            try requiresString("title")
        case AgentToolName.updateReminder.rawValue,
             AgentToolName.moveReminder.rawValue,
             AgentToolName.completeReminder.rawValue,
             AgentToolName.deleteReminder.rawValue:
            try requiresString("reminder_id")
            if tool == AgentToolName.completeReminder.rawValue, arguments["is_completed"] is Bool == false {
                throw AgentStructuredModelClientError.invalidDecision(
                    "工具 complete_reminder 缺少必填参数：is_completed。"
                )
            }
        case AgentToolName.proposeSchedule.rawValue:
            guard let items = arguments["items"] as? [[String: Any]], items.isEmpty == false else {
                throw AgentStructuredModelClientError.invalidDecision(
                    "工具 propose_schedule 缺少非空必填参数：items。"
                )
            }
            for item in items {
                guard let reminderID = item["reminder_id"] as? String,
                      reminderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      let targetDueDate = item["target_due_date"] as? String,
                      targetDueDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    throw AgentStructuredModelClientError.invalidDecision(
                        "propose_schedule 的每个 item 都必须包含 reminder_id 和 target_due_date。"
                    )
                }
            }
        case AgentToolName.applySchedule.rawValue:
            try requiresString("plan_id")
        default:
            break
        }
    }

    private func validate(_ decision: AgentModelDecision, expectedRunID: UUID) throws {
        guard decision.schemaVersion == 1 else {
            throw AgentStructuredModelClientError.invalidDecision("模型决策 schema_version 必须为 1。")
        }
        guard decision.runID == expectedRunID else {
            throw AgentStructuredModelClientError.invalidDecision("模型决策 run_id 与当前运行不一致。")
        }
        guard decision.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentStructuredModelClientError.invalidDecision("模型决策 goal 不能为空。")
        }
        let callIDs = decision.toolCalls.map { $0.callID.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard callIDs.allSatisfy({ $0.isEmpty == false }), Set(callIDs).count == callIDs.count else {
            throw AgentStructuredModelClientError.invalidDecision("工具 call_id 必须非空且在本轮唯一。")
        }

        switch decision.phase {
        case .toolCalls:
            guard decision.toolCalls.isEmpty == false, nonempty(decision.finalReply) == nil else {
                throw AgentStructuredModelClientError.invalidDecision("tool_calls 阶段必须提供工具调用且不能提供最终回复。")
            }
        case .final:
            guard decision.toolCalls.isEmpty, nonempty(decision.finalReply) != nil else {
                throw AgentStructuredModelClientError.invalidDecision("final 阶段必须提供最终回复且不能包含工具调用。")
            }
        case .awaitingClarification, .awaitingConfirmation:
            guard decision.toolCalls.isEmpty,
                  nonempty(decision.assistantDraft) != nil || nonempty(decision.finalReply) != nil else {
                throw AgentStructuredModelClientError.invalidDecision("等待阶段必须提供用户可见提示且不能包含工具调用。")
            }
        }
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func responseMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return sanitized(message)
        }
        return sanitized(String(data: data, encoding: .utf8) ?? "")
    }

    private func sanitized(_ value: String) -> String {
        let withoutSecret = value.replacingOccurrences(of: configuration.apiKey, with: "[REDACTED]")
        let singleLine = withoutSecret.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(240))
    }

    private static let toolSchemas = #"""
    [
      {"name":"search_reminders","risk":"read_only","arguments":{"query":"string?","list_id":"string?","list_title":"string?","date_from":"ISO8601?","date_to":"ISO8601?","include_completed":"boolean?","limit":"integer 1...50?"}},
      {"name":"get_reminder_details","risk":"read_only","arguments":{"reminder_ids":"string[1...10]"}},
      {"name":"create_list","risk":"medium_risk_write","arguments":{"title":"string"}},
      {"name":"create_reminder","risk":"low_risk_write","arguments":{"title":"string","due_date":"ISO8601?","includes_time":"boolean?","list_id":"string?","list_title":"string?","notes":"string?"}},
      {"name":"update_reminder","risk":"low_risk_write","arguments":{"reminder_id":"string","title":"string?","due_date":"ISO8601|null?","clear_due_date":"boolean?","includes_time":"boolean?","notes":"string|null?","expected_list_id":"string?","expected_due_date":"ISO8601?","expected_completion":"boolean?","must_exist":"boolean"}},
      {"name":"move_reminder","risk":"low_risk_write","arguments":{"reminder_id":"string","list_id":"string?","list_title":"string?","expected_list_id":"string?","expected_due_date":"ISO8601?","expected_completion":"boolean?","must_exist":"boolean"}},
      {"name":"complete_reminder","risk":"low_risk_write","arguments":{"reminder_id":"string","is_completed":"boolean","expected_list_id":"string?","expected_due_date":"ISO8601?","expected_completion":"boolean?","must_exist":"boolean"}},
      {"name":"delete_reminder","risk":"high_risk_write","arguments":{"reminder_id":"string","expected_list_id":"string?","expected_due_date":"ISO8601?","expected_completion":"boolean?","must_exist":"boolean"}},
      {"name":"propose_schedule","risk":"read_only","arguments":{"items":[{"item_id":"string?","reminder_id":"string","target_due_date":"ISO8601","includes_time":"boolean?","expected_due_date":"ISO8601?","dependency_ids":"string[]?"}]}},
      {"name":"apply_schedule","risk":"medium_risk_write","arguments":{"plan_id":"string"}}
    ]
    """#
}

private struct ChatRequestBody: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int
    let responseFormat: ResponseFormat

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    private enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

private struct ResponsesRequestBody: Encodable {
    let model: String
    let instructions: String
    let input: String
    let text: TextConfiguration
    let temperature: Double
    let maxOutputTokens: Int
    let store: Bool

    struct TextConfiguration: Encodable {
        let format: Format
    }

    struct Format: Encodable {
        let type: String
    }

    private enum CodingKeys: String, CodingKey {
        case model, instructions, input, text, temperature, store
        case maxOutputTokens = "max_output_tokens"
    }
}
