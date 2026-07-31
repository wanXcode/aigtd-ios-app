import Foundation
import XCTest
@testable import AIGTDReminders

@MainActor
final class AgentConversationCoordinatorTests: XCTestCase {
    func testRunReturnsResultAndNaturalLanguageReply() async {
        let harness = makeHarness(mode: .final(reply: "已经处理好了。", modelTurns: 2))

        let presentation = await harness.coordinator.run(userInput: "处理任务", configuration: configuration())

        XCTAssertEqual(presentation.result.status, .succeeded)
        XCTAssertEqual(presentation.reply, "已经处理好了。")
        XCTAssertFalse(presentation.allowsLegacyFallback)
        XCTAssertNil(presentation.confirmationPayload)
    }

    func testRunPassesUserInputAndBuildsClientFromConfiguration() async {
        let probe = CoordinatorTestProbe(mode: .final(reply: "完成", modelTurns: 1))
        let providerBox = LockedBox<String?>(nil)
        let coordinator = makeCoordinator(probe: probe) { configuration in
            providerBox.withValue { $0 = configuration.provider }
            return NeverModelClient()
        }

        _ = await coordinator.run(userInput: "原始输入", configuration: configuration(provider: "injected"))

        let capturedInput = await probe.lastUserInput()
        XCTAssertEqual(capturedInput, "原始输入")
        XCTAssertEqual(providerBox.value, "injected")
    }

    func testDefaultToolFactoryBuildsAllTenTools() async {
        let probe = CoordinatorTestProbe(mode: .final(reply: "完成", modelTurns: 1))
        let names = LockedBox<[AgentToolName]>([])
        let store = makeStore()
        let coordinator = AgentConversationCoordinator(
            runStore: store,
            modelClientFactory: { _ in NeverModelClient() },
            orchestratorFactory: { _, executors in
                names.withValue { $0 = executors.map(\.toolName) }
                return probe.operations()
            }
        )

        _ = await coordinator.run(userInput: "检查工具", configuration: configuration())

        XCTAssertEqual(Set(names.value), Set([
            .searchReminders, .getReminderDetails, .createList, .createReminder, .updateReminder,
            .moveReminder, .completeReminder, .deleteReminder, .proposeSchedule, .applySchedule
        ]))
        XCTAssertEqual(names.value.count, 10)
    }

    func testRunPersistsBeginFinalStateAndModelTurns() async throws {
        let harness = makeHarness(mode: .final(reply: "完成", modelTurns: 3))

        let presentation = await harness.coordinator.run(userInput: "处理", configuration: configuration())
        let log = try XCTUnwrap(harness.store.run(for: presentation.result.runID))

        XCTAssertEqual(log.status, .succeeded)
        XCTAssertNotNil(log.endedAt)
        XCTAssertEqual(log.modelTurns.map(\.turn), [1, 2, 3])
    }

    func testNetworkFailureDoesNotSilentlyEnterLegacyExecutor() async {
        let harness = makeHarness(mode: .failure(category: .networkError, toolResults: []))

        let presentation = await harness.coordinator.run(userInput: "处理", configuration: configuration())

        XCTAssertFalse(presentation.allowsLegacyFallback)
        XCTAssertEqual(presentation.reply, "测试错误")
    }

    func testModelProtocolFailureDoesNotSilentlyEnterLegacyExecutor() async {
        let harness = makeHarness(mode: .failure(category: .modelProtocolError, toolResults: []))

        let presentation = await harness.coordinator.run(userInput: "处理", configuration: configuration())

        XCTAssertFalse(presentation.allowsLegacyFallback)
    }

    func testNonProtocolFailureNeverAllowsLegacyFallback() async {
        let harness = makeHarness(mode: .failure(category: .toolExecutionFailed, toolResults: []))

        let presentation = await harness.coordinator.run(userInput: "处理", configuration: configuration())

        XCTAssertFalse(presentation.allowsLegacyFallback)
    }

    func testSuccessfulWriteDisablesLegacyFallback() async {
        let call = AgentToolResult(
            runID: UUID(),
            callID: "write",
            tool: .createReminder,
            status: .success
        )
        let harness = makeHarness(
            mode: .failure(category: .networkError, toolResults: [call]),
            executors: [StubToolExecutor(toolName: .createReminder, riskLevel: .lowRiskWrite)]
        )

        let presentation = await harness.coordinator.run(userInput: "处理", configuration: configuration())

        XCTAssertFalse(presentation.allowsLegacyFallback)
    }

    func testStartedReadToolChainDisablesLegacyFallback() async {
        let call = AgentToolResult(
            runID: UUID(),
            callID: "read",
            tool: .searchReminders,
            status: .success
        )
        let harness = makeHarness(
            mode: .failure(category: .networkError, toolResults: [call]),
            executors: [StubToolExecutor(toolName: .searchReminders, riskLevel: .readOnly)]
        )

        let presentation = await harness.coordinator.run(userInput: "处理", configuration: configuration())

        XCTAssertFalse(presentation.allowsLegacyFallback)
    }

    func testPendingConfirmationPayloadIsCodableAndPreservesInput() async throws {
        let call = AgentToolCall(
            callID: "delete-1",
            tool: .deleteReminder,
            arguments: .init(["reminder_id": .string("private-reminder")])
        )
        let harness = makeHarness(
            mode: .pending(call),
            executors: [StubToolExecutor(toolName: .deleteReminder, riskLevel: .highRiskWrite)]
        )

        let presentation = await harness.coordinator.run(userInput: "删除它", configuration: configuration())
        let decoded = try JSONDecoder().decode(
            AgentConversationPresentation.self,
            from: JSONEncoder().encode(presentation)
        )

        XCTAssertEqual(decoded, presentation)
        XCTAssertEqual(decoded.confirmationPayload?.userInput, "删除它")
        XCTAssertEqual(decoded.confirmationPayload?.pendingToolCalls, [call])
    }

    func testPendingInvocationIsPersistedAsAwaitingConfirmationAndRedacted() async throws {
        let secret = "私人任务标题不应明文落盘"
        let call = AgentToolCall(
            callID: "delete-1",
            tool: .deleteReminder,
            arguments: .init(["title": .string(secret)])
        )
        let defaults = makeDefaults()
        let store = AgentRunStore(defaults: defaults)
        let harness = makeHarness(
            mode: .pending(call),
            executors: [StubToolExecutor(toolName: .deleteReminder, riskLevel: .highRiskWrite)],
            store: store
        )

        let presentation = await harness.coordinator.run(userInput: "删除", configuration: configuration())
        let invocation = try XCTUnwrap(store.run(for: presentation.result.runID)?.toolInvocations.first)
        let persisted = String(decoding: try XCTUnwrap(defaults.data(forKey: AgentRunStore.defaultStorageKey)), as: UTF8.self)

        XCTAssertEqual(invocation.status, .awaitingConfirmation)
        XCTAssertEqual(invocation.riskLevel, .highRiskWrite)
        XCTAssertFalse(persisted.contains(secret))
    }

    func testExecutedToolResultIsPersistedWithRedactedResult() async throws {
        let secret = "工具返回的私人内容"
        let executor = StubToolExecutor(
            toolName: .searchReminders,
            riskLevel: .readOnly,
            output: .init(result: .init(["title": .string(secret)]))
        )
        let defaults = makeDefaults()
        let store = AgentRunStore(defaults: defaults)
        let harness = makeHarness(mode: .executeTool, executors: [executor], store: store)

        let presentation = await harness.coordinator.run(userInput: "查询", configuration: configuration())
        let invocation = try XCTUnwrap(store.run(for: presentation.result.runID)?.toolInvocations.first)
        let persisted = String(decoding: try XCTUnwrap(defaults.data(forKey: AgentRunStore.defaultStorageKey)), as: UTF8.self)

        XCTAssertEqual(invocation.status, .success)
        XCTAssertNotNil(invocation.result)
        XCTAssertFalse(persisted.contains(secret))
    }

    func testConfirmUsesExecuteConfirmedAndReturnsUpdatedPresentation() async {
        let call = AgentToolCall(callID: "delete-1", tool: .deleteReminder)
        let harness = makeHarness(
            mode: .pending(call),
            executors: [StubToolExecutor(toolName: .deleteReminder, riskLevel: .highRiskWrite)]
        )
        let pending = await harness.coordinator.run(userInput: "删除", configuration: configuration())

        let confirmed = await harness.coordinator.confirm(pending)

        let confirmCount = await harness.probe.confirmCount()
        XCTAssertEqual(confirmCount, 1)
        XCTAssertEqual(confirmed.result.status, .succeeded)
        XCTAssertEqual(confirmed.reply, "确认执行完成。")
        XCTAssertNil(confirmed.confirmationPayload)
        XCTAssertFalse(confirmed.allowsLegacyFallback)
    }

    func testConfirmWithoutPayloadFailsWithoutCallingOrchestrator() async {
        let harness = makeHarness(mode: .final(reply: "完成", modelTurns: 1))
        let completed = await harness.coordinator.run(userInput: "处理", configuration: configuration())

        let confirmed = await harness.coordinator.confirm(completed)

        XCTAssertEqual(confirmed.result.status, .failed)
        XCTAssertEqual(confirmed.result.error?.category, .invalidArguments)
        let confirmCount = await harness.probe.confirmCount()
        XCTAssertEqual(confirmCount, 0)
    }

    func testConfirmRestoresOperationsAfterCoordinatorRecreation() async {
        let call = AgentToolCall(callID: "delete-restore", tool: .deleteReminder)
        let firstProbe = CoordinatorTestProbe(mode: .pending(call))
        let first = makeCoordinator(probe: firstProbe) { _ in NeverModelClient() }
        let pending = await first.run(userInput: "删除", configuration: configuration())

        let restoredProbe = CoordinatorTestProbe(mode: .pending(call))
        let restored = makeCoordinator(probe: restoredProbe) { _ in NeverModelClient() }
        let completed = await restored.confirm(pending, configuration: configuration())
        let confirmCount = await restoredProbe.confirmCount()

        XCTAssertEqual(completed.result.status, .succeeded)
        XCTAssertEqual(confirmCount, 1)
        XCTAssertNil(completed.confirmationPayload)
    }

    private func makeHarness(
        mode: CoordinatorTestProbe.Mode,
        executors: [any AgentToolExecutor] = [],
        store: AgentRunStore? = nil
    ) -> (coordinator: AgentConversationCoordinator, store: AgentRunStore, probe: CoordinatorTestProbe) {
        let probe = CoordinatorTestProbe(mode: mode)
        let activeStore = store ?? makeStore()
        let coordinator = AgentConversationCoordinator(
            runStore: activeStore,
            modelClientFactory: { _ in NeverModelClient() },
            toolExecutorsFactory: { executors },
            orchestratorFactory: { _, wrappedExecutors in
                probe.operations(executors: wrappedExecutors)
            }
        )
        return (coordinator, activeStore, probe)
    }

    private func makeCoordinator(
        probe: CoordinatorTestProbe,
        modelFactory: @escaping AgentConversationCoordinator.ModelClientFactory
    ) -> AgentConversationCoordinator {
        AgentConversationCoordinator(
            runStore: makeStore(),
            modelClientFactory: modelFactory,
            toolExecutorsFactory: { [] },
            orchestratorFactory: { _, executors in probe.operations(executors: executors) }
        )
    }

    private func configuration(provider: String = "test") -> AgentModelConfiguration {
        AgentModelConfiguration(
            provider: provider,
            wireAPI: "chat_completions",
            modelID: "offline-test",
            baseURL: "https://invalid.local",
            apiKey: "unused",
            temperature: 0,
            maxTokens: 100,
            timeoutSeconds: 1
        )
    }

    private func makeStore() -> AgentRunStore {
        AgentRunStore(defaults: makeDefaults())
    }

    private func makeDefaults() -> UserDefaults {
        let name = "AgentConversationCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

private actor CoordinatorTestProbe {
    enum Mode: Sendable {
        case final(reply: String, modelTurns: Int)
        case failure(category: AgentToolErrorCategory, toolResults: [AgentToolResult])
        case pending(AgentToolCall)
        case executeTool
    }

    private let mode: Mode
    private var input: String?
    private var confirmations = 0

    init(mode: Mode) {
        self.mode = mode
    }

    nonisolated func operations(
        executors: [any AgentToolExecutor] = []
    ) -> AgentConversationOrchestratorOperations {
        AgentConversationOrchestratorOperations(
            run: { [self] input, runID, _ in
                await run(input: input, runID: runID, executors: executors)
            },
            executeConfirmed: { [self] payload in
                await confirm(payload)
            }
        )
    }

    func lastUserInput() -> String? { input }
    func confirmCount() -> Int { confirmations }

    private func run(
        input: String,
        runID: UUID,
        executors: [any AgentToolExecutor]
    ) async -> AgentRunResult {
        self.input = input
        switch mode {
        case let .final(reply, modelTurns):
            return result(runID: runID, status: .succeeded, reply: reply, modelTurns: modelTurns)
        case let .failure(category, toolResults):
            let normalizedResults = toolResults.map {
                AgentToolResult(
                    runID: runID,
                    callID: $0.callID,
                    tool: $0.tool,
                    status: $0.status,
                    result: $0.result,
                    error: $0.error
                )
            }
            return AgentRunResult(
                runID: runID,
                goal: input,
                status: .failed,
                finalReply: nil,
                modelTurns: 1,
                toolCallCount: normalizedResults.count,
                toolResults: normalizedResults,
                error: AgentToolError(category: category, userVisibleMessage: "测试错误")
            )
        case let .pending(call):
            return AgentRunResult(
                runID: runID,
                goal: input,
                status: .awaitingConfirmation,
                finalReply: "请确认。",
                modelTurns: 1,
                toolCallCount: 0,
                toolResults: [],
                pendingToolCalls: [call],
                error: nil
            )
        case .executeTool:
            guard let executor = executors.first else {
                return result(runID: runID, status: .failed, reply: "缺少工具", modelTurns: 1)
            }
            let output = try? await executor.execute(
                arguments: .init(["query": .string("private-query")]),
                runID: runID,
                callID: "read-1"
            )
            let toolResult = AgentToolResult(
                runID: runID,
                callID: "read-1",
                tool: executor.toolName,
                status: output?.status ?? .failed,
                result: output?.result
            )
            return AgentRunResult(
                runID: runID,
                goal: input,
                status: output == nil ? .failed : .succeeded,
                finalReply: "查询完成。",
                modelTurns: 1,
                toolCallCount: 1,
                toolResults: [toolResult],
                error: nil
            )
        }
    }

    private func confirm(_ payload: AgentConversationConfirmationPayload) -> AgentRunResult {
        confirmations += 1
        return result(runID: payload.runID, status: .succeeded, reply: "确认执行完成。", modelTurns: 0)
    }

    private func result(
        runID: UUID,
        status: AgentRunStatus,
        reply: String,
        modelTurns: Int
    ) -> AgentRunResult {
        AgentRunResult(
            runID: runID,
            goal: "测试目标",
            status: status,
            finalReply: reply,
            modelTurns: modelTurns,
            toolCallCount: 0,
            toolResults: [],
            error: nil
        )
    }
}

private struct NeverModelClient: AgentModelClient {
    func decide(_ request: AgentModelRequest) async throws -> AgentModelDecision {
        throw AgentToolError(category: .networkError, userVisibleMessage: "测试不应调用模型。")
    }
}

private struct StubToolExecutor: AgentToolExecutor {
    let toolName: AgentToolName
    let riskLevel: AgentToolRiskLevel
    let output: AgentToolExecutionOutput

    init(
        toolName: AgentToolName,
        riskLevel: AgentToolRiskLevel,
        output: AgentToolExecutionOutput = .init()
    ) {
        self.toolName = toolName
        self.riskLevel = riskLevel
        self.output = output
    }

    func execute(
        arguments: AgentToolArguments,
        runID: UUID,
        callID: String
    ) async throws -> AgentToolExecutionOutput {
        output
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}
