import XCTest
@testable import AIGTDReminders

final class AgentStructuredModelClientTests: XCTestCase {
    private let runID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testChatCompletionsBuildsAuthenticatedStructuredRequestWithSchemasResultsAndTime() async throws {
        let runID = runID
        let transport = RecordingModelTransport { request in
            let decision = Self.decisionJSON(runID: runID)
            return (Self.chatEnvelope(decision), Self.httpResponse(for: request, status: 200))
        }
        let client = makeClient(transport: transport)
        let result = AgentToolResult(
            runID: runID,
            callID: "search-1",
            tool: .searchReminders,
            status: .success,
            result: AgentToolArguments(["count": .integer(2)])
        )

        let decision = try await client.decide(
            AgentModelRequest(runID: runID, userInput: "查一下", modelTurn: 2, toolResults: [result])
        )
        let capturedRequest = await transport.lastRequest
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)
        let user = try XCTUnwrap(messages.last?["content"] as? String)

        XCTAssertEqual(decision.runID, runID)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
        XCTAssertTrue(system.contains("1970-01-01T08:00:00.000+08:00"))
        XCTAssertTrue(system.contains("Asia/Shanghai"))
        XCTAssertTrue(system.contains("search_reminders"))
        XCTAssertTrue(system.contains("apply_schedule"))
        XCTAssertTrue(system.contains("target_due_date"))
        XCTAssertTrue(system.contains("不能只传 reminder_ids"))
        XCTAssertTrue(system.contains("expected_due_date"))
        XCTAssertTrue(system.contains("must_exist=true"))
        XCTAssertTrue(system.contains("空清单也会包含在内"))
        XCTAssertTrue(system.contains("必须先调用 create_list"))
        XCTAssertTrue(system.contains("search-1"))
        XCTAssertTrue(system.contains("\"count\":2"))
        XCTAssertTrue(user.contains("\"model_turn\":2"))
        XCTAssertTrue(user.contains(runID.uuidString.lowercased()))
    }

    func testExistingEmptyListIsIncludedInModelContext() async throws {
        let runID = runID
        let transport = RecordingModelTransport { request in
            (Self.chatEnvelope(Self.decisionJSON(runID: runID)), Self.httpResponse(for: request, status: 200))
        }
        let snapshot = makeContextSnapshot(
            reminderLists: [ReminderListContextItem(id: "release", title: "0.5 发布")]
        )

        _ = try await makeClient(transport: transport).decide(
            AgentModelRequest(
                runID: runID,
                userInput: "新建任务",
                modelTurn: 1,
                toolResults: [],
                contextSnapshot: snapshot
            )
        )
        let capturedRequest = await transport.lastRequest
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)

        XCTAssertTrue(system.contains("\"reminderLists\":[{\"id\":\"release\",\"title\":\"0.5 发布\"}]"))
    }

    func testMissingListRequiresCreateListDependencyAndRepairsOnce() async throws {
        let runID = runID
        let invalid = Self.jsonString([
            "schema_version": 1,
            "run_id": runID.uuidString,
            "goal": "创建任务",
            "phase": "tool_calls",
            "assistant_draft": "准备创建",
            "tool_calls": [[
                "call_id": "create-a",
                "tool": "create_reminder",
                "arguments": ["title": "0.5 排期 A", "list_title": "0.5 发布"]
            ]],
            "final_reply": NSNull()
        ])
        let repaired = Self.jsonString([
            "schema_version": 1,
            "run_id": runID.uuidString,
            "goal": "创建任务",
            "phase": "tool_calls",
            "assistant_draft": "准备创建",
            "tool_calls": [
                [
                    "call_id": "create-list",
                    "tool": "create_list",
                    "arguments": ["title": "0.5 发布"]
                ],
                [
                    "call_id": "create-a",
                    "tool": "create_reminder",
                    "arguments": ["title": "0.5 排期 A", "list_title": "0.5 发布"],
                    "depends_on": ["create-list"]
                ]
            ],
            "final_reply": NSNull()
        ])
        let transport = SequencedModelTransport(responses: [
            { request in
                (Self.chatEnvelope(invalid), Self.httpResponse(for: request, status: 200))
            },
            { request in
                (Self.chatEnvelope(repaired), Self.httpResponse(for: request, status: 200))
            }
        ])
        let request = AgentModelRequest(
            runID: runID,
            userInput: "在 0.5 发布中新建任务",
            modelTurn: 1,
            toolResults: [],
            contextSnapshot: makeContextSnapshot(reminderLists: [])
        )

        let client = AgentStructuredModelClient(
            configuration: configuration(),
            transport: transport,
            now: { Date(timeIntervalSince1970: 0) },
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )
        let decision = try await client.decide(request)
        let requests = await transport.requests

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            decision.toolCalls.map(\.tool),
            [AgentToolName.createList, AgentToolName.createReminder]
        )
        XCTAssertEqual(decision.toolCalls.last?.dependencyCallIDs, ["create-list"])
    }

    func testResponsesAPIUsesResponsesShapeAndExtractsNestedOutputText() async throws {
        let runID = runID
        let transport = RecordingModelTransport { request in
            let text = Self.decisionJSON(runID: runID)
            let body = try JSONSerialization.data(withJSONObject: [
                "output": [["content": [["type": "output_text", "text": text]]]]
            ])
            return (body, Self.httpResponse(for: request, status: 200))
        }
        let client = makeClient(wireAPI: "responses", transport: transport)

        _ = try await client.decide(makeRequest())
        let capturedRequest = await transport.lastRequest
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v1/responses")
        XCTAssertNotNil(body["instructions"] as? String)
        XCTAssertNotNil(body["input"] as? String)
        XCTAssertEqual(((body["text"] as? [String: Any])?["format"] as? [String: String])?["type"], "text")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 4_096)
        XCTAssertEqual(body["store"] as? Bool, false)
    }

    func testRejectsMarkdownWrappedDecision() async {
        await assertDecisionError(text: "```json\n\(Self.decisionJSON(runID: runID))\n```", contains: "纯 JSON")
    }

    func testRejectsExplanationBeforeDecision() async {
        await assertDecisionError(text: "我先思考一下\n\(Self.decisionJSON(runID: runID))", contains: "纯 JSON")
    }

    func testRejectsReasoningOrAnyUnknownTopLevelField() async {
        var object = Self.decisionObject(runID: runID)
        object["reasoning"] = "secret"
        await assertDecisionError(text: Self.jsonString(object), contains: "reasoning")
    }

    func testRejectsMismatchedRunID() async {
        await assertDecisionError(
            text: Self.decisionJSON(runID: UUID()),
            contains: "run_id"
        )
    }

    func testRejectsFinalPhaseWithoutReply() async {
        let text = Self.decisionJSON(runID: runID, finalReply: nil)
        await assertDecisionError(text: text, contains: "final")
    }

    func testRejectsDuplicateToolCallIDs() async {
        let text = Self.toolCallDecisionJSON(runID: runID, callIDs: ["same", "same"])
        await assertDecisionError(text: text, contains: "唯一")
    }

    func testHTTPErrorUsesProviderMessageAndRedactsAPIKey() async {
        let transport = RecordingModelTransport { request in
            let body = try JSONSerialization.data(withJSONObject: [
                "error": ["message": "bad credential test-key"]
            ])
            return (body, Self.httpResponse(for: request, status: 401))
        }

        do {
            _ = try await makeClient(transport: transport).decide(makeRequest())
            XCTFail("Expected HTTP error")
        } catch let error as AgentStructuredModelClientError {
            XCTAssertEqual(error, .httpStatus(401, "bad credential [REDACTED]"))
            XCTAssertTrue(error.localizedDescription.contains("HTTP 401"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTimeoutBecomesReadableNetworkError() async {
        let transport = RecordingModelTransport { _ in throw URLError(.timedOut) }

        do {
            _ = try await makeClient(transport: transport).decide(makeRequest())
            XCTFail("Expected timeout")
        } catch let error as AgentStructuredModelClientError {
            XCTAssertEqual(error, .network("模型请求超时，请稍后重试。"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMalformedProviderEnvelopeIsReadableError() async {
        let transport = RecordingModelTransport { request in
            (Data(#"{"choices":[]}"#.utf8), Self.httpResponse(for: request, status: 200))
        }

        do {
            _ = try await makeClient(transport: transport).decide(makeRequest())
            XCTFail("Expected envelope error")
        } catch let error as AgentStructuredModelClientError {
            XCTAssertTrue(error.localizedDescription.contains("message.content"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidDecisionRetriesOnceWithZeroTemperature() async throws {
        let runID = runID
        let transport = SequencedModelTransport(responses: [
            { request in
                (Self.chatEnvelope("{invalid}"), Self.httpResponse(for: request, status: 200))
            },
            { request in
                (Self.chatEnvelope(Self.decisionJSON(runID: runID)), Self.httpResponse(for: request, status: 200))
            }
        ])
        let client = AgentStructuredModelClient(
            configuration: configuration(),
            transport: transport,
            now: { Date(timeIntervalSince1970: 0) },
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )

        let decision = try await client.decide(makeRequest())
        let requests = await transport.requests
        let retryBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests.last?.httpBody)) as? [String: Any]
        )
        let messages = try XCTUnwrap(retryBody["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)

        XCTAssertEqual(decision.runID, runID)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(retryBody["temperature"] as? Double, 0)
        XCTAssertTrue(system.contains("唯一一次纠错机会"))
    }

    func testMissingScheduleItemsTriggersProtocolRepairRetry() async throws {
        let runID = runID
        let invalid = Self.jsonString([
            "schema_version": 1,
            "run_id": runID.uuidString,
            "goal": "生成排期",
            "phase": "tool_calls",
            "assistant_draft": "正在生成方案",
            "tool_calls": [[
                "call_id": "plan",
                "tool": "propose_schedule",
                "arguments": ["reminder_ids": ["a", "b"]]
            ]],
            "final_reply": NSNull()
        ])
        let transport = SequencedModelTransport(responses: [
            { request in
                (Self.chatEnvelope(invalid), Self.httpResponse(for: request, status: 200))
            },
            { request in
                (Self.chatEnvelope(Self.decisionJSON(runID: runID)), Self.httpResponse(for: request, status: 200))
            }
        ])
        let client = AgentStructuredModelClient(
            configuration: configuration(),
            transport: transport,
            now: { Date(timeIntervalSince1970: 0) },
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )

        _ = try await client.decide(makeRequest())
        let requests = await transport.requests
        let retryBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests.last?.httpBody)) as? [String: Any]
        )
        let messages = try XCTUnwrap(retryBody["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)

        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(system.contains("propose_schedule 缺少非空必填参数：items"))
    }

    func testInvalidConfigurationFailsBeforeTransport() async {
        let transport = RecordingModelTransport { _ in
            XCTFail("Transport must not be called")
            throw URLError(.badURL)
        }
        let configuration = AgentModelConfiguration(
            provider: "test",
            wireAPI: "chat_completions",
            modelID: "",
            baseURL: "https://example.com",
            apiKey: "test-key",
            temperature: 0,
            maxTokens: 500,
            timeoutSeconds: 10
        )

        do {
            _ = try await AgentStructuredModelClient(configuration: configuration, transport: transport)
                .decide(makeRequest())
            XCTFail("Expected configuration error")
        } catch let error as AgentStructuredModelClientError {
            XCTAssertEqual(error, .invalidConfiguration("模型配置不完整。"))
            let requestCount = await transport.requestCount
            XCTAssertEqual(requestCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertDecisionError(text: String, contains expected: String) async {
        let transport = RecordingModelTransport { request in
            (Self.chatEnvelope(text), Self.httpResponse(for: request, status: 200))
        }
        do {
            _ = try await makeClient(transport: transport).decide(makeRequest())
            XCTFail("Expected decision error")
        } catch let error as AgentStructuredModelClientError {
            guard case .invalidDecision = error else {
                return XCTFail("Unexpected structured error: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient(
        wireAPI: String = "chat_completions",
        transport: RecordingModelTransport
    ) -> AgentStructuredModelClient {
        let configuration = AgentModelConfiguration(
            provider: "test",
            wireAPI: wireAPI,
            modelID: "test-model",
            baseURL: "https://example.com/api",
            apiKey: "test-key",
            temperature: 0.1,
            maxTokens: 700,
            timeoutSeconds: 10
        )
        return AgentStructuredModelClient(
            configuration: configuration,
            transport: transport,
            now: { Date(timeIntervalSince1970: 0) },
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )
    }

    private func configuration() -> AgentModelConfiguration {
        AgentModelConfiguration(
            provider: "test",
            wireAPI: "chat_completions",
            modelID: "test-model",
            baseURL: "https://example.com/api",
            apiKey: "test-key",
            temperature: 0.1,
            maxTokens: 700,
            timeoutSeconds: 10
        )
    }

    private func makeRequest() -> AgentModelRequest {
        AgentModelRequest(runID: runID, userInput: "测试", modelTurn: 1, toolResults: [])
    }

    private func makeContextSnapshot(
        reminderLists: [ReminderListContextItem]
    ) -> AgentContextSnapshot {
        let now = Date(timeIntervalSince1970: 0)
        return AgentContextSnapshot(
            generatedAt: now,
            timeZoneIdentifier: "Asia/Shanghai",
            session: SessionContext(id: UUID(), title: "测试", createdAt: now, updatedAt: now),
            recentTurns: [],
            sessionSummary: nil,
            reminderLists: reminderLists,
            reminders: [],
            references: .empty,
            preferences: [],
            documents: AgentDocumentContext(prompt: "p", memory: "m", solu: "s", operatingGuide: "o"),
            privacy: ContextPrivacyDescriptor(
                includesNotes: false,
                includesCompletedReminders: false,
                maximumReminderCount: 40,
                reminderSnapshotIsStale: false,
                originalReminderCount: 0,
                includedReminderCount: 0,
                truncatedReminderCount: 0,
                truncatedTurnCount: 0
            )
        )
    }

    private static func decisionJSON(runID: UUID, finalReply: String? = "处理完成") -> String {
        jsonString(decisionObject(runID: runID, finalReply: finalReply))
    }

    private static func decisionObject(runID: UUID, finalReply: String? = "处理完成") -> [String: Any] {
        [
            "schema_version": 1,
            "run_id": runID.uuidString,
            "goal": "测试目标",
            "phase": "final",
            "assistant_draft": NSNull(),
            "tool_calls": [],
            "final_reply": finalReply ?? NSNull()
        ]
    }

    private static func toolCallDecisionJSON(runID: UUID, callIDs: [String]) -> String {
        jsonString([
            "schema_version": 1,
            "run_id": runID.uuidString,
            "goal": "测试目标",
            "phase": "tool_calls",
            "assistant_draft": "查询中",
            "tool_calls": callIDs.map {
                ["call_id": $0, "tool": "search_reminders", "arguments": [:]] as [String: Any]
            },
            "final_reply": NSNull()
        ])
    }

    private static func jsonString(_ object: Any) -> String {
        String(
            data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8
        )!
    }

    private static func chatEnvelope(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]])
    }

    private static func httpResponse(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

private actor RecordingModelTransport: AgentStructuredModelTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let handler: Handler
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var lastRequest: URLRequest? { requests.last }
    var requestCount: Int { requests.count }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try await handler(request)
    }
}

private actor SequencedModelTransport: AgentStructuredModelTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let responses: [Handler]
    private(set) var requests: [URLRequest] = []

    init(responses: [Handler]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index = requests.count
        requests.append(request)
        guard responses.indices.contains(index) else {
            throw URLError(.cannotParseResponse)
        }
        return try await responses[index](request)
    }
}
