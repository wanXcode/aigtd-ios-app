import Foundation
import XCTest
@testable import AIGTDReminders

final class AgentOrchestratorTests: XCTestCase {
    func testReturnsFinalReplyWithoutCallingTools() async {
        let runID = UUID()
        let model = ScriptedModelClient([
            .init(runID: runID, goal: "聊天", phase: .final, finalReply: "今天也辛苦了。")
        ])

        let result = await AgentOrchestrator(modelClient: model).run(userInput: "有点累", runID: runID)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.finalReply, "今天也辛苦了。")
        XCTAssertEqual(result.modelTurns, 1)
        XCTAssertEqual(result.toolCallCount, 0)
    }

    func testFeedsQueryResultBackToModelBeforeFinalDecision() async throws {
        let runID = UUID()
        let queryCall = AgentToolCall(
            callID: "call-search",
            tool: .searchReminders,
            arguments: .init(["query": .string("会议")])
        )
        let model = ScriptedModelClient([
            .init(runID: runID, goal: "查询会议", phase: .toolCalls, toolCalls: [queryCall]),
            .init(runID: runID, goal: "查询会议", phase: .final, finalReply: "找到 1 个会议。")
        ])
        let executor = RecordingToolExecutor(
            toolName: .searchReminders,
            output: .init(result: .init(["count": .integer(1)]))
        )

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [executor]
        ).run(userInput: "查找会议", runID: runID)

        let requests = await model.recordedRequests()
        let executionCount = await executor.executionCount()
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.finalReply, "找到 1 个会议。")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].toolResults.first?.result?["count"], .integer(1))
        XCTAssertEqual(executionCount, 1)
    }

    func testDropsEquivalentUpdateAfterCreatingScheduledReminder() async {
        let runID = UUID()
        let dueDate = "2026-08-01T02:00:00Z"
        let model = ScriptedModelClient([
            .init(
                runID: runID,
                goal: "创建明天上午十点的去上班任务",
                phase: .toolCalls,
                toolCalls: [
                    .init(
                        callID: "create-work",
                        tool: .createReminder,
                        arguments: .init([
                            "title": .string("去上班"),
                            "due_date": .string(dueDate),
                            "includes_time": .bool(true)
                        ])
                    )
                ]
            ),
            .init(
                runID: runID,
                goal: "创建明天上午十点的去上班任务",
                phase: .toolCalls,
                assistantDraft: "已设好：“去上班”在明天上午十点。",
                toolCalls: [
                    .init(
                        callID: "redundant-update",
                        tool: .updateReminder,
                        arguments: .init([
                            "reminder_id": .string("created-id"),
                            "title": .string("去上班"),
                            "due_date": .string(dueDate),
                            "includes_time": .bool(true),
                            "must_exist": .bool(true)
                        ])
                    )
                ]
            )
        ])
        let create = RecordingToolExecutor(
            toolName: .createReminder,
            riskLevel: .lowRiskWrite,
            output: .init(result: .init([
                "reminder_id": .string("created-id"),
                "title": .string("去上班"),
                "due_date": .string(dueDate),
                "includes_time": .bool(true)
            ]))
        )
        let update = RecordingToolExecutor(toolName: .updateReminder, riskLevel: .lowRiskWrite)

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [create, update]
        ).run(userInput: "明天去上班 上午十点", runID: runID)
        let updateCount = await update.executionCount()

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.finalReply, "已设好：“去上班”在明天上午十点。")
        XCTAssertEqual(result.toolCallCount, 1)
        XCTAssertEqual(result.toolResults.map(\.tool), [.createReminder])
        XCTAssertEqual(updateCount, 0)
    }

    func testStopsWhenModelTurnBudgetIsExhausted() async {
        let runID = UUID()
        let calls = (1...AgentOrchestrator.maxModelTurns).map { index in
            AgentModelDecision(
                runID: runID,
                goal: "循环查询",
                phase: .toolCalls,
                toolCalls: [
                    .init(callID: "call-\(index)", tool: .searchReminders)
                ]
            )
        }
        let model = ScriptedModelClient(calls)
        let executor = RecordingToolExecutor(toolName: .searchReminders)

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [executor]
        ).run(userInput: "一直查", runID: runID)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error?.category, .budgetExhausted)
        XCTAssertEqual(result.modelTurns, AgentOrchestrator.maxModelTurns)
        XCTAssertEqual(result.toolCallCount, AgentOrchestrator.maxModelTurns)
    }

    func testRejectsToolCallsBeyondTotalBudgetBeforeExecution() async {
        let runID = UUID()
        let firstCalls = (1...5).map {
            AgentToolCall(callID: "first-\($0)", tool: .searchReminders)
        }
        let secondCalls = (1...4).map {
            AgentToolCall(callID: "second-\($0)", tool: .searchReminders)
        }
        let model = ScriptedModelClient([
            .init(runID: runID, goal: "超预算", phase: .toolCalls, toolCalls: firstCalls),
            .init(runID: runID, goal: "超预算", phase: .toolCalls, toolCalls: secondCalls)
        ])
        let executor = RecordingToolExecutor(toolName: .searchReminders)

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [executor]
        ).run(userInput: "超预算", runID: runID)

        let executionCount = await executor.executionCount()
        XCTAssertEqual(result.error?.category, .budgetExhausted)
        XCTAssertEqual(result.toolCallCount, 5)
        XCTAssertEqual(executionCount, 5)
    }

    func testUnknownToolFailureIsReturnedToModel() async {
        let runID = UUID()
        let model = ScriptedModelClient([
            .init(
                runID: runID,
                goal: "未知工具",
                phase: .toolCalls,
                toolCalls: [.init(callID: "unknown-1", tool: "launch_missiles")]
            ),
            .init(runID: runID, goal: "未知工具", phase: .final, finalReply: "无法执行这个工具。")
        ])

        let result = await AgentOrchestrator(modelClient: model).run(userInput: "执行未知工具", runID: runID)

        let requests = await model.recordedRequests()
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(requests[1].toolResults.first?.status, .failed)
        XCTAssertEqual(requests[1].toolResults.first?.error?.category, .unknownTool)
    }

    func testThrownToolErrorIsStructuredAndReturnedToModel() async {
        let runID = UUID()
        let model = ScriptedModelClient([
            .init(
                runID: runID,
                goal: "读取详情",
                phase: .toolCalls,
                toolCalls: [.init(callID: "details-1", tool: .getReminderDetails)]
            ),
            .init(runID: runID, goal: "读取详情", phase: .final, finalReply: "没有找到该任务。")
        ])
        let executor = RecordingToolExecutor(
            toolName: .getReminderDetails,
            error: AgentToolError(category: .notFound, userVisibleMessage: "任务不存在。")
        )

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [executor]
        ).run(userInput: "读取任务", runID: runID)

        let requests = await model.recordedRequests()
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.finalReply, "这次没有完成：任务不存在。")
        XCTAssertEqual(requests[1].toolResults.first?.error?.category, .notFound)
    }

    func testReminderGatewayListNotFoundKeepsSpecificCategoryAndMessage() async {
        let runID = UUID()
        let model = ScriptedModelClient([
            .init(
                runID: runID,
                goal: "创建任务",
                phase: .toolCalls,
                toolCalls: [.init(callID: "create-1", tool: .createReminder)]
            ),
            .init(runID: runID, goal: "创建任务", phase: .final, finalReply: "没有创建成功。")
        ])
        let executor = GatewayFailingToolExecutor(
            toolName: .createReminder,
            error: .listNotFound("0.5 发布")
        )

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [executor]
        ).run(userInput: "创建任务", runID: runID)

        let requests = await model.recordedRequests()
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(requests[1].toolResults.first?.error?.category, .listNotFound)
        XCTAssertEqual(requests[1].toolResults.first?.error?.userVisibleMessage, "没有找到清单“0.5 发布”。")
    }

    func testCancellationStopsRunBeforeAnotherModelTurn() async {
        let runID = UUID()
        let model = ScriptedModelClient([
            .init(
                runID: runID,
                goal: "慢查询",
                phase: .toolCalls,
                toolCalls: [.init(callID: "slow-1", tool: .searchReminders)]
            )
        ])
        let executor = SuspendingToolExecutor(toolName: .searchReminders)
        let task = Task {
            await AgentOrchestrator(
                modelClient: model,
                toolExecutors: [executor]
            ).run(userInput: "慢查询", runID: runID)
        }

        await executor.waitUntilStarted()
        task.cancel()
        let result = await task.value
        let requestCount = await model.recordedRequests().count

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.error?.category, .cancelled)
        XCTAssertEqual(requestCount, 1)
    }

    func testReadToolTimeoutReturnsTimedOutResult() async {
        let runID = UUID()
        let model = ScriptedModelClient([
            .init(
                runID: runID,
                goal: "慢查询",
                phase: .toolCalls,
                toolCalls: [.init(callID: "slow-read", tool: .searchReminders)
                ]
            )
        ])
        let executor = SuspendingToolExecutor(toolName: .searchReminders)

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [executor],
            toolTimeouts: .init(readOnly: .milliseconds(20), write: .seconds(1), schedule: .seconds(1))
        ).run(userInput: "查询", runID: runID)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.toolResults.first?.status, .timedOut)
        XCTAssertEqual(result.toolResults.first?.error?.category, .timeout)
    }

    func testScheduleToolUsesScheduleTimeout() async {
        let runID = UUID()
        let model = ScriptedModelClient([
            .init(
                runID: runID,
                goal: "慢排期",
                phase: .toolCalls,
                toolCalls: [.init(callID: "slow-plan", tool: .proposeSchedule)]
            )
        ])
        let executor = SuspendingToolExecutor(toolName: .proposeSchedule)

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [executor],
            toolTimeouts: .init(readOnly: .seconds(1), write: .seconds(1), schedule: .milliseconds(20))
        ).run(userInput: "排期", runID: runID)

        XCTAssertEqual(result.toolResults.first?.status, .timedOut)
        XCTAssertEqual(result.toolResults.first?.error?.category, .timeout)
    }

    func testSuccessfulScheduleProposalReturnsConfirmationCardWithoutAnotherModelTurn() async {
        let runID = UUID()
        let planID = UUID().uuidString
        let proposal = AgentToolCall(
            callID: "propose",
            tool: .proposeSchedule,
            arguments: .init(["items": .array([])])
        )
        let model = ScriptedModelClient([
            .init(
                runID: runID,
                goal: "生成三项排期",
                phase: .toolCalls,
                assistantDraft: "方案已生成，暂未执行。",
                toolCalls: [proposal]
            )
        ])
        let executor = RecordingToolExecutor(
            toolName: .proposeSchedule,
            output: .init(result: .init([
                "plan_id": .string(planID),
                "plan_status": .string("awaiting_confirmation"),
                "items": .array([])
            ]))
        )

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [executor]
        ).run(userInput: "先给我看方案，不要执行", runID: runID)

        XCTAssertEqual(result.status, .awaitingConfirmation)
        XCTAssertEqual(result.finalReply, "方案已生成，暂未执行。")
        XCTAssertEqual(result.modelTurns, 1)
        XCTAssertEqual(result.toolCallCount, 1)
        XCTAssertEqual(result.toolResults.map(\.tool), [.proposeSchedule])
        XCTAssertEqual(result.pendingToolCalls.count, 1)
        XCTAssertEqual(result.pendingToolCalls.first?.tool, .applySchedule)
        XCTAssertEqual(result.pendingToolCalls.first?.arguments["plan_id"], .string(planID))
    }

    func testMultipleWritesRequireLocalConfirmationWithoutExecution() async {
        let runID = UUID()
        let calls = [
            AgentToolCall(callID: "one", tool: .updateReminder),
            AgentToolCall(callID: "two", tool: .completeReminder)
        ]
        let model = ScriptedModelClient([
            .init(runID: runID, goal: "批量修改", phase: .toolCalls, toolCalls: calls)
        ])
        let update = RecordingToolExecutor(toolName: .updateReminder, riskLevel: .lowRiskWrite)
        let complete = RecordingToolExecutor(toolName: .completeReminder, riskLevel: .lowRiskWrite)

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [update, complete]
        ).run(userInput: "修改两项", runID: runID)

        let updateCount = await update.executionCount()
        let completeCount = await complete.executionCount()
        XCTAssertEqual(result.status, .awaitingConfirmation)
        XCTAssertEqual(result.pendingToolCalls, calls)
        XCTAssertEqual(updateCount, 0)
        XCTAssertEqual(completeCount, 0)
    }

    func testPendingWritesUseLocalReadSnapshotsInsteadOfModelPreconditions() async throws {
        let runID = UUID()
        let firstDate = "2026-07-18T01:00:00Z"
        let secondDate = "2026-07-18T02:00:00Z"
        let search = RecordingToolExecutor(
            toolName: .searchReminders,
            output: .init(result: .init([
                "items": .array([
                    .object([
                        "reminder_id": .string("a"),
                        "list_id": .string("inbox"),
                        "due_date": .string(firstDate),
                        "is_completed": .bool(false)
                    ]),
                    .object([
                        "reminder_id": .string("b"),
                        "list_id": .string("project"),
                        "due_date": .string(secondDate),
                        "is_completed": .bool(false)
                    ])
                ])
            ]))
        )
        let wrongArguments: AgentToolArguments = .init([
            "expected_list_id": .string("wrong-list"),
            "expected_due_date": .string("2026-08-01T00:00:00Z"),
            "expected_completion": .bool(true),
            "must_exist": .bool(false)
        ])
        let model = ScriptedModelClient([
            .init(
                runID: runID,
                goal: "批量改期",
                phase: .toolCalls,
                toolCalls: [.init(callID: "search", tool: .searchReminders)]
            ),
            .init(
                runID: runID,
                goal: "批量改期",
                phase: .toolCalls,
                toolCalls: [
                    .init(
                        callID: "update-a",
                        tool: .updateReminder,
                        arguments: AgentToolArguments(wrongArguments.values.merging([
                            "reminder_id": .string("a"),
                            "due_date": .string("2026-07-19T01:00:00Z")
                        ], uniquingKeysWith: { _, new in new }))
                    ),
                    .init(
                        callID: "update-b",
                        tool: .updateReminder,
                        arguments: AgentToolArguments(wrongArguments.values.merging([
                            "reminder_id": .string("b"),
                            "due_date": .string("2026-07-19T02:00:00Z")
                        ], uniquingKeysWith: { _, new in new }))
                    )
                ]
            )
        ])

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [
                search,
                RecordingToolExecutor(toolName: .updateReminder, riskLevel: .lowRiskWrite)
            ]
        ).run(userInput: "分别改期", runID: runID)

        XCTAssertEqual(result.status, .awaitingConfirmation)
        let pending = result.pendingToolCalls
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending[0].arguments["expected_list_id"], .string("inbox"))
        XCTAssertEqual(pending[0].arguments["expected_due_date"], .string(firstDate))
        XCTAssertEqual(pending[0].arguments["expected_completion"], .bool(false))
        XCTAssertEqual(pending[0].arguments["must_exist"], .bool(true))
        XCTAssertEqual(pending[1].arguments["expected_list_id"], .string("project"))
        XCTAssertEqual(pending[1].arguments["expected_due_date"], .string(secondDate))
        XCTAssertEqual(pending[1].arguments["expected_completion"], .bool(false))
        XCTAssertEqual(pending[1].arguments["must_exist"], .bool(true))
    }

    func testPendingWritesAutomaticallyReadMissingSnapshots() async {
        let runID = UUID()
        let originalDate = "2026-07-18T02:00:00Z"
        let details = RecordingToolExecutor(
            toolName: .getReminderDetails,
            output: .init(result: .init([
                "items": .array([
                    .object([
                        "reminder_id": .string("a"),
                        "list_id": .string("inbox"),
                        "due_date": .string(originalDate),
                        "is_completed": .bool(false)
                    ]),
                    .object([
                        "reminder_id": .string("b"),
                        "list_id": .string("inbox"),
                        "due_date": .string(originalDate),
                        "is_completed": .bool(false)
                    ])
                ])
            ]))
        )
        let model = ScriptedModelClient([
            .init(
                runID: runID,
                goal: "直接批量改期",
                phase: .toolCalls,
                toolCalls: ["a", "b"].map { id in
                    .init(
                        callID: "update-\(id)",
                        tool: .updateReminder,
                        arguments: .init([
                            "reminder_id": .string(id),
                            "due_date": .string("2026-07-19T02:00:00Z"),
                            "expected_due_date": .string("2026-08-01T00:00:00Z"),
                            "must_exist": .bool(true)
                        ])
                    )
                }
            )
        ])

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [
                details,
                RecordingToolExecutor(toolName: .updateReminder, riskLevel: .lowRiskWrite)
            ]
        ).run(userInput: "直接改两项", runID: runID)

        let detailCount = await details.executionCount()
        XCTAssertEqual(result.status, .awaitingConfirmation)
        XCTAssertEqual(detailCount, 1)
        XCTAssertEqual(result.toolCallCount, 1)
        XCTAssertEqual(result.pendingToolCalls.count, 2)
        XCTAssertTrue(result.pendingToolCalls.allSatisfy {
            $0.arguments["expected_due_date"] == .string(originalDate)
        })
    }

    func testFailedDependencySkipsFollowingConfirmedWrite() async {
        let runID = UUID()
        let first = AgentToolCall(callID: "create-list", tool: .createList)
        let second = AgentToolCall(
            callID: "move-task",
            tool: .moveReminder,
            dependencyCallIDs: ["create-list"]
        )
        let createList = RecordingToolExecutor(
            toolName: .createList,
            riskLevel: .lowRiskWrite,
            error: AgentToolError(category: .eventKitError, userVisibleMessage: "清单创建失败")
        )
        let move = RecordingToolExecutor(toolName: .moveReminder, riskLevel: .lowRiskWrite)
        let orchestrator = AgentOrchestrator(
            modelClient: ScriptedModelClient([]),
            toolExecutors: [createList, move]
        )

        let result = await orchestrator.executeConfirmed(
            [first, second],
            runID: runID,
            goal: "创建后移动",
            userInput: "创建清单并移动"
        )
        let moveCount = await move.executionCount()

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.toolResults.map(\.status), [.failed, .skipped])
        XCTAssertEqual(moveCount, 0)
    }

    func testConfirmedPartialReplyDoesNotCountPreflightReadAsCompletedOperation() async {
        let runID = UUID()
        let preflight = AgentToolResult(
            runID: runID,
            callID: "local-preflight",
            tool: .getReminderDetails,
            status: .success
        )
        let update = RecordingToolExecutor(toolName: .updateReminder, riskLevel: .lowRiskWrite)
        let complete = RecordingToolExecutor(
            toolName: .completeReminder,
            riskLevel: .lowRiskWrite,
            error: AgentToolError(
                category: .preconditionConflict,
                userVisibleMessage: "任务已发生变化。"
            )
        )
        let result = await AgentOrchestrator(
            modelClient: ScriptedModelClient([]),
            toolExecutors: [update, complete]
        ).executeConfirmed(
            [
                .init(callID: "update", tool: .updateReminder),
                .init(callID: "complete", tool: .completeReminder)
            ],
            runID: runID,
            goal: "部分执行",
            priorToolResults: [preflight],
            userInput: "执行"
        )

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.finalReply, "已完成 1 项，另有 1 项未成功。")
    }

    func testConfirmedScheduleUsesItemCountsAndReportsPartialPlan() async {
        let runID = UUID()
        let apply = RecordingToolExecutor(
            toolName: .applySchedule,
            riskLevel: .mediumRiskWrite,
            output: .init(result: .init([
                "plan_status": .string("partial"),
                "successful_count": .integer(2),
                "failed_count": .integer(1)
            ]))
        )
        let result = await AgentOrchestrator(
            modelClient: ScriptedModelClient([]),
            toolExecutors: [apply]
        ).executeConfirmed(
            [.init(callID: "apply", tool: .applySchedule)],
            runID: runID,
            goal: "执行三项排期",
            userInput: "执行"
        )

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.finalReply, "已完成 2 项，另有 1 项未成功。")
    }

    func testSingleMediumRiskWriteRequiresConfirmation() async {
        let runID = UUID()
        let call = AgentToolCall(callID: "apply", tool: .applySchedule)
        let model = ScriptedModelClient([
            .init(runID: runID, goal: "应用方案", phase: .toolCalls, toolCalls: [call])
        ])
        let executor = RecordingToolExecutor(toolName: .applySchedule, riskLevel: .mediumRiskWrite)

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [executor]
        ).run(userInput: "应用", runID: runID)

        let executionCount = await executor.executionCount()
        XCTAssertEqual(result.status, .awaitingConfirmation)
        XCTAssertEqual(executionCount, 0)
    }

    func testSingleLowRiskWriteExecutesWithoutConfirmation() async {
        let runID = UUID()
        let call = AgentToolCall(callID: "create", tool: .createReminder)
        let model = ScriptedModelClient([
            .init(runID: runID, goal: "新建", phase: .toolCalls, toolCalls: [call]),
            .init(runID: runID, goal: "新建", phase: .final, finalReply: "创建好了。")
        ])
        let executor = RecordingToolExecutor(toolName: .createReminder, riskLevel: .lowRiskWrite)

        let result = await AgentOrchestrator(
            modelClient: model,
            toolExecutors: [executor]
        ).run(userInput: "新建", runID: runID)

        let executionCount = await executor.executionCount()
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(executionCount, 1)
    }

    func testExecuteConfirmedAddsConfirmationAndRunsPendingCalls() async {
        let runID = UUID()
        let call = AgentToolCall(callID: "delete", tool: .deleteReminder)
        let executor = RecordingToolExecutor(toolName: .deleteReminder, riskLevel: .highRiskWrite)
        let orchestrator = AgentOrchestrator(modelClient: ScriptedModelClient([]), toolExecutors: [executor])

        let result = await orchestrator.executeConfirmed(
            [call],
            runID: runID,
            goal: "删除",
            userInput: "删除"
        )

        let executionCount = await executor.executionCount()
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.finalReply, "已完成确认的 1 项操作。")
        XCTAssertEqual(executionCount, 1)
    }
}

private actor ScriptedModelClient: AgentModelClient {
    private var decisions: [AgentModelDecision]
    private var requests: [AgentModelRequest] = []

    init(_ decisions: [AgentModelDecision]) {
        self.decisions = decisions
    }

    func decide(_ request: AgentModelRequest) async throws -> AgentModelDecision {
        requests.append(request)
        guard decisions.isEmpty == false else {
            throw AgentToolError(category: .modelProtocolError, userVisibleMessage: "No scripted decision")
        }
        return decisions.removeFirst()
    }

    func recordedRequests() -> [AgentModelRequest] {
        requests
    }
}

private actor RecordingToolExecutor: AgentToolExecutor {
    nonisolated let toolName: AgentToolName
    nonisolated let riskLevel: AgentToolRiskLevel
    private let output: AgentToolExecutionOutput
    private let error: AgentToolError?
    private var callCount = 0

    init(
        toolName: AgentToolName,
        riskLevel: AgentToolRiskLevel = .readOnly,
        output: AgentToolExecutionOutput = .init(),
        error: AgentToolError? = nil
    ) {
        self.toolName = toolName
        self.riskLevel = riskLevel
        self.output = output
        self.error = error
    }

    func execute(
        arguments: AgentToolArguments,
        runID: UUID,
        callID: String
    ) async throws -> AgentToolExecutionOutput {
        callCount += 1
        if let error {
            throw error
        }
        return output
    }

    func executionCount() -> Int {
        callCount
    }
}

private actor SuspendingToolExecutor: AgentToolExecutor {
    nonisolated let toolName: AgentToolName
    nonisolated let riskLevel: AgentToolRiskLevel = .readOnly
    private var started = false

    init(toolName: AgentToolName) {
        self.toolName = toolName
    }

    func execute(
        arguments: AgentToolArguments,
        runID: UUID,
        callID: String
    ) async throws -> AgentToolExecutionOutput {
        started = true
        try await Task.sleep(for: .seconds(60))
        return .init()
    }

    func waitUntilStarted() async {
        while started == false {
            await Task.yield()
        }
    }
}

private actor GatewayFailingToolExecutor: AgentToolExecutor {
    nonisolated let toolName: AgentToolName
    nonisolated let riskLevel: AgentToolRiskLevel = .lowRiskWrite
    private let error: ReminderGatewayError

    init(toolName: AgentToolName, error: ReminderGatewayError) {
        self.toolName = toolName
        self.error = error
    }

    func execute(
        arguments: AgentToolArguments,
        runID: UUID,
        callID: String
    ) async throws -> AgentToolExecutionOutput {
        throw error
    }
}
