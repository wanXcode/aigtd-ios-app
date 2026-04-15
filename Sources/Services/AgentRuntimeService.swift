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
    func respond(
        to content: String,
        reminderLists: [ReminderListInfo],
        reminderItems: [ReminderItemInfo],
        configuration: AgentModelConfiguration?,
        agentContext: AIGTDAgentRuntimeContext? = nil,
        onTextUpdate: (@MainActor @Sendable (String) async -> Void)? = nil
    ) async -> MockAgentResult {
        guard let configuration,
              configuration.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            let message = readableRemoteFailureMessage(from: AgentRuntimeError.invalidConfiguration)
            return MockAgentResult(
                reply: message.reply,
                summary: message.summary,
                actionType: nil,
                payloadJSON: "{}",
                confidence: 0.0,
                followUpPrompt: message.followUpPrompt
            )
        }

        do {
            return try await requestRemoteResponse(
                content: content,
                reminderLists: reminderLists,
                reminderItems: reminderItems,
                configuration: configuration,
                agentContext: agentContext,
                onTextUpdate: onTextUpdate
            )
        } catch {
            let message = readableRemoteFailureMessage(from: error)
            return MockAgentResult(
                reply: message.reply,
                summary: message.summary,
                actionType: nil,
                payloadJSON: "{}",
                confidence: 0.0,
                followUpPrompt: message.followUpPrompt
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
        await MainActor.run {
            RemoteResponseDebugStore.shared.saveRaw(
                endpoint: normalizedEndpoint(from: configuration),
                wireAPI: normalizedWireAPI(from: configuration).rawValue,
                statusCode: httpResponse.statusCode,
                data: data
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AgentRuntimeError.httpStatus(
                httpResponse.statusCode,
                responseBodySummary(from: data)
            )
        }

        let returnedText = try extractHealthCheckText(from: data, configuration: configuration)
        guard returnedText.isEmpty == false else {
            throw AgentRuntimeError.invalidPayload("")
        }

        return "连接成功，可正常访问 \(configuration.modelID)"
    }

    private func requestRemoteResponse(
        content: String,
        reminderLists: [ReminderListInfo],
        reminderItems: [ReminderItemInfo],
        configuration: AgentModelConfiguration,
        agentContext: AIGTDAgentRuntimeContext?,
        onTextUpdate: (@MainActor @Sendable (String) async -> Void)?
    ) async throws -> MockAgentResult {
        if normalizedWireAPI(from: configuration) == .responses {
            return try await requestRemoteStreamingResponse(
                content: content,
                reminderLists: reminderLists,
                reminderItems: reminderItems,
                configuration: configuration,
                agentContext: agentContext,
                onTextUpdate: onTextUpdate
            )
        }

        let endpoint = normalizedEndpoint(from: configuration)
        let request = try makeRequest(
            content: content,
            reminderLists: reminderLists,
            reminderItems: reminderItems,
            configuration: configuration,
            agentContext: agentContext
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = configuration.timeoutSeconds

        let (data, response) = try await URLSession(configuration: sessionConfiguration).data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentRuntimeError.invalidResponse
        }
        await MainActor.run {
            RemoteResponseDebugStore.shared.saveRaw(
                endpoint: endpoint,
                wireAPI: normalizedWireAPI(from: configuration).rawValue,
                statusCode: httpResponse.statusCode,
                data: data
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AgentRuntimeError.httpStatus(
                httpResponse.statusCode,
                responseBodySummary(from: data)
            )
        }

        let returnedText: String
        do {
            returnedText = try parseReturnedText(from: data, configuration: configuration)
        } catch let runtimeError as AgentRuntimeError {
            switch runtimeError {
            case .invalidPayload:
                throw AgentRuntimeError.invalidPayload(responseBodySummary(from: data))
            default:
                throw runtimeError
            }
        }
        if let structuredResult = makeStructuredResult(from: returnedText) {
            return structuredResult
        }
        if let onTextUpdate {
            await onTextUpdate(returnedText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return MockAgentResult(
            reply: returnedText.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: "远端自然回复",
            actionType: nil,
            payloadJSON: "{}",
            confidence: 0.82,
            followUpPrompt: nil
        )
    }

    private func requestRemoteStreamingResponse(
        content: String,
        reminderLists: [ReminderListInfo],
        reminderItems: [ReminderItemInfo],
        configuration: AgentModelConfiguration,
        agentContext: AIGTDAgentRuntimeContext?,
        onTextUpdate: (@MainActor @Sendable (String) async -> Void)?
    ) async throws -> MockAgentResult {
        let endpoint = normalizedEndpoint(from: configuration)
        let request = try makeRequest(
            content: content,
            reminderLists: reminderLists,
            reminderItems: reminderItems,
            configuration: configuration,
            agentContext: agentContext,
            forceStreaming: true
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = configuration.timeoutSeconds

        let (bytes, response) = try await URLSession(configuration: sessionConfiguration).bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentRuntimeError.invalidResponse
        }

        var rawLines: [String] = []
        var currentEvent = "message"
        var currentDataLines: [String] = []
        var latestResolvedText = ""
        var lastPayloadSummary = ""

        func consumeCurrentEvent() async {
            guard currentDataLines.isEmpty == false else { return }
            let payload = currentDataLines.joined(separator: "\n")
            rawLines.append("event: \(currentEvent)")
            rawLines.append("data: \(payload)")
            rawLines.append("")
            lastPayloadSummary = payload
            if let extracted = extractReadableTextFromSSEPayload(payload, eventName: currentEvent, currentText: latestResolvedText),
               extracted != latestResolvedText {
                latestResolvedText = extracted
                if let onTextUpdate,
                   makeStructuredResult(from: latestResolvedText) == nil {
                    await onTextUpdate(latestResolvedText)
                }
            }
            currentEvent = "message"
            currentDataLines.removeAll(keepingCapacity: true)
        }

        for try await line in bytes.lines {
            if line.isEmpty {
                await consumeCurrentEvent()
                continue
            }

            if line.hasPrefix("event:") {
                await consumeCurrentEvent()
                currentEvent = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if line.hasPrefix("data:") {
                let dataLine = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                if dataLine == "[DONE]" {
                    rawLines.append("event: \(currentEvent)")
                    rawLines.append("data: [DONE]")
                    rawLines.append("")
                    await consumeCurrentEvent()
                    break
                }
                currentDataLines.append(dataLine)
            }
        }
        await consumeCurrentEvent()

        let rawBody = rawLines.joined(separator: "\n")
        await MainActor.run {
            RemoteResponseDebugStore.shared.save(
                endpoint: endpoint,
                wireAPI: normalizedWireAPI(from: configuration).rawValue,
                statusCode: httpResponse.statusCode,
                body: rawBody
            )
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AgentRuntimeError.httpStatus(
                httpResponse.statusCode,
                rawBody.isEmpty ? lastPayloadSummary : rawBody
            )
        }

        let resolvedText = latestResolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedText.isEmpty == false else {
            throw AgentRuntimeError.invalidPayload(rawBody.isEmpty ? lastPayloadSummary : rawBody)
        }
        if let structuredResult = makeStructuredResult(from: resolvedText) {
            return structuredResult
        }
        if let onTextUpdate {
            await onTextUpdate(resolvedText)
        }

        return MockAgentResult(
            reply: resolvedText,
            summary: "远端流式自然回复",
            actionType: nil,
            payloadJSON: "{}",
            confidence: 0.82,
            followUpPrompt: nil
        )
    }

    private func makeRequest(
        content: String,
        reminderLists: [ReminderListInfo],
        reminderItems: [ReminderItemInfo],
        configuration: AgentModelConfiguration,
        agentContext: AIGTDAgentRuntimeContext?,
        forceStreaming: Bool = false
    ) throws -> URLRequest {
        let endpoint = normalizedEndpoint(from: configuration)
        guard let url = URL(string: endpoint) else {
            throw AgentRuntimeError.invalidURL
        }

        let availableLists = reminderLists.map(\.title).joined(separator: "、")
        let systemPrompt = buildSystemPrompt(
            availableLists: availableLists,
            reminderItems: reminderItems,
            agentContext: agentContext
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try makeRequestBody(
            systemPrompt: systemPrompt,
            userContent: content,
            configuration: configuration,
            streamOverride: forceStreaming
        )
        return request
    }

    private func buildSystemPrompt(
        availableLists: String,
        reminderItems: [ReminderItemInfo],
        agentContext: AIGTDAgentRuntimeContext?
    ) -> String {
        let now = Date()
        let currentTimeZone = TimeZone.current
        let isoFormatter = ISO8601DateFormatter()
        let currentTimestamp = isoFormatter.string(from: now)
        let displayTimestamp = now.formatted(date: .complete, time: .shortened)
        let openItemCount = reminderItems.filter { !$0.isCompleted }.count
        let todayItems = reminderItems.filter { item in
            guard let dueDate = item.dueDate else { return false }
            return Calendar.current.isDateInToday(dueDate)
        }
        let recentPreview = reminderItems
            .filter { !$0.isCompleted }
            .prefix(8)
            .map { item in
                let list = item.listTitle.isEmpty ? "默认清单" : item.listTitle
                return "- \(item.title) · \(list)"
            }
            .joined(separator: "\n")

        let memoryBlock = agentContext?.memory.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let operatingGuideBlock = agentContext?.operatingGuide.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return """
        你是 AIGTD，一个长期在线的个人事务管理助手。你现在在 iPhone App 里和用户直接对话。

        你的目标：
        - 准确判断用户是否要创建任务、创建清单、查看事项、移动任务、完成任务，或只是普通聊天
        - 先做结构化理解，再交给本地执行层落地
        - 对于会修改系统状态的动作，不要提前宣称“已经成功执行”
        - 输出必须是单个 JSON 对象，不要输出代码块，不要输出额外解释

        当前提醒事项列表：\(availableLists.isEmpty ? "无" : availableLists)
        当前未完成事项数：\(openItemCount)
        今天到期事项数：\(todayItems.count)
        最近事项预览：
        \(recentPreview.isEmpty ? "- 暂无" : recentPreview)
        当前本地时间：\(displayTimestamp)
        当前 ISO 时间：\(currentTimestamp)
        当前时区：\(currentTimeZone.identifier)

        用户记忆：
        \(memoryBlock.isEmpty ? "暂无额外记忆" : memoryBlock)

        协作原则：
        \(operatingGuideBlock.isEmpty ? "- 直接接住用户的话，默认按事务管理语境理解。" : operatingGuideBlock)

        你必须返回一个单独的 JSON 对象，字段如下：
        {
          "reply": "给用户看的简短草稿回复。若 intent 会修改系统状态，只能表达“我来处理”，不能宣称已经成功。",
          "summary": "内部摘要，简短明确",
          "confidence": 0 到 1 的小数,
          "followUpPrompt": "可选字符串，没有就填 null",
          "matchedSignals": ["命中的意图信号"],
          "action": {
            "intent": "create_reminder | create_list | summarize_lists | capture_message | move_reminder | complete_reminder | fallback",
            "title": "动作标题",
            "entities": {
              "title": "任务标题",
              "due_date": "ISO8601 时间字符串，没有就留空字符串",
              "preferred_list_name": "期望清单名，没有就留空字符串",
              "note": "备注，没有就留空字符串",
              "source_text": "用户原话"
            },
            "requiresConfirmation": false
          }
        }

        约束：
        - summarize_lists / capture_message / fallback 也必须返回上述 JSON
        - 如果用户是在查看任务，就不要伪装成 create_reminder
        - 如果用户只是打招呼、试探、闲聊，intent 应为 capture_message 或 fallback
        - 所有相对日期都必须以上面的“当前本地时间”和“当前时区”为准
        - “今天 / 明天 / 后天 / 下周X”必须换算成正确的未来 ISO8601 时间，不能瞎猜年份
        - 如果用户没有给具体时刻，但给了日期，due_date 默认用当地时间 09:00:00
        - 不要把相对日期解析到过去
        - 对 create_reminder，entities 至少包含 title、due_date、preferred_list_name、note、source_text
        - 对 create_list，entities 至少包含 list_name
        - 对 move_reminder，entities 至少包含 target、destination_list
        - 对 complete_reminder，entities 至少包含 target
        - 只输出 JSON，不要输出 markdown，不要输出 ```json
        """
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
        temperatureOverride: Double? = nil,
        streamOverride: Bool? = nil
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
                maxTokens: maxTokensOverride ?? configuration.maxTokens
            )
            return try JSONEncoder().encode(requestBody)
        case .responses:
            let requestBody = OpenAIResponsesRequest(
                model: configuration.modelID,
                instructions: systemPrompt,
                input: userContent,
                text: .init(format: .init(type: "text")),
                temperature: temperatureOverride ?? configuration.temperature,
                maxOutputTokens: maxTokensOverride ?? configuration.maxTokens,
                store: false,
                stream: streamOverride
            )
            return try JSONEncoder().encode(requestBody)
        }
    }

    private func parseReturnedText(from data: Data, configuration: AgentModelConfiguration) throws -> String {
        if let strictParsed = try? parseReturnedTextStrictly(from: data),
           strictParsed.isEmpty == false {
            return strictParsed
        }

        if let object = try? JSONSerialization.jsonObject(with: data),
           let extracted = extractReadableTextFromOfficialCompatibleShape(object),
           extracted.isEmpty == false {
            return extracted
        }

        if let raw = String(data: data, encoding: .utf8),
           let extracted = extractReadableTextFromRawJSONString(raw),
           extracted.isEmpty == false {
            return extracted
        }

        throw AgentRuntimeError.invalidPayload("")
    }

    private func parseReturnedTextStrictly(from data: Data) throws -> String {
        if let completion = try? JSONDecoder().decode(OpenAICompatibleChatResponse.self, from: data) {
            if let content = completion.choices.first?.resolvedText ?? completion.text,
               content.isEmpty == false {
                return content
            }
        }

        if let response = try? JSONDecoder().decode(OpenAIResponsesResponse.self, from: data) {
            let text = response.output
                .flatMap(\.content)
                .filter { $0.type == "output_text" || $0.type == "text" }
                .compactMap(\.text)
                .joined(separator: "\n")
            let fallbackText = response.outputText?.joined(separator: "\n") ?? ""
            let resolvedText = text.isEmpty == false ? text : fallbackText
            if resolvedText.isEmpty == false {
                return resolvedText
            }
        }

        throw AgentRuntimeError.invalidPayload("")
    }

    private func extractReadableTextFromOfficialCompatibleShape(_ object: Any) -> String? {
        if let chatText = extractChatCompletionText(fromJSONObject: object) {
            return chatText
        }
        if let responsesText = extractResponsesText(fromJSONObject: object) {
            return responsesText
        }

        guard let dict = object as? [String: Any] else { return nil }
        for key in ["reply", "response", "answer"] {
            if let value = dict[key] as? String,
               value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func extractChatCompletionText(fromJSONObject object: Any) -> String? {
        guard let dict = object as? [String: Any] else { return nil }
        if let choices = dict["choices"] as? [[String: Any]] {
            for choice in choices {
                if let message = choice["message"] as? [String: Any],
                   let content = extractChatMessageText(from: message) {
                    return content
                }
                if let text = choice["text"] as? String,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        if let text = dict["text"] as? String,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func extractResponsesText(fromJSONObject object: Any) -> String? {
        guard let dict = object as? [String: Any] else { return nil }
        if let outputText = extractChatMessageContent(dict["output_text"]) {
            return outputText
        }
        if let outputTextParts = dict["output_text"] as? [String] {
            let joined = outputTextParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if joined.isEmpty == false {
                return joined
            }
        }
        if let output = dict["output"] as? [[String: Any]] {
            var parts: [String] = []
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    for contentItem in content {
                        let type = (contentItem["type"] as? String)?.lowercased()
                        guard type == "output_text" || type == "text" else { continue }
                        if let text = extractChatMessageContent(contentItem["text"]) {
                            parts.append(text)
                        }
                    }
                }
            }
            let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if joined.isEmpty == false {
                return joined
            }
        }
        return nil
    }

    private func extractReadableTextFromRawJSONString(_ raw: String) -> String? {
        let candidateKeys = [
            "reasoning_content",
            "content",
            "output_text",
            "text",
            "answer",
            "response"
        ]

        for key in candidateKeys {
            if let value = firstJSONStringValue(forKey: key, in: raw)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               value.isEmpty == false {
                return value
            }
        }

        return nil
    }

    private func extractReadableTextFromSSEPayload(_ raw: String, eventName: String, currentText: String = "") -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let dict = object as? [String: Any] {
                if eventName == "response.output_text.delta",
                   let delta = dict["delta"] as? String,
                   delta.isEmpty == false {
                    return currentText + delta
                }

                if let type = dict["type"] as? String,
                   type == "response.output_text.delta",
                   let delta = dict["delta"] as? String,
                   delta.isEmpty == false {
                    return currentText + delta
                }
            }

            if let extracted = extractReadableTextFromOfficialCompatibleShape(object),
               extracted.isEmpty == false {
                return extracted
            }

            if let dict = object as? [String: Any] {
                for key in ["part", "delta", "item", "response"] {
                    if let nested = dict[key],
                       let extracted = extractReadableTextFromOfficialCompatibleShape(nested),
                       extracted.isEmpty == false {
                        return extracted
                    }
                }
            }
        }

        return extractReadableTextFromRawJSONString(trimmed)
    }

    private func firstJSONStringValue(forKey key: String, in raw: String) -> String? {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: raw) else {
            return nil
        }

        let escapedValue = String(raw[range])
        let wrapped = "\"\(escapedValue)\""
        if let data = wrapped.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return escapedValue.replacingOccurrences(of: "\\n", with: "\n")
    }

    private func extractChatMessageText(from message: [String: Any]) -> String? {
        if let content = extractChatMessageContent(message["content"]) {
            return content
        }

        let fallbackKeys = [
            "reasoning_content",
            "output_text",
            "text",
            "answer",
            "response"
        ]
        for key in fallbackKeys {
            if let text = extractChatMessageContent(message[key]) {
                return text
            }
        }

        return nil
    }

    private func extractChatMessageContent(_ content: Any?) -> String? {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let parts = content as? [String: Any] {
            for key in ["text", "content", "value"] {
                if let nested = extractChatMessageContent(parts[key]) {
                    return nested
                }
            }
        }
        if let parts = content as? [[String: Any]] {
            let texts = parts.compactMap { part -> String? in
                let type = (part["type"] as? String)?.lowercased()
                guard type == nil || type == "text" || type == "output_text" || type == "input_text" else { return nil }
                if let nestedText = extractChatMessageContent(part["text"]) {
                    return nestedText
                }
                if let nested = extractChatMessageContent(part["content"]) {
                    return nested
                }
                if let nested = extractChatMessageContent(part["value"]) {
                    return nested
                }
                return nil
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private func extractHealthCheckText(from data: Data, configuration: AgentModelConfiguration) throws -> String {
            if let parsed = try? parseReturnedText(from: data, configuration: configuration),
           parsed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return parsed
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = (object["error"] as? [String: Any])?["message"] as? String,
               message.isEmpty == false {
                return message
            }
            if let text = object["output_text"] as? String, text.isEmpty == false {
                return text
            }
            if let texts = object["output_text"] as? [String], texts.isEmpty == false {
                return texts.joined(separator: "\n")
            }
        }

        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false else {
            throw AgentRuntimeError.invalidPayload("")
        }
        return raw
    }

    private func readableRemoteFailureMessage(from error: Error) -> (reply: String, summary: String, followUpPrompt: String?) {
        if let runtimeError = error as? AgentRuntimeError {
            switch runtimeError {
            case .invalidConfiguration:
                return (
                    "还没连上可用模型，先去 Agent 页把模型配置完整再发这条消息。",
                    "模型配置不完整",
                    "至少需要 provider、model、API key 这三项。"
                )
            case let .invalidPayload(bodySummary):
                let trimmedSummary = bodySummary.trimmingCharacters(in: .whitespacesAndNewlines)
                let debugLine = trimmedSummary.isEmpty ? "" : "\n返回摘要：\(trimmedSummary)"
                return (
                    "远端模型已经连上了，但这次返回内容不是当前 Chat 能直接吃下来的格式。\(debugLine)",
                    "远端返回格式暂未兼容",
                    trimmedSummary.isEmpty ? "我下一步会按这个 provider 的真实返回继续兼容。" : "我已经把返回摘要带出来了，按这段继续兼容就行。"
                )
            case let .httpStatus(statusCode, body):
                return (
                    "远端模型这次回了 HTTP \(statusCode)。",
                    "远端请求失败：HTTP \(statusCode)",
                    body.isEmpty ? "你可以先去 Agent 里再测一次连接。" : body
                )
            default:
                break
            }
        }

        if let urlError = error as? URLError {
            return (
                "远端模型这次网络请求没走通，哥哥稍后再试一下。",
                "远端网络请求失败",
                urlError.localizedDescription
            )
        }

        return (
            "远端模型这次没有正常完成回复。",
            "远端模型暂时不可用",
            String(describing: error)
        )
    }

    private func responseBodySummary(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              text.isEmpty == false else {
            return "无返回内容"
        }

        if text.count > 1400 {
            let head = String(text.prefix(900))
            let tail = String(text.suffix(400))
            return "\(head)\n…\n\(tail)"
        }
        return text
    }

    private func makeStructuredResult(from rawText: String) -> MockAgentResult? {
        guard let envelope = parseRemoteAgentEnvelope(from: rawText) else {
            return nil
        }
        let mockEnvelope = envelope.toMockEnvelope()
        guard let data = try? JSONEncoder().encode(mockEnvelope),
              let payloadJSON = String(data: data, encoding: .utf8) else {
            return nil
        }

        return MockAgentResult(
            reply: envelope.replyText,
            summary: envelope.summaryText,
            actionType: mockEnvelope.action.intent,
            payloadJSON: payloadJSON,
            confidence: envelope.confidenceValue,
            followUpPrompt: envelope.followUpPrompt
        )
    }

    private func parseRemoteAgentEnvelope(from rawText: String) -> RemoteAgentEnvelope? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let candidates = [
            trimmed,
            sanitizedJSONObjectText(from: trimmed)
        ].compactMap { $0 }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(RemoteAgentEnvelope.self, from: data),
                  envelope.isMeaningful else {
                continue
            }
            return envelope
        }

        return nil
    }

    private func sanitizedJSONObjectText(from rawText: String) -> String? {
        var candidate = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            candidate = candidate
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let firstBrace = candidate.firstIndex(of: "{"),
              let lastBrace = candidate.lastIndex(of: "}"),
              firstBrace <= lastBrace else {
            return nil
        }

        let sliced = candidate[firstBrace...lastBrace]
        return String(sliced)
    }
}

private enum AgentRuntimeError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidPayload(String)
    case invalidConfiguration
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "请求地址无效，请检查 Base URL。"
        case .invalidResponse:
            return "服务返回了无法识别的响应。"
        case let .invalidPayload(bodySummary):
            if bodySummary.isEmpty {
                return "服务返回成功，但内容格式不是当前 App 可解析的结果。"
            }
            return "服务返回成功，但内容格式不是当前 App 可解析的结果。返回摘要：\(bodySummary)"
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

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct OpenAIMessage: Encodable {
    let role: String
    let content: String
}

private struct OpenAICompatibleChatResponse: Decodable {
    let choices: [Choice]
    let text: String?

    struct Choice: Decodable {
        let message: Message?
        let text: String?

        var resolvedText: String? {
            if let messageText = message?.resolvedContent, messageText.isEmpty == false {
                return messageText
            }
            if let text, text.isEmpty == false {
                return text
            }
            return nil
        }
    }

    struct Message: Decodable {
        let content: Content

        var resolvedContent: String? {
            content.textValue
        }
    }

    enum Content: Decodable {
        case text(String)
        case parts([Part])

        var textValue: String? {
            switch self {
            case let .text(value):
                return value
            case let .parts(parts):
                let joined = parts.compactMap(\.text).joined(separator: "\n")
                return joined.isEmpty ? nil : joined
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
                return
            }
            if let parts = try? container.decode([Part].self) {
                self = .parts(parts)
                return
            }
            throw DecodingError.typeMismatch(
                Content.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported content payload")
            )
        }
    }

    struct Part: Decodable {
        let type: String?
        let text: String?
    }
}

private struct OpenAIResponsesRequest: Encodable {
    let model: String
    let instructions: String?
    let input: String
    let text: OpenAIResponsesTextFormat?
    let temperature: Double
    let maxOutputTokens: Int
    let store: Bool?
    let stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case instructions
        case input
        case text
        case temperature
        case maxOutputTokens = "max_output_tokens"
        case store
        case stream
    }
}

private struct OpenAIResponsesTextFormat: Encodable {
    let format: OpenAIResponsesTextFormatValue
}

private struct OpenAIResponsesTextFormatValue: Encodable {
    let type: String
}

private struct OpenAIResponsesResponse: Decodable {
    let output: [OutputItem]
    let outputText: [String]?

    enum CodingKeys: String, CodingKey {
        case output
        case outputText = "output_text"
    }

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
    let reply: String?
    let summary: String?
    let confidence: Double?
    let followUpPrompt: String?
    let matchedSignals: [String]?
    let action: RemoteAgentAction

    var replyText: String {
        let trimmed = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty == false ? trimmed : "我来帮你处理一下。"
    }

    var summaryText: String {
        let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty == false ? trimmed : "远端结构化动作"
    }

    var confidenceValue: Double {
        confidence ?? 0.82
    }

    var isMeaningful: Bool {
        action.intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func toMockEnvelope() -> MockAgentEnvelope {
        MockAgentEnvelope(
            action: MockAgentActionPayload(
                intent: action.intent,
                title: {
                    let trimmed = action.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty == false ? trimmed : action.intent
                }(),
                entities: action.entities ?? [:],
                requiresConfirmation: action.requiresConfirmation ?? false
            ),
            confidence: confidenceValue,
            summary: summaryText,
            followUpPrompt: followUpPrompt,
            matchedSignals: matchedSignals ?? []
        )
    }
}

private struct RemoteAgentAction: Decodable {
    let intent: String
    let title: String?
    let entities: [String: String]?
    let requiresConfirmation: Bool?
}
