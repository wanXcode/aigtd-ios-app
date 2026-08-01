import Foundation

struct AgentConversationConfirmationPayload: Codable, Equatable, Sendable {
    let runID: UUID
    let goal: String
    let userInput: String
    let pendingToolCalls: [AgentToolCall]
    let priorToolResults: [AgentToolResult]
    let sessionID: UUID?
    let interactionID: UUID?
    let interactionVersion: Int?

    init(
        runID: UUID,
        goal: String,
        userInput: String,
        pendingToolCalls: [AgentToolCall],
        priorToolResults: [AgentToolResult],
        sessionID: UUID? = nil,
        interactionID: UUID? = nil,
        interactionVersion: Int? = nil
    ) {
        self.runID = runID
        self.goal = goal
        self.userInput = userInput
        self.pendingToolCalls = pendingToolCalls
        self.priorToolResults = priorToolResults
        self.sessionID = sessionID
        self.interactionID = interactionID
        self.interactionVersion = interactionVersion
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case goal
        case userInput = "user_input"
        case pendingToolCalls = "pending_tool_calls"
        case priorToolResults = "prior_tool_results"
        case sessionID = "session_id"
        case interactionID = "interaction_id"
        case interactionVersion = "interaction_version"
    }
}

struct AgentConversationPresentation: Codable, Equatable, Sendable {
    let result: AgentRunResult
    let reply: String
    let allowsLegacyFallback: Bool
    let confirmationPayload: AgentConversationConfirmationPayload?

    private enum CodingKeys: String, CodingKey {
        case result
        case reply
        case allowsLegacyFallback = "allows_legacy_fallback"
        case confirmationPayload = "confirmation_payload"
    }
}

struct AgentPendingPlanRevisionPrompt {
    static func make(
        userInput: String,
        pending: AgentConversationConfirmationPayload
    ) -> String {
        let operations = pending.pendingToolCalls.enumerated().map { index, call in
            let arguments = encodedArguments(call.arguments)
            return "操作 \(index + 1)：工具 \(call.tool.rawValue)，参数 \(arguments)"
        }.joined(separator: "\n")

        return """
        [待确认方案修订模式]
        当前存在一份尚未执行的方案。用户本轮是在继续说明或调整该方案，不是确认执行。
        必须遵守：
        1. 不得执行任何写操作，只能生成修订后的完整待确认方案或提出必要澄清。
        2. “第一条”“第二条”等序号严格对应下方操作顺序。
        3. 用户要求某条“不改”时，必须从新版方案移除该条写操作，让对应提醒保持 Reminders 当前状态；不得沿用或执行旧方案中该条操作。
        4. 若本轮与旧方案无关，正常回答，但仍不得执行新的写操作。

        旧方案原始请求：\(pending.userInput)
        旧方案目标：\(pending.goal)
        旧方案操作：
        \(operations)

        用户本轮输入：\(userInput)
        """
    }

    private static func encodedArguments(_ arguments: AgentToolArguments) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(arguments) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct AgentPlanPreviewRequest {
    static func matches(_ input: String) -> Bool {
        let normalized = input.replacingOccurrences(of: " ", with: "")
        let asksForPlan = ["生成方案", "先给方案", "先看方案", "只看方案", "方案预览"]
            .contains { normalized.contains($0) }
        let defersExecution = ["不要执行", "不执行", "暂不执行", "先不执行"]
            .contains { normalized.contains($0) }
        return asksForPlan && defersExecution
    }

    static func modelInput(_ input: String) -> String {
        """
        [计划预览模式]
        用户要求先查看可执行方案，当前绝不能写入 Reminders。
        必须返回用于生成待确认卡的真实 tool_calls；本地策略会拦截写操作并等待确认。
        禁止只用 final 自然语言描述方案，也禁止直接返回没有 tool_calls 的 awaiting_confirmation。

        用户本轮输入：\(input)
        """
    }
}

struct AgentConversationOrchestratorOperations: Sendable {
    let run: @Sendable (
        _ userInput: String,
        _ runID: UUID,
        _ contextSnapshot: AgentContextSnapshot?
    ) async -> AgentRunResult
    let executeConfirmed: @Sendable (_ payload: AgentConversationConfirmationPayload) async -> AgentRunResult
}

@MainActor
final class AgentConversationCoordinator {
    typealias ModelClientFactory = @Sendable (AgentModelConfiguration) -> any AgentModelClient
    typealias ToolExecutorsFactory = @Sendable () -> [any AgentToolExecutor]
    typealias OrchestratorFactory = @Sendable (
        _ modelClient: any AgentModelClient,
        _ toolExecutors: [any AgentToolExecutor],
        _ policySettings: AgentExecutionPolicySettings,
        _ longTermRules: AgentExecutionPolicyLongTermRules
    ) -> AgentConversationOrchestratorOperations

    private let runStore: AgentRunStore
    private let pendingInteractionStore: AgentPendingInteractionStore
    private let modelClientFactory: ModelClientFactory
    private let toolExecutorsFactory: ToolExecutorsFactory
    private let orchestratorFactory: OrchestratorFactory
    private var operationsByRunID: [UUID: AgentConversationOrchestratorOperations] = [:]
    private var riskLevelsByRunID: [UUID: [AgentToolName: AgentToolRiskLevel]] = [:]

    init(
        runStore: AgentRunStore = .shared,
        pendingInteractionStore: AgentPendingInteractionStore = .shared,
        modelClientFactory: @escaping ModelClientFactory = { configuration in
            AgentStructuredModelClient(configuration: configuration)
        },
        toolExecutorsFactory: @escaping ToolExecutorsFactory = {
            ReminderAgentToolExecutor.standardExecutors()
        },
        orchestratorFactory: @escaping OrchestratorFactory = { modelClient, toolExecutors, policySettings, longTermRules in
            let orchestrator = AgentOrchestrator(
                modelClient: modelClient,
                toolExecutors: toolExecutors,
                policySettings: policySettings,
                longTermRules: longTermRules
            )
            return AgentConversationOrchestratorOperations(
                run: { userInput, runID, contextSnapshot in
                    await orchestrator.run(
                        userInput: userInput,
                        runID: runID,
                        contextSnapshot: contextSnapshot
                    )
                },
                executeConfirmed: { payload in
                    await orchestrator.executeConfirmed(
                        payload.pendingToolCalls,
                        runID: payload.runID,
                        goal: payload.goal,
                        priorToolResults: payload.priorToolResults,
                        userInput: payload.userInput
                    )
                }
            )
        }
    ) {
        self.runStore = runStore
        self.pendingInteractionStore = pendingInteractionStore
        self.modelClientFactory = modelClientFactory
        self.toolExecutorsFactory = toolExecutorsFactory
        self.orchestratorFactory = orchestratorFactory
    }

    func run(
        userInput: String,
        configuration: AgentModelConfiguration,
        contextSnapshot: AgentContextSnapshot? = nil,
        sessionID: UUID? = nil,
        policySettings: AgentExecutionPolicySettings = .init(),
        longTermRules: AgentExecutionPolicyLongTermRules = .init(),
        revisionOf pending: AgentConversationConfirmationPayload? = nil
    ) async -> AgentConversationPresentation {
        let runID = UUID()
        runStore.beginRun(runID: runID, status: .deciding)

        let modelInput: String
        var effectiveLongTermRules = longTermRules
        if let pending {
            modelInput = AgentPendingPlanRevisionPrompt.make(
                userInput: userInput,
                pending: pending
            )
            // A revision must produce a new versioned plan before any write can run.
            effectiveLongTermRules.requireConfirmationForAllWrites = true
        } else if AgentPlanPreviewRequest.matches(userInput) {
            modelInput = AgentPlanPreviewRequest.modelInput(userInput)
            effectiveLongTermRules.requireConfirmationForAllWrites = true
        } else {
            modelInput = userInput
        }

        let modelClient = modelClientFactory(configuration)
        let baseExecutors = toolExecutorsFactory()
        let riskLevels = Dictionary(
            baseExecutors.map { ($0.toolName, $0.riskLevel) },
            uniquingKeysWith: { first, _ in first }
        )
        let persistedExecutors: [any AgentToolExecutor] = baseExecutors.map {
            PersistingAgentToolExecutor(base: $0, runStore: runStore)
        }
        let operations = orchestratorFactory(
            modelClient,
            persistedExecutors,
            policySettings,
            effectiveLongTermRules
        )
        operationsByRunID[runID] = operations
        riskLevelsByRunID[runID] = riskLevels

        let result = await operations.run(modelInput, runID, contextSnapshot)
        return finish(
            result,
            userInput: userInput,
            riskLevels: riskLevels,
            sessionID: sessionID
        )
    }

    func confirm(
        _ presentation: AgentConversationPresentation,
        configuration: AgentModelConfiguration? = nil
    ) async -> AgentConversationPresentation {
        guard let payload = presentation.confirmationPayload else {
            let result = failureResult(
                basedOn: presentation.result,
                category: .invalidArguments,
                message: "没有等待确认的操作。"
            )
            return finish(result, userInput: "", riskLevels: [:])
        }
        var interactionIDToConsume: UUID?
        if let interactionID = payload.interactionID {
            guard let sessionID = payload.sessionID,
                  let version = payload.interactionVersion,
                  let active = pendingInteractionStore.active(for: sessionID),
                  active.interactionID == interactionID,
                  active.runID == payload.runID,
                  active.version == version else {
                let result = failureResult(
                    basedOn: presentation.result,
                    category: .staleReference,
                    message: "这份方案已经失效，请使用当前最新方案。"
                )
                return finish(result, userInput: payload.userInput, riskLevels: [:])
            }
            interactionIDToConsume = interactionID
        }
        let operations: AgentConversationOrchestratorOperations
        if let existing = operationsByRunID[payload.runID] {
            operations = existing
        } else if let configuration {
            let restored = makeOperations(configuration: configuration)
            operations = restored.operations
            operationsByRunID[payload.runID] = restored.operations
            riskLevelsByRunID[payload.runID] = restored.riskLevels
        } else {
            let result = failureResult(
                basedOn: presentation.result,
                category: .modelProtocolError,
                message: "确认上下文已失效，请重新发起操作。"
            )
            return finish(result, userInput: payload.userInput, riskLevels: [:])
        }

        if let interactionIDToConsume {
            do {
                try pendingInteractionStore.supersede(id: interactionIDToConsume)
            } catch {
                let result = failureResult(
                    basedOn: presentation.result,
                    category: .staleReference,
                    message: "这份方案已经失效，请重新生成。"
                )
                return finish(result, userInput: payload.userInput, riskLevels: [:])
            }
        }

        runStore.updateStatus(runID: payload.runID, status: .executingWrites)
        let result = await operations.executeConfirmed(payload)
        return finish(
            result,
            userInput: payload.userInput,
            riskLevels: riskLevelsByRunID[payload.runID] ?? [:]
        )
    }

    func cancel(_ presentation: AgentConversationPresentation) -> AgentConversationPresentation {
        guard let payload = presentation.confirmationPayload else {
            let result = failureResult(
                basedOn: presentation.result,
                category: .invalidArguments,
                message: "没有等待确认的操作。"
            )
            return finish(result, userInput: "", riskLevels: [:])
        }

        if let interactionID = payload.interactionID {
            guard let sessionID = payload.sessionID,
                  let version = payload.interactionVersion,
                  let active = pendingInteractionStore.active(for: sessionID),
                  active.interactionID == interactionID,
                  active.runID == payload.runID,
                  active.version == version else {
                let result = failureResult(
                    basedOn: presentation.result,
                    category: .staleReference,
                    message: "这份方案已经失效，请使用当前最新方案。"
                )
                return finish(result, userInput: payload.userInput, riskLevels: [:])
            }
            do {
                try pendingInteractionStore.cancel(id: interactionID)
            } catch {
                let result = failureResult(
                    basedOn: presentation.result,
                    category: .staleReference,
                    message: "这份方案已经失效，请重新生成。"
                )
                return finish(result, userInput: payload.userInput, riskLevels: [:])
            }
        }

        let result = AgentRunResult(
            runID: payload.runID,
            goal: payload.goal,
            status: .cancelled,
            finalReply: "已取消这个方案。",
            modelTurns: 0,
            toolCallCount: 0,
            toolResults: payload.priorToolResults,
            error: nil
        )
        return finish(result, userInput: payload.userInput, riskLevels: [:])
    }

    func retryFailed(
        _ presentation: AgentConversationPresentation,
        configuration: AgentModelConfiguration? = nil
    ) async -> AgentConversationPresentation {
        let recoveryPlan = AgentRecoveryPlanner().makePlan(from: presentation.result.toolResults)
        guard recoveryPlan.retryCandidates.isEmpty == false else {
            let result = failureResult(
                basedOn: presentation.result,
                category: .invalidArguments,
                message: recoveryPlan.recommendation
            )
            return finish(result, userInput: "", riskLevels: [:])
        }

        let runID = presentation.result.runID
        guard let interaction = pendingInteractionStore.interactions().first(where: { $0.runID == runID }) else {
            let result = failureResult(
                basedOn: presentation.result,
                category: .staleReference,
                message: "原方案已无法恢复，请重新生成方案。"
            )
            return finish(result, userInput: "", riskLevels: [:])
        }
        let candidatesByCallID = Dictionary(
            uniqueKeysWithValues: recoveryPlan.retryCandidates.map { ($0.callID, $0) }
        )
        let retryCalls = interaction.pendingCalls.compactMap { call -> AgentToolCall? in
            guard let candidate = candidatesByCallID[call.callID] else { return nil }
            guard candidate.itemIDs.isEmpty == false else { return call }
            var values = call.arguments.values
            values["retry_item_ids"] = .array(candidate.itemIDs.map(AgentJSONValue.string))
            return AgentToolCall(
                callID: call.callID,
                tool: call.tool,
                arguments: AgentToolArguments(values),
                dependencyCallIDs: call.dependencyCallIDs
            )
        }
        guard retryCalls.count == recoveryPlan.retryCandidates.count else {
            let result = failureResult(
                basedOn: presentation.result,
                category: .staleReference,
                message: "部分失败项已无法对应原方案，请重新生成方案。"
            )
            return finish(result, userInput: "", riskLevels: [:])
        }

        let operations: AgentConversationOrchestratorOperations
        if let existing = operationsByRunID[runID] {
            operations = existing
        } else if let configuration {
            let restored = makeOperations(configuration: configuration)
            operations = restored.operations
            operationsByRunID[runID] = restored.operations
            riskLevelsByRunID[runID] = restored.riskLevels
        } else {
            let result = failureResult(
                basedOn: presentation.result,
                category: .modelProtocolError,
                message: "重试上下文已失效，请重新发起操作。"
            )
            return finish(result, userInput: "", riskLevels: [:])
        }

        let retryCallIDs = Set(retryCalls.map(\.callID))
        let preservedResults = presentation.result.toolResults.filter {
            retryCallIDs.contains($0.callID) == false
        }
        let payload = AgentConversationConfirmationPayload(
            runID: runID,
            goal: presentation.result.goal,
            userInput: "重试失败项",
            pendingToolCalls: retryCalls,
            priorToolResults: preservedResults
        )
        runStore.updateStatus(runID: runID, status: .executingWrites)
        let result = await operations.executeConfirmed(payload)
        return finish(
            result,
            userInput: payload.userInput,
            riskLevels: riskLevelsByRunID[runID] ?? [:]
        )
    }

    private func makeOperations(
        configuration: AgentModelConfiguration
    ) -> (operations: AgentConversationOrchestratorOperations, riskLevels: [AgentToolName: AgentToolRiskLevel]) {
        let modelClient = modelClientFactory(configuration)
        let baseExecutors = toolExecutorsFactory()
        let riskLevels = Dictionary(
            baseExecutors.map { ($0.toolName, $0.riskLevel) },
            uniquingKeysWith: { first, _ in first }
        )
        let persistedExecutors: [any AgentToolExecutor] = baseExecutors.map {
            PersistingAgentToolExecutor(base: $0, runStore: runStore)
        }
        return (
            orchestratorFactory(modelClient, persistedExecutors, .init(), .init()),
            riskLevels
        )
    }

    private func finish(
        _ result: AgentRunResult,
        userInput: String,
        riskLevels: [AgentToolName: AgentToolRiskLevel],
        sessionID: UUID? = nil
    ) -> AgentConversationPresentation {
        recordModelTurns(result)
        recordPendingCalls(result, riskLevels: riskLevels)
        runStore.finishRun(
            runID: result.runID,
            status: result.status,
            errorCategory: result.error?.category
        )

        let interaction: AgentPendingInteraction?
        if result.pendingToolCalls.isEmpty == false, let sessionID {
            interaction = try? pendingInteractionStore.create(
                sessionID: sessionID,
                runID: result.runID,
                goal: result.goal,
                pendingCalls: result.pendingToolCalls,
                priorResults: result.toolResults
            )
        } else {
            interaction = nil
        }
        let payload = result.pendingToolCalls.isEmpty ? nil : AgentConversationConfirmationPayload(
            runID: result.runID,
            goal: result.goal,
            userInput: userInput,
            pendingToolCalls: result.pendingToolCalls,
            priorToolResults: result.toolResults,
            sessionID: interaction?.sessionID,
            interactionID: interaction?.interactionID,
            interactionVersion: interaction?.version
        )
        return AgentConversationPresentation(
            result: result,
            reply: naturalLanguageReply(for: result),
            allowsLegacyFallback: allowsLegacyFallback(for: result, riskLevels: riskLevels),
            confirmationPayload: payload
        )
    }

    private func recordModelTurns(_ result: AgentRunResult) {
        guard result.modelTurns > 0 else { return }
        for turn in 1...result.modelTurns {
            runStore.recordModelTurn(runID: result.runID, turn: turn)
        }
    }

    private func recordPendingCalls(
        _ result: AgentRunResult,
        riskLevels: [AgentToolName: AgentToolRiskLevel]
    ) {
        for call in result.pendingToolCalls {
            runStore.recordToolInvocation(
                runID: result.runID,
                call: call,
                riskLevel: riskLevels[call.tool] ?? .highRiskWrite,
                status: .awaitingConfirmation
            )
        }
    }

    private func naturalLanguageReply(for result: AgentRunResult) -> String {
        if let reply = nonempty(result.finalReply) { return reply }
        if let message = nonempty(result.error?.userVisibleMessage) { return message }
        switch result.status {
        case .awaitingConfirmation:
            return "请确认后再执行这些操作。"
        case .awaitingClarification:
            return "还需要更多信息才能继续。"
        case .cancelled:
            return "操作已取消。"
        case .succeeded:
            return "处理完成。"
        case .partial:
            return "部分操作已完成，请查看每项结果。"
        default:
            return "这次没有完成，请稍后重试。"
        }
    }

    private func allowsLegacyFallback(
        for result: AgentRunResult,
        riskLevels: [AgentToolName: AgentToolRiskLevel]
    ) -> Bool {
        false
    }

    private func failureResult(
        basedOn result: AgentRunResult,
        category: AgentToolErrorCategory,
        message: String
    ) -> AgentRunResult {
        AgentRunResult(
            runID: result.runID,
            goal: result.goal,
            status: .failed,
            finalReply: message,
            modelTurns: 0,
            toolCallCount: 0,
            toolResults: result.toolResults,
            error: AgentToolError(category: category, userVisibleMessage: message)
        )
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct PersistingAgentToolExecutor: AgentToolExecutor, Sendable {
    let toolName: AgentToolName
    let riskLevel: AgentToolRiskLevel

    private let base: any AgentToolExecutor
    private let runStore: AgentRunStore

    init(base: any AgentToolExecutor, runStore: AgentRunStore) {
        self.toolName = base.toolName
        self.riskLevel = base.riskLevel
        self.base = base
        self.runStore = runStore
    }

    func execute(
        arguments: AgentToolArguments,
        runID: UUID,
        callID: String
    ) async throws -> AgentToolExecutionOutput {
        let call = AgentToolCall(callID: callID, tool: toolName, arguments: arguments)
        runStore.recordToolInvocation(
            runID: runID,
            call: call,
            riskLevel: riskLevel,
            status: .running
        )
        do {
            let output = try await base.execute(arguments: arguments, runID: runID, callID: callID)
            runStore.recordToolInvocation(
                runID: runID,
                call: call,
                riskLevel: riskLevel,
                status: output.status,
                result: output.result,
                endedAt: .now
            )
            return output
        } catch is CancellationError {
            runStore.recordToolInvocation(
                runID: runID,
                call: call,
                riskLevel: riskLevel,
                status: .cancelled,
                errorCategory: .cancelled,
                endedAt: .now
            )
            throw CancellationError()
        } catch let error as AgentToolError {
            runStore.recordToolInvocation(
                runID: runID,
                call: call,
                riskLevel: riskLevel,
                status: error.category == .timeout ? .timedOut : .failed,
                errorCategory: error.category,
                endedAt: .now
            )
            throw error
        } catch {
            runStore.recordToolInvocation(
                runID: runID,
                call: call,
                riskLevel: riskLevel,
                status: .failed,
                errorCategory: .toolExecutionFailed,
                endedAt: .now
            )
            throw error
        }
    }
}
