import Foundation

struct AgentOrchestrator: Sendable {
    struct ToolTimeouts: Sendable {
        let readOnly: Duration
        let write: Duration
        let schedule: Duration

        static let `default` = ToolTimeouts(
            readOnly: .seconds(8),
            write: .seconds(12),
            schedule: .seconds(30)
        )
    }

    static let maxModelTurns = 4
    static let maxToolCalls = 8
    static let maxToolCallsPerTurn = 5

    private let modelClient: any AgentModelClient
    private let executors: [AgentToolName: any AgentToolExecutor]
    private let toolTimeouts: ToolTimeouts

    init(
        modelClient: any AgentModelClient,
        toolExecutors: [any AgentToolExecutor] = [],
        toolTimeouts: ToolTimeouts = .default
    ) {
        self.modelClient = modelClient
        self.executors = Dictionary(
            toolExecutors.map { ($0.toolName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.toolTimeouts = toolTimeouts
    }

    func run(
        userInput: String,
        runID: UUID = UUID(),
        contextSnapshot: AgentContextSnapshot? = nil
    ) async -> AgentRunResult {
        var goal = userInput
        var modelTurns = 0
        var toolCallCount = 0
        var toolResults: [AgentToolResult] = []

        do {
            while modelTurns < Self.maxModelTurns {
                try Task.checkCancellation()
                modelTurns += 1

                let request = AgentModelRequest(
                    runID: runID,
                    userInput: userInput,
                    modelTurn: modelTurns,
                    toolResults: toolResults,
                    contextSnapshot: contextSnapshot
                )
                let decision = try await modelClient.decide(request)
                try Task.checkCancellation()

                guard decision.schemaVersion == 1, decision.runID == runID else {
                    return failedRun(
                        runID: runID,
                        goal: goal,
                        modelTurns: modelTurns,
                        toolCallCount: toolCallCount,
                        toolResults: toolResults,
                        category: .modelProtocolError,
                        message: "模型返回了无效的编排协议。"
                    )
                }
                goal = decision.goal

                switch decision.phase {
                case .final:
                    guard let reply = nonempty(decision.finalReply) else {
                        return failedRun(
                            runID: runID,
                            goal: goal,
                            modelTurns: modelTurns,
                            toolCallCount: toolCallCount,
                            toolResults: toolResults,
                            category: .modelProtocolError,
                            message: "模型没有提供最终回复。"
                        )
                    }
                    let status = aggregateSuccessStatus(toolResults)
                    return AgentRunResult(
                        runID: runID,
                        goal: goal,
                        status: status,
                        finalReply: verifiedFinalReply(modelReply: reply, status: status, results: toolResults),
                        modelTurns: modelTurns,
                        toolCallCount: toolCallCount,
                        toolResults: toolResults,
                        error: nil
                    )

                case .awaitingClarification:
                    return AgentRunResult(
                        runID: runID,
                        goal: goal,
                        status: .awaitingClarification,
                        finalReply: nonempty(decision.finalReply) ?? nonempty(decision.assistantDraft),
                        modelTurns: modelTurns,
                        toolCallCount: toolCallCount,
                        toolResults: toolResults,
                        error: nil
                    )

                case .awaitingConfirmation:
                    return AgentRunResult(
                        runID: runID,
                        goal: goal,
                        status: .awaitingConfirmation,
                        finalReply: nonempty(decision.finalReply) ?? nonempty(decision.assistantDraft),
                        modelTurns: modelTurns,
                        toolCallCount: toolCallCount,
                        toolResults: toolResults,
                        error: nil
                    )

                case .toolCalls:
                    guard decision.toolCalls.isEmpty == false else {
                        return failedRun(
                            runID: runID,
                            goal: goal,
                            modelTurns: modelTurns,
                            toolCallCount: toolCallCount,
                            toolResults: toolResults,
                            category: .modelProtocolError,
                            message: "模型请求执行工具，但没有提供工具调用。"
                        )
                    }
                    guard decision.toolCalls.count <= Self.maxToolCallsPerTurn,
                          toolCallCount + decision.toolCalls.count <= Self.maxToolCalls else {
                        return budgetExhaustedRun(
                            runID: runID,
                            goal: goal,
                            modelTurns: modelTurns,
                            toolCallCount: toolCallCount,
                            toolResults: toolResults
                        )
                    }

                    var callsToProcess = decision.toolCalls
                    let containsWrite = callsToProcess.contains { call in
                        executors[call.tool]?.riskLevel != .readOnly
                    }

                    if containsWrite {
                        let reads = callsToProcess.filter { call in
                            executors[call.tool]?.riskLevel == .readOnly
                        }
                        for call in reads {
                            toolCallCount += 1
                            let result = await executeOrSkip(call, runID: runID, priorResults: toolResults)
                            toolResults.append(result)
                        }
                        callsToProcess.removeAll { call in
                            executors[call.tool]?.riskLevel == .readOnly
                        }
                        let successful: Set<AgentToolExecutionStatus> = [.success, .unchanged, .alreadyApplied]
                        if toolResults.suffix(reads.count).contains(where: { successful.contains($0.status) == false }) {
                            continue
                        }

                        let knownSnapshots = reminderSnapshots(from: toolResults)
                        let missingIDs = guardedWriteReminderIDs(in: callsToProcess).filter {
                            knownSnapshots[$0] == nil
                        }
                        if missingIDs.isEmpty == false {
                            guard toolCallCount + 1 <= Self.maxToolCalls else {
                                return budgetExhaustedRun(
                                    runID: runID,
                                    goal: goal,
                                    modelTurns: modelTurns,
                                    toolCallCount: toolCallCount,
                                    toolResults: toolResults
                                )
                            }
                            let preflight = AgentToolCall(
                                callID: "local-preflight-\(modelTurns)",
                                tool: .getReminderDetails,
                                arguments: AgentToolArguments([
                                    "reminder_ids": .array(missingIDs.map(AgentJSONValue.string)),
                                    "allow_notes": .bool(false),
                                    "allow_completed": .bool(true)
                                ])
                            )
                            toolCallCount += 1
                            let result = await execute(preflight, runID: runID)
                            toolResults.append(result)
                            guard successful.contains(result.status) else { continue }
                        }
                    }

                    let verifiedCalls = callsByAttachingReadSnapshots(
                        callsToProcess,
                        priorResults: toolResults
                    )

                    if verifiedCalls.isEmpty { continue }

                    if requiresLocalConfirmation(verifiedCalls) {
                        return AgentRunResult(
                            runID: runID,
                            goal: goal,
                            status: .awaitingConfirmation,
                            finalReply: nonempty(decision.assistantDraft) ?? "这次包含多项或高风险修改，请确认后再执行。",
                            modelTurns: modelTurns,
                            toolCallCount: toolCallCount,
                            toolResults: toolResults,
                            pendingToolCalls: verifiedCalls,
                            error: nil
                        )
                    }

                    let resultStartIndex = toolResults.count
                    for call in verifiedCalls {
                        try Task.checkCancellation()
                        toolCallCount += 1
                        let result = await executeOrSkip(call, runID: runID, priorResults: toolResults)
                        toolResults.append(result)
                    }

                    if let pendingApply = pendingScheduleApplication(
                        from: toolResults[resultStartIndex...],
                        modelTurn: modelTurns
                    ) {
                        return AgentRunResult(
                            runID: runID,
                            goal: goal,
                            status: .awaitingConfirmation,
                            finalReply: nonempty(decision.assistantDraft) ?? "排期方案已生成，请确认后再执行。",
                            modelTurns: modelTurns,
                            toolCallCount: toolCallCount,
                            toolResults: toolResults,
                            pendingToolCalls: [pendingApply],
                            error: nil
                        )
                    }
                }
            }

            return budgetExhaustedRun(
                runID: runID,
                goal: goal,
                modelTurns: modelTurns,
                toolCallCount: toolCallCount,
                toolResults: toolResults
            )
        } catch is CancellationError {
            return AgentRunResult(
                runID: runID,
                goal: goal,
                status: .cancelled,
                finalReply: nil,
                modelTurns: modelTurns,
                toolCallCount: toolCallCount,
                toolResults: toolResults,
                error: AgentToolError(category: .cancelled, userVisibleMessage: "操作已取消。")
            )
        } catch let error as AgentStructuredModelClientError {
            let category: AgentToolErrorCategory
            switch error {
            case .network, .httpStatus:
                category = .networkError
            case .invalidConfiguration, .invalidURL, .invalidResponse, .invalidEnvelope, .invalidDecision:
                category = .modelProtocolError
            }
            return failedRun(
                runID: runID,
                goal: goal,
                modelTurns: modelTurns,
                toolCallCount: toolCallCount,
                toolResults: toolResults,
                category: category,
                message: error.localizedDescription
            )
        } catch {
            return failedRun(
                runID: runID,
                goal: goal,
                modelTurns: modelTurns,
                toolCallCount: toolCallCount,
                toolResults: toolResults,
                category: .modelProtocolError,
                message: readableMessage(for: error, fallback: "模型请求失败，请稍后重试。")
            )
        }
    }

    private func pendingScheduleApplication(
        from results: ArraySlice<AgentToolResult>,
        modelTurn: Int
    ) -> AgentToolCall? {
        let successful: Set<AgentToolExecutionStatus> = [.success, .unchanged, .alreadyApplied]
        guard let proposal = results.last(where: {
            $0.tool == .proposeSchedule && successful.contains($0.status)
        }),
        case let .string(planID)? = proposal.result?["plan_id"],
        planID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return AgentToolCall(
            callID: "local-apply-schedule-\(modelTurn)",
            tool: .applySchedule,
            arguments: .init(["plan_id": .string(planID)])
        )
    }

    func executeConfirmed(
        _ pendingCalls: [AgentToolCall],
        runID: UUID,
        goal: String,
        priorToolResults: [AgentToolResult] = [],
        userInput: String
    ) async -> AgentRunResult {
        guard pendingCalls.isEmpty == false else {
            return failedRun(
                runID: runID,
                goal: goal,
                modelTurns: 0,
                toolCallCount: 0,
                toolResults: priorToolResults,
                category: .invalidArguments,
                message: "没有等待确认的操作。"
            )
        }
        guard pendingCalls.count <= Self.maxToolCalls else {
            return budgetExhaustedRun(
                runID: runID,
                goal: goal,
                modelTurns: 0,
                toolCallCount: 0,
                toolResults: priorToolResults
            )
        }

        var results = priorToolResults
        do {
            for call in pendingCalls {
                try Task.checkCancellation()
                let confirmedCall = AgentToolCall(
                    callID: call.callID,
                    tool: call.tool,
                    arguments: argumentsByConfirming(call.arguments),
                    dependencyCallIDs: call.dependencyCallIDs
                )
                results.append(await executeOrSkip(confirmedCall, runID: runID, priorResults: results))
            }
            let status = aggregateSuccessStatus(results)
            return AgentRunResult(
                runID: runID,
                goal: goal,
                status: status,
                finalReply: deterministicReply(status: status, results: results),
                modelTurns: 0,
                toolCallCount: pendingCalls.count,
                toolResults: results,
                error: status == .failed
                    ? AgentToolError(category: .toolExecutionFailed, userVisibleMessage: "确认的操作没有执行成功。")
                    : nil
            )
        } catch is CancellationError {
            return AgentRunResult(
                runID: runID,
                goal: goal,
                status: .cancelled,
                finalReply: "操作已取消。",
                modelTurns: 0,
                toolCallCount: results.count - priorToolResults.count,
                toolResults: results,
                error: AgentToolError(category: .cancelled, userVisibleMessage: "操作已取消。")
            )
        } catch {
            return failedRun(
                runID: runID,
                goal: goal,
                modelTurns: 0,
                toolCallCount: results.count - priorToolResults.count,
                toolResults: results,
                category: .toolExecutionFailed,
                message: readableMessage(for: error, fallback: "确认的操作执行失败。")
            )
        }
    }

    private func execute(_ call: AgentToolCall, runID: UUID) async -> AgentToolResult {
        guard let executor = executors[call.tool] else {
            return AgentToolResult(
                runID: runID,
                callID: call.callID,
                tool: call.tool,
                status: .failed,
                error: AgentToolError(
                    category: .unknownTool,
                    userVisibleMessage: "不支持工具：\(call.tool.rawValue)。"
                )
            )
        }

        do {
            let timeout = timeout(for: call.tool, riskLevel: executor.riskLevel)
            let output = try await withThrowingTaskGroup(of: AgentToolExecutionOutput.self) { group in
                group.addTask {
                    try await executor.execute(
                        arguments: call.arguments,
                        runID: runID,
                        callID: call.callID
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw AgentToolError(category: .timeout, userVisibleMessage: "工具执行超时，请稍后重试。")
                }
                guard let first = try await group.next() else {
                    throw AgentToolError(category: .toolExecutionFailed, userVisibleMessage: "工具没有返回结果。")
                }
                group.cancelAll()
                return first
            }
            return AgentToolResult(
                runID: runID,
                callID: call.callID,
                tool: call.tool,
                status: output.status,
                result: output.result
            )
        } catch is CancellationError {
            return AgentToolResult(
                runID: runID,
                callID: call.callID,
                tool: call.tool,
                status: .cancelled,
                error: AgentToolError(category: .cancelled, userVisibleMessage: "工具调用已取消。")
            )
        } catch let error as AgentToolError {
            return AgentToolResult(
                runID: runID,
                callID: call.callID,
                tool: call.tool,
                status: status(for: error.category),
                error: error
            )
        } catch let error as ReminderGatewayError {
            let toolError = mappedGatewayError(error)
            return AgentToolResult(
                runID: runID,
                callID: call.callID,
                tool: call.tool,
                status: status(for: toolError.category),
                error: toolError
            )
        } catch {
            return AgentToolResult(
                runID: runID,
                callID: call.callID,
                tool: call.tool,
                status: .failed,
                error: AgentToolError(
                    category: .toolExecutionFailed,
                    userVisibleMessage: readableMessage(for: error, fallback: "工具执行失败。")
                )
            )
        }
    }

    private func executeOrSkip(
        _ call: AgentToolCall,
        runID: UUID,
        priorResults: [AgentToolResult]
    ) async -> AgentToolResult {
        let dependencies = call.dependencyCallIDs ?? []
        guard dependencies.isEmpty == false else {
            return await execute(call, runID: runID)
        }
        let successful: Set<AgentToolExecutionStatus> = [.success, .unchanged, .alreadyApplied]
        let completed = Dictionary(
            priorResults.map { ($0.callID, $0.status) },
            uniquingKeysWith: { _, latest in latest }
        )
        guard dependencies.allSatisfy({ completed[$0].map(successful.contains) == true }) else {
            return AgentToolResult(
                runID: runID,
                callID: call.callID,
                tool: call.tool,
                status: .skipped,
                error: AgentToolError(
                    category: .toolExecutionFailed,
                    userVisibleMessage: "前置操作未成功，已跳过这一步。"
                )
            )
        }
        return await execute(call, runID: runID)
    }

    private func timeout(for tool: AgentToolName, riskLevel: AgentToolRiskLevel) -> Duration {
        if tool == .proposeSchedule || tool == .applySchedule {
            return toolTimeouts.schedule
        }
        return riskLevel == .readOnly ? toolTimeouts.readOnly : toolTimeouts.write
    }

    private func requiresLocalConfirmation(_ calls: [AgentToolCall]) -> Bool {
        let writes = calls.compactMap { call -> (AgentToolCall, AgentToolRiskLevel)? in
            guard let executor = executors[call.tool], executor.riskLevel != .readOnly else { return nil }
            return (call, executor.riskLevel)
        }
        guard writes.isEmpty == false else { return false }
        if writes.allSatisfy({ isExplicitlyConfirmed($0.0.arguments) }) { return false }
        if writes.count > 1 { return true }
        return writes.contains { $0.1 == .mediumRiskWrite || $0.1 == .highRiskWrite }
    }

    private func callsByAttachingReadSnapshots(
        _ calls: [AgentToolCall],
        priorResults: [AgentToolResult]
    ) -> [AgentToolCall] {
        let snapshots = reminderSnapshots(from: priorResults)
        let guardedWrites: Set<AgentToolName> = [
            .updateReminder, .moveReminder, .completeReminder, .deleteReminder
        ]

        return calls.map { call in
            guard guardedWrites.contains(call.tool),
                  case let .string(reminderID)? = call.arguments["reminder_id"],
                  let snapshot = snapshots[reminderID] else {
                return call
            }

            var arguments = call.arguments.values
            arguments.removeValue(forKey: "expected_list_id")
            arguments.removeValue(forKey: "expected_due_date")
            arguments.removeValue(forKey: "expected_completion")
            arguments["must_exist"] = .bool(true)

            if case let .string(listID)? = snapshot["list_id"] {
                arguments["expected_list_id"] = .string(listID)
            }
            if case let .string(dueDate)? = snapshot["due_date"] {
                arguments["expected_due_date"] = .string(dueDate)
            }
            if case let .bool(isCompleted)? = snapshot["is_completed"] {
                arguments["expected_completion"] = .bool(isCompleted)
            }

            return AgentToolCall(
                callID: call.callID,
                tool: call.tool,
                arguments: AgentToolArguments(arguments),
                dependencyCallIDs: call.dependencyCallIDs
            )
        }
    }

    private func guardedWriteReminderIDs(in calls: [AgentToolCall]) -> [String] {
        let guardedWrites: Set<AgentToolName> = [
            .updateReminder, .moveReminder, .completeReminder, .deleteReminder
        ]
        var seen: Set<String> = []
        return calls.compactMap { call in
            guard guardedWrites.contains(call.tool),
                  case let .string(reminderID)? = call.arguments["reminder_id"],
                  seen.insert(reminderID).inserted else { return nil }
            return reminderID
        }
    }

    private func reminderSnapshots(
        from results: [AgentToolResult]
    ) -> [String: [String: AgentJSONValue]] {
        var snapshots: [String: [String: AgentJSONValue]] = [:]
        for result in results where result.tool == .searchReminders || result.tool == .getReminderDetails {
            guard case let .array(items)? = result.result?["items"] else { continue }
            for item in items {
                guard case let .object(snapshot) = item,
                      case let .string(reminderID)? = snapshot["reminder_id"] else { continue }
                snapshots[reminderID] = snapshot
            }
        }
        return snapshots
    }

    private func isExplicitlyConfirmed(_ arguments: AgentToolArguments) -> Bool {
        guard case let .bool(confirmed)? = arguments["confirmed"] else { return false }
        return confirmed
    }

    private func argumentsByConfirming(_ arguments: AgentToolArguments) -> AgentToolArguments {
        var values = arguments.values
        values["confirmed"] = .bool(true)
        return AgentToolArguments(values)
    }

    private func deterministicReply(status: AgentRunStatus, results: [AgentToolResult]) -> String {
        if let counts = scheduleOutcomeCounts(from: results) {
            switch status {
            case .succeeded:
                return "已完成确认的 \(counts.success) 项操作。"
            case .partial:
                return "已完成 \(counts.success) 项，另有 \(counts.failed) 项未成功。"
            default:
                return "确认的操作没有执行成功。"
            }
        }
        let visibleResults = userVisibleResults(from: results)
        let successes: Set<AgentToolExecutionStatus> = [.success, .unchanged, .alreadyApplied]
        let successCount = visibleResults.lazy.filter { successes.contains($0.status) }.count
        let failedCount = visibleResults.count - successCount
        switch status {
        case .succeeded:
            return "已完成确认的 \(successCount) 项操作。"
        case .partial:
            return "已完成 \(successCount) 项，另有 \(failedCount) 项未成功。"
        default:
            return "确认的操作没有执行成功。"
        }
    }

    private func verifiedFinalReply(
        modelReply: String,
        status: AgentRunStatus,
        results: [AgentToolResult]
    ) -> String {
        switch status {
        case .partial:
            return deterministicReply(status: status, results: results)
        case .failed:
            let message = results.compactMap(\.error?.userVisibleMessage).first ?? "工具操作没有执行成功。"
            return "这次没有完成：\(message)"
        default:
            return modelReply
        }
    }

    private func status(for category: AgentToolErrorCategory) -> AgentToolExecutionStatus {
        switch category {
        case .cancelled:
            return .cancelled
        case .timeout:
            return .timedOut
        default:
            return .failed
        }
    }

    private func aggregateSuccessStatus(_ results: [AgentToolResult]) -> AgentRunStatus {
        guard results.isEmpty == false else { return .succeeded }
        if let applyResult = results.last(where: { $0.tool == .applySchedule }),
           case let .string(planStatus)? = applyResult.result?["plan_status"],
           planStatus == "partial" {
            return .partial
        }
        let visibleResults = userVisibleResults(from: results)
        let successfulStatuses: Set<AgentToolExecutionStatus> = [.success, .unchanged, .alreadyApplied]
        let successCount = visibleResults.lazy.filter { successfulStatuses.contains($0.status) }.count
        if successCount == visibleResults.count {
            return .succeeded
        }
        return successCount > 0 ? .partial : .failed
    }

    private func scheduleOutcomeCounts(
        from results: [AgentToolResult]
    ) -> (success: Int, failed: Int)? {
        guard let applyResult = results.last(where: { $0.tool == .applySchedule }),
              case let .integer(success)? = applyResult.result?["successful_count"],
              case let .integer(failed)? = applyResult.result?["failed_count"] else {
            return nil
        }
        return (success, failed)
    }

    private func userVisibleResults(from results: [AgentToolResult]) -> [AgentToolResult] {
        let internalReadTools: Set<AgentToolName> = [
            .searchReminders,
            .getReminderDetails,
            .proposeSchedule
        ]
        let visibleResults = results.filter { result in
            internalReadTools.contains(result.tool) == false
        }
        return visibleResults.isEmpty ? results : visibleResults
    }

    private func budgetExhaustedRun(
        runID: UUID,
        goal: String,
        modelTurns: Int,
        toolCallCount: Int,
        toolResults: [AgentToolResult]
    ) -> AgentRunResult {
        failedRun(
            runID: runID,
            goal: goal,
            modelTurns: modelTurns,
            toolCallCount: toolCallCount,
            toolResults: toolResults,
            category: .budgetExhausted,
            message: "本次操作已达到编排预算，请缩小范围后重试。"
        )
    }

    private func failedRun(
        runID: UUID,
        goal: String,
        modelTurns: Int,
        toolCallCount: Int,
        toolResults: [AgentToolResult],
        category: AgentToolErrorCategory,
        message: String
    ) -> AgentRunResult {
        AgentRunResult(
            runID: runID,
            goal: goal,
            status: .failed,
            finalReply: message,
            modelTurns: modelTurns,
            toolCallCount: toolCallCount,
            toolResults: toolResults,
            error: AgentToolError(category: category, userVisibleMessage: message)
        )
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func readableMessage(for error: Error, fallback: String) -> String {
        let message = (error as? LocalizedError)?.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let message, message.isEmpty == false else { return fallback }
        return message
    }

    private func mappedGatewayError(_ error: ReminderGatewayError) -> AgentToolError {
        switch error {
        case .readNotAuthorized:
            return AgentToolError(category: .permissionDenied, userVisibleMessage: "没有读取提醒事项的权限。")
        case .writeNotAuthorized:
            return AgentToolError(category: .permissionDenied, userVisibleMessage: "没有修改提醒事项的权限。")
        case let .invalidRequest(message):
            return AgentToolError(category: .invalidArguments, userVisibleMessage: "提醒事项参数无效：\(message)")
        case let .reminderNotFound(identifier):
            return AgentToolError(category: .notFound, userVisibleMessage: "没有找到要操作的提醒事项（\(identifier)）。")
        case let .listNotFound(title):
            return AgentToolError(category: .listNotFound, userVisibleMessage: "没有找到清单“\(title)”。")
        case .preconditionConflict:
            return AgentToolError(category: .preconditionConflict, userVisibleMessage: "任务已发生变化，请刷新后重试。")
        case .storeUnavailable:
            return AgentToolError(category: .eventKitError, userVisibleMessage: "系统提醒事项存储当前不可用。")
        case .operationFailed:
            return AgentToolError(category: .eventKitError, userVisibleMessage: "系统提醒事项操作失败。")
        }
    }
}
