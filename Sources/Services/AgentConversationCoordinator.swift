import Foundation

struct AgentConversationConfirmationPayload: Codable, Equatable, Sendable {
    let runID: UUID
    let goal: String
    let userInput: String
    let pendingToolCalls: [AgentToolCall]
    let priorToolResults: [AgentToolResult]

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case goal
        case userInput = "user_input"
        case pendingToolCalls = "pending_tool_calls"
        case priorToolResults = "prior_tool_results"
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
        _ toolExecutors: [any AgentToolExecutor]
    ) -> AgentConversationOrchestratorOperations

    private let runStore: AgentRunStore
    private let modelClientFactory: ModelClientFactory
    private let toolExecutorsFactory: ToolExecutorsFactory
    private let orchestratorFactory: OrchestratorFactory
    private var operationsByRunID: [UUID: AgentConversationOrchestratorOperations] = [:]
    private var riskLevelsByRunID: [UUID: [AgentToolName: AgentToolRiskLevel]] = [:]

    init(
        runStore: AgentRunStore = .shared,
        modelClientFactory: @escaping ModelClientFactory = { configuration in
            AgentStructuredModelClient(configuration: configuration)
        },
        toolExecutorsFactory: @escaping ToolExecutorsFactory = {
            ReminderAgentToolExecutor.standardExecutors()
        },
        orchestratorFactory: @escaping OrchestratorFactory = { modelClient, toolExecutors in
            let orchestrator = AgentOrchestrator(
                modelClient: modelClient,
                toolExecutors: toolExecutors
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
        self.modelClientFactory = modelClientFactory
        self.toolExecutorsFactory = toolExecutorsFactory
        self.orchestratorFactory = orchestratorFactory
    }

    func run(
        userInput: String,
        configuration: AgentModelConfiguration,
        contextSnapshot: AgentContextSnapshot? = nil
    ) async -> AgentConversationPresentation {
        let runID = UUID()
        runStore.beginRun(runID: runID, status: .deciding)

        let modelClient = modelClientFactory(configuration)
        let baseExecutors = toolExecutorsFactory()
        let riskLevels = Dictionary(
            baseExecutors.map { ($0.toolName, $0.riskLevel) },
            uniquingKeysWith: { first, _ in first }
        )
        let persistedExecutors: [any AgentToolExecutor] = baseExecutors.map {
            PersistingAgentToolExecutor(base: $0, runStore: runStore)
        }
        let operations = orchestratorFactory(modelClient, persistedExecutors)
        operationsByRunID[runID] = operations
        riskLevelsByRunID[runID] = riskLevels

        let result = await operations.run(userInput, runID, contextSnapshot)
        return finish(result, userInput: userInput, riskLevels: riskLevels)
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

        runStore.updateStatus(runID: payload.runID, status: .executingWrites)
        let result = await operations.executeConfirmed(payload)
        return finish(
            result,
            userInput: payload.userInput,
            riskLevels: riskLevelsByRunID[payload.runID] ?? [:]
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
        return (orchestratorFactory(modelClient, persistedExecutors), riskLevels)
    }

    private func finish(
        _ result: AgentRunResult,
        userInput: String,
        riskLevels: [AgentToolName: AgentToolRiskLevel]
    ) -> AgentConversationPresentation {
        recordModelTurns(result)
        recordPendingCalls(result, riskLevels: riskLevels)
        runStore.finishRun(
            runID: result.runID,
            status: result.status,
            errorCategory: result.error?.category
        )

        let payload = result.pendingToolCalls.isEmpty ? nil : AgentConversationConfirmationPayload(
            runID: result.runID,
            goal: result.goal,
            userInput: userInput,
            pendingToolCalls: result.pendingToolCalls,
            priorToolResults: result.toolResults
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
