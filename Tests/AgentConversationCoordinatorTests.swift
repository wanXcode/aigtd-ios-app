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

    func testRevisionAddsOrderedPendingContextAndForcesAllWritesToConfirmation() async {
        let probe = CoordinatorTestProbe(mode: .final(reply: "已生成新版方案", modelTurns: 1))
        let capturedRules = LockedBox<AgentExecutionPolicyLongTermRules?>(nil)
        let coordinator = AgentConversationCoordinator(
            runStore: makeStore(),
            pendingInteractionStore: makePendingStore(),
            modelClientFactory: { _ in NeverModelClient() },
            toolExecutorsFactory: { [] },
            orchestratorFactory: { _, executors, _, rules in
                capturedRules.withValue { $0 = rules }
                return probe.operations(executors: executors)
            }
        )
        let pending = AgentConversationConfirmationPayload(
            runID: UUID(),
            goal: "把会议改到晚上 7 点，把资料改到晚上 6 点半",
            userInput: "调整两个提醒",
            pendingToolCalls: [
                AgentToolCall(
                    callID: "update-meeting",
                    tool: .updateReminder,
                    arguments: .init(["reminder_id": .string("meeting")])
                ),
                AgentToolCall(
                    callID: "update-materials",
                    tool: .updateReminder,
                    arguments: .init(["reminder_id": .string("materials")])
                )
            ],
            priorToolResults: []
        )

        _ = await coordinator.run(
            userInput: "第二条不要改，只调整第一条",
            configuration: configuration(),
            revisionOf: pending
        )

        let modelInput = await probe.lastUserInput()
        XCTAssertTrue(capturedRules.value?.requireConfirmationForAllWrites == true)
        XCTAssertTrue(modelInput?.contains("旧方案原始请求：调整两个提醒") == true)
        XCTAssertTrue(modelInput?.contains("操作 1：工具 update_reminder") == true)
        XCTAssertTrue(modelInput?.contains("操作 2：工具 update_reminder") == true)
        XCTAssertTrue(modelInput?.contains("必须从新版方案移除该条写操作") == true)
        XCTAssertTrue(modelInput?.contains("用户本轮输入：第二条不要改，只调整第一条") == true)
    }

    func testPlanPreviewAddsProtocolModeAndForcesAllWritesToConfirmation() async {
        let probe = CoordinatorTestProbe(mode: .final(reply: "不应直接结束", modelTurns: 1))
        let capturedRules = LockedBox<AgentExecutionPolicyLongTermRules?>(nil)
        let coordinator = AgentConversationCoordinator(
            runStore: makeStore(),
            pendingInteractionStore: makePendingStore(),
            modelClientFactory: { _ in NeverModelClient() },
            toolExecutorsFactory: { [] },
            orchestratorFactory: { _, executors, _, rules in
                capturedRules.withValue { $0 = rules }
                return probe.operations(executors: executors)
            }
        )

        _ = await coordinator.run(
            userInput: "把 A 改到 8 点，先生成方案，不要执行",
            configuration: configuration()
        )

        let modelInput = await probe.lastUserInput()
        XCTAssertTrue(capturedRules.value?.requireConfirmationForAllWrites == true)
        XCTAssertTrue(modelInput?.contains("[计划预览模式]") == true)
        XCTAssertTrue(modelInput?.contains("必须返回用于生成待确认卡的真实 tool_calls") == true)
    }

    func testDefaultToolFactoryBuildsAllTenTools() async {
        let probe = CoordinatorTestProbe(mode: .final(reply: "完成", modelTurns: 1))
        let names = LockedBox<[AgentToolName]>([])
        let store = makeStore()
        let coordinator = AgentConversationCoordinator(
            runStore: store,
            modelClientFactory: { _ in NeverModelClient() },
            orchestratorFactory: { _, executors, _, _ in
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

    func testLegacyConfirmationPayloadWithoutInteractionMetadataStillDecodes() throws {
        let runID = UUID()
        let legacyJSON = """
        {
          "run_id": "\(runID.uuidString)",
          "goal": "修改会议时间",
          "user_input": "改到明天",
          "pending_tool_calls": [],
          "prior_tool_results": []
        }
        """

        let payload = try JSONDecoder().decode(
            AgentConversationConfirmationPayload.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(payload.runID, runID)
        XCTAssertEqual(payload.goal, "修改会议时间")
        XCTAssertNil(payload.sessionID)
        XCTAssertNil(payload.interactionID)
        XCTAssertNil(payload.interactionVersion)
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

    func testPendingRunPersistsVersionedInteractionForSession() async throws {
        let pendingStore = makePendingStore()
        let harness = makeHarness(
            mode: .pending(AgentToolCall(callID: "update-1", tool: .updateReminder)),
            pendingStore: pendingStore
        )
        let sessionID = UUID()

        let pending = await harness.coordinator.run(
            userInput: "修改会议",
            configuration: configuration(),
            sessionID: sessionID
        )
        let active = try XCTUnwrap(pendingStore.active(for: sessionID))

        XCTAssertEqual(active.runID, pending.result.runID)
        XCTAssertEqual(active.version, 1)
        XCTAssertEqual(pending.confirmationPayload?.sessionID, sessionID)
        XCTAssertEqual(pending.confirmationPayload?.interactionID, active.interactionID)
        XCTAssertEqual(pending.confirmationPayload?.interactionVersion, 1)
    }

    func testConfirmRejectsSupersededInteractionAndExecutesLatest() async {
        let pendingStore = makePendingStore()
        let harness = makeHarness(
            mode: .pending(AgentToolCall(callID: "update-1", tool: .updateReminder)),
            pendingStore: pendingStore
        )
        let sessionID = UUID()
        let first = await harness.coordinator.run(
            userInput: "第一版",
            configuration: configuration(),
            sessionID: sessionID
        )
        let second = await harness.coordinator.run(
            userInput: "第二版",
            configuration: configuration(),
            sessionID: sessionID
        )

        let stale = await harness.coordinator.confirm(first)
        let latest = await harness.coordinator.confirm(second)

        XCTAssertEqual(stale.result.error?.category, .staleReference)
        XCTAssertEqual(latest.result.status, .succeeded)
        let confirmCount = await harness.probe.confirmCount()
        XCTAssertEqual(confirmCount, 1)
        XCTAssertNil(pendingStore.active(for: sessionID))
    }

    func testRevisedPlanSupersedesOldPlanAndConfirmsOnlyRemainingOperation() async throws {
        let pendingStore = makePendingStore()
        let sessionID = UUID()
        let firstProbe = CoordinatorTestProbe(
            mode: .pending(AgentToolCall(callID: "update-b", tool: .updateReminder))
        )
        let firstCoordinator = AgentConversationCoordinator(
            runStore: makeStore(),
            pendingInteractionStore: pendingStore,
            modelClientFactory: { _ in NeverModelClient() },
            toolExecutorsFactory: { [] },
            orchestratorFactory: { _, executors, _, _ in
                firstProbe.operations(executors: executors)
            }
        )
        let original = await firstCoordinator.run(
            userInput: "把 A 和 B 改期",
            configuration: configuration(),
            sessionID: sessionID
        )

        let revisedProbe = CoordinatorTestProbe(
            mode: .pending(AgentToolCall(callID: "update-a-revised", tool: .updateReminder))
        )
        let revisedCoordinator = AgentConversationCoordinator(
            runStore: makeStore(),
            pendingInteractionStore: pendingStore,
            modelClientFactory: { _ in NeverModelClient() },
            toolExecutorsFactory: { [] },
            orchestratorFactory: { _, executors, _, _ in
                revisedProbe.operations(executors: executors)
            }
        )
        let originalPayload = try XCTUnwrap(original.confirmationPayload)
        let revised = await revisedCoordinator.run(
            userInput: "B 不要动，只调整 A",
            configuration: configuration(),
            sessionID: sessionID,
            revisionOf: originalPayload
        )

        let stale = await firstCoordinator.confirm(original)
        let completed = await revisedCoordinator.confirm(revised)
        let confirmedPayload = await revisedProbe.lastConfirmedPayload()

        XCTAssertEqual(stale.result.error?.category, .staleReference)
        XCTAssertEqual(completed.result.status, .succeeded)
        XCTAssertEqual(confirmedPayload?.pendingToolCalls.map(\.callID), ["update-a-revised"])
        XCTAssertNil(pendingStore.active(for: sessionID))
    }

    func testRestartedCoordinatorConfirmsPersistedCurrentInteraction() async throws {
        let pendingStore = makePendingStore()
        let sessionID = UUID()
        let initialProbe = CoordinatorTestProbe(
            mode: .pending(AgentToolCall(callID: "update-after-restart", tool: .updateReminder))
        )
        let initial = AgentConversationCoordinator(
            runStore: makeStore(),
            pendingInteractionStore: pendingStore,
            modelClientFactory: { _ in NeverModelClient() },
            toolExecutorsFactory: { [] },
            orchestratorFactory: { _, executors, _, _ in
                initialProbe.operations(executors: executors)
            }
        )
        let pending = await initial.run(
            userInput: "重启后再确认",
            configuration: configuration(),
            sessionID: sessionID
        )
        let interactionID = try XCTUnwrap(pending.confirmationPayload?.interactionID)

        let restoredProbe = CoordinatorTestProbe(
            mode: .pending(AgentToolCall(callID: "unused", tool: .updateReminder))
        )
        let restored = AgentConversationCoordinator(
            runStore: makeStore(),
            pendingInteractionStore: pendingStore,
            modelClientFactory: { _ in NeverModelClient() },
            toolExecutorsFactory: { [] },
            orchestratorFactory: { _, executors, _, _ in
                restoredProbe.operations(executors: executors)
            }
        )

        XCTAssertEqual(pendingStore.active(for: sessionID)?.interactionID, interactionID)
        let completed = await restored.confirm(pending, configuration: configuration())
        let confirmedPayload = await restoredProbe.lastConfirmedPayload()

        XCTAssertEqual(completed.result.status, .succeeded)
        XCTAssertEqual(confirmedPayload?.pendingToolCalls.map(\.callID), ["update-after-restart"])
        XCTAssertNil(pendingStore.active(for: sessionID))
    }

    func testCancelInvalidatesCurrentInteractionWithoutExecuting() async {
        let pendingStore = makePendingStore()
        let harness = makeHarness(
            mode: .pending(AgentToolCall(callID: "delete-1", tool: .deleteReminder)),
            pendingStore: pendingStore
        )
        let sessionID = UUID()
        let pending = await harness.coordinator.run(
            userInput: "删除会议",
            configuration: configuration(),
            sessionID: sessionID
        )

        let cancelled = harness.coordinator.cancel(pending)

        XCTAssertEqual(cancelled.result.status, .cancelled)
        XCTAssertEqual(cancelled.reply, "已取消这个方案。")
        XCTAssertNil(cancelled.confirmationPayload)
        XCTAssertNil(pendingStore.active(for: sessionID))
        let confirmCount = await harness.probe.confirmCount()
        XCTAssertEqual(confirmCount, 0)
    }

    func testOrdinaryConversationProducesNoActionPayloadOrToolResults() async {
        let harness = makeHarness(mode: .final(reply: "今天先休息，任务不会变化。", modelTurns: 1))

        let presentation = await harness.coordinator.run(
            userInput: "我今天有点累，先不整理任务。",
            configuration: configuration(),
            sessionID: UUID()
        )

        XCTAssertEqual(presentation.result.status, .succeeded)
        XCTAssertTrue(presentation.result.toolResults.isEmpty)
        XCTAssertTrue(presentation.result.pendingToolCalls.isEmpty)
        XCTAssertNil(presentation.confirmationPayload)
    }

    func testRestoreFailureDoesNotConsumePendingInteraction() async throws {
        let pendingStore = makePendingStore()
        let firstProbe = CoordinatorTestProbe(
            mode: .pending(AgentToolCall(callID: "update-1", tool: .updateReminder))
        )
        let first = AgentConversationCoordinator(
            runStore: makeStore(),
            pendingInteractionStore: pendingStore,
            modelClientFactory: { _ in NeverModelClient() },
            toolExecutorsFactory: { [] },
            orchestratorFactory: { _, executors, _, _ in
                firstProbe.operations(executors: executors)
            }
        )
        let sessionID = UUID()
        let pending = await first.run(
            userInput: "修改会议",
            configuration: configuration(),
            sessionID: sessionID
        )
        let interactionID = try XCTUnwrap(pending.confirmationPayload?.interactionID)

        let restored = AgentConversationCoordinator(
            runStore: makeStore(),
            pendingInteractionStore: pendingStore,
            modelClientFactory: { _ in NeverModelClient() },
            toolExecutorsFactory: { [] },
            orchestratorFactory: { _, executors, _, _ in
                firstProbe.operations(executors: executors)
            }
        )
        let failed = await restored.confirm(pending, configuration: nil)

        XCTAssertEqual(failed.result.status, .failed)
        XCTAssertEqual(pendingStore.active(for: sessionID)?.interactionID, interactionID)
    }

    func testRetryFailedRestoresOnlyRetryableOriginalCall() async throws {
        let pendingStore = makePendingStore()
        let call = AgentToolCall(callID: "update-1", tool: .updateReminder)
        let harness = makeHarness(mode: .pending(call), pendingStore: pendingStore)
        let sessionID = UUID()
        let pending = await harness.coordinator.run(
            userInput: "修改任务",
            configuration: configuration(),
            sessionID: sessionID
        )
        let failedResult = AgentToolResult(
            runID: pending.result.runID,
            callID: call.callID,
            tool: call.tool,
            status: .failed,
            error: AgentToolError(category: .networkError, userVisibleMessage: "暂时失败")
        )
        let failed = AgentConversationPresentation(
            result: AgentRunResult(
                runID: pending.result.runID,
                goal: pending.result.goal,
                status: .failed,
                finalReply: "失败",
                modelTurns: 0,
                toolCallCount: 1,
                toolResults: [failedResult],
                error: failedResult.error
            ),
            reply: "失败",
            allowsLegacyFallback: false,
            confirmationPayload: nil
        )

        let retried = await harness.coordinator.retryFailed(failed)
        let payload = await harness.probe.lastConfirmedPayload()

        XCTAssertEqual(retried.result.status, .succeeded)
        XCTAssertEqual(payload?.pendingToolCalls.map(\.callID), ["update-1"])
        XCTAssertEqual(payload?.runID, pending.result.runID)
    }

    func testRetryPartialSchedulePassesOnlyRetryableItemIDs() async throws {
        let pendingStore = makePendingStore()
        let call = AgentToolCall(
            callID: "apply-1",
            tool: .applySchedule,
            arguments: .init(["plan_id": .string(UUID().uuidString)])
        )
        let harness = makeHarness(mode: .pending(call), pendingStore: pendingStore)
        let pending = await harness.coordinator.run(
            userInput: "应用方案",
            configuration: configuration(),
            sessionID: UUID()
        )
        let applyResult = AgentToolResult(
            runID: pending.result.runID,
            callID: call.callID,
            tool: call.tool,
            status: .success,
            result: .init([
                "plan_status": .string("partial"),
                "items": .array([
                    .object(["item_id": .string("temporary"), "status": .string("failed"), "error_category": .string(AgentToolErrorCategory.eventKitError.rawValue)]),
                    .object(["item_id": .string("conflict"), "status": .string("failed"), "error_category": .string(AgentToolErrorCategory.preconditionConflict.rawValue)])
                ])
            ])
        )
        let failed = AgentConversationPresentation(
            result: AgentRunResult(
                runID: pending.result.runID,
                goal: pending.result.goal,
                status: .partial,
                finalReply: "部分完成",
                modelTurns: 0,
                toolCallCount: 1,
                toolResults: [applyResult],
                error: nil
            ),
            reply: "部分完成",
            allowsLegacyFallback: false,
            confirmationPayload: nil
        )

        _ = await harness.coordinator.retryFailed(failed)
        let retryValue = await harness.probe.lastConfirmedPayload()?
            .pendingToolCalls.first?.arguments["retry_item_ids"]
        let retryItems: [String]? = if case let .array(values)? = retryValue {
            values.compactMap { value in
                guard case let .string(itemID) = value else { return nil }
                return itemID
            }
        } else {
            nil
        }

        XCTAssertEqual(retryItems, ["temporary"])
    }

    private func makeHarness(
        mode: CoordinatorTestProbe.Mode,
        executors: [any AgentToolExecutor] = [],
        store: AgentRunStore? = nil,
        pendingStore: AgentPendingInteractionStore? = nil
    ) -> (coordinator: AgentConversationCoordinator, store: AgentRunStore, probe: CoordinatorTestProbe) {
        let probe = CoordinatorTestProbe(mode: mode)
        let activeStore = store ?? makeStore()
        let coordinator = AgentConversationCoordinator(
            runStore: activeStore,
            pendingInteractionStore: pendingStore ?? makePendingStore(),
            modelClientFactory: { _ in NeverModelClient() },
            toolExecutorsFactory: { executors },
            orchestratorFactory: { _, wrappedExecutors, _, _ in
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
            orchestratorFactory: { _, executors, _, _ in probe.operations(executors: executors) }
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

    private func makePendingStore() -> AgentPendingInteractionStore {
        AgentPendingInteractionStore(
            defaults: makeDefaults(),
            storageKey: "pending-interactions"
        )
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
    private var confirmedPayload: AgentConversationConfirmationPayload?

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
    func lastConfirmedPayload() -> AgentConversationConfirmationPayload? { confirmedPayload }

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
        confirmedPayload = payload
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
