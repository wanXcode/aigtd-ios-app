import XCTest
@testable import AIGTDReminders

final class AgentRecoveryPlannerTests: XCTestCase {
    private let planner = AgentRecoveryPlanner()
    private let runID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testNetworkFailureIsRetryableAndSelected() {
        assertSingleFailure(category: .networkError, kind: .retryable, action: .retry, isSelected: true)
    }

    func testTimeoutErrorIsRetryableAndSelected() {
        assertSingleFailure(category: .timeout, kind: .retryable, action: .retry, isSelected: true)
    }

    func testTimedOutStatusIsRetryableEvenWithoutError() {
        let result = makeResult(status: .timedOut, category: nil)

        let plan = planner.makePlan(from: [result])

        XCTAssertEqual(plan.items.first?.failureKind, .retryable)
        XCTAssertEqual(plan.retryCandidates.count, 1)
    }

    func testTemporaryEventKitFailureIsRetryable() {
        assertSingleFailure(category: .eventKitError, kind: .retryable, action: .retry, isSelected: true)
    }

    func testGenericToolExecutionFailureIsRetryable() {
        assertSingleFailure(category: .toolExecutionFailed, kind: .retryable, action: .retry, isSelected: true)
    }

    func testNotFoundRequiresRefreshAndIsNotSelected() {
        assertSingleFailure(
            category: .notFound,
            kind: .refreshRequired,
            action: .refreshAndReconfirm,
            isSelected: false
        )
    }

    func testPreconditionConflictRequiresRefreshAndReconfirmation() {
        let result = makeResult(category: .preconditionConflict)

        let plan = planner.makePlan(from: [result])

        XCTAssertEqual(plan.items.first?.failureKind, .refreshRequired)
        XCTAssertEqual(plan.items.first?.recommendedAction, .refreshAndReconfirm)
        XCTAssertTrue(plan.items.first?.recommendation.contains("再次确认") == true)
        XCTAssertTrue(plan.retryCandidates.isEmpty)
    }

    func testStaleReferenceListNotFoundAndExpiredPlanRequireRefresh() {
        for category in [
            AgentToolErrorCategory.staleReference,
            .listNotFound,
            .planExpired
        ] {
            let plan = planner.makePlan(from: [makeResult(category: category)])
            XCTAssertEqual(plan.items.first?.failureKind, .refreshRequired, "category: \(category)")
            XCTAssertTrue(plan.retryCandidates.isEmpty)
        }
    }

    func testPermissionDeniedRequiresUserActionWithPermissionAdvice() {
        let plan = planner.makePlan(from: [makeResult(category: .permissionDenied)])

        XCTAssertEqual(plan.items.first?.failureKind, .userActionRequired)
        XCTAssertEqual(plan.items.first?.recommendedAction, .requestUserAction)
        XCTAssertTrue(plan.items.first?.recommendation.contains("系统设置") == true)
        XCTAssertTrue(plan.retryCandidates.isEmpty)
    }

    func testAmbiguousTargetRequiresSpecificUserChoice() {
        let plan = planner.makePlan(from: [makeResult(category: .ambiguousTarget)])

        XCTAssertEqual(plan.items.first?.failureKind, .userActionRequired)
        XCTAssertTrue(plan.items.first?.recommendation.contains("具体任务或清单") == true)
    }

    func testProtocolAndUnknownToolFailuresAreTerminal() {
        for category in [
            AgentToolErrorCategory.invalidArguments,
            .modelProtocolError,
            .unknownTool,
            .budgetExhausted
        ] {
            let plan = planner.makePlan(from: [makeResult(category: category)])
            XCTAssertEqual(plan.items.first?.failureKind, .terminal, "category: \(category)")
            XCTAssertEqual(plan.items.first?.recommendedAction, .stop)
            XCTAssertTrue(plan.retryCandidates.isEmpty)
        }
    }

    func testSuccessUnchangedAlreadyAppliedAndSkippedAreNeverIncluded() {
        let statuses: [AgentToolExecutionStatus] = [.success, .unchanged, .alreadyApplied, .skipped]
        let results = statuses.enumerated().map { index, status in
            makeResult(callID: "call-\(index)", status: status, category: .networkError)
        }

        let plan = planner.makePlan(from: results)

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertTrue(plan.retryCandidates.isEmpty)
        XCTAssertEqual(plan.recommendation, "没有可恢复的失败项。")
    }

    func testQueuedRunningAwaitingConfirmationAndCancelledStatusesAreIgnored() {
        let statuses: [AgentToolExecutionStatus] = [.queued, .running, .awaitingConfirmation, .cancelled]
        let results = statuses.map { makeResult(status: $0, category: .networkError) }

        let plan = planner.makePlan(from: results)

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertTrue(plan.retryCandidates.isEmpty)
    }

    func testRetryCandidatePreservesOriginalRunIDCallIDAndTool() {
        let result = makeResult(
            callID: "original-call-id",
            tool: .updateReminder,
            category: .networkError
        )

        let candidate = planner.makePlan(from: [result]).retryCandidates.first

        XCTAssertEqual(candidate?.runID, runID)
        XCTAssertEqual(candidate?.callID, "original-call-id")
        XCTAssertEqual(candidate?.tool, .updateReminder)
        XCTAssertEqual(candidate?.itemIDs, [])
    }

    func testMixedResultsSelectOnlyFailedOrTimedOutRetryableCallsInOrder() {
        let results = [
            makeResult(callID: "success", status: .success, category: nil),
            makeResult(callID: "network", category: .networkError),
            makeResult(callID: "conflict", category: .preconditionConflict),
            makeResult(callID: "timeout", status: .timedOut, category: nil),
            makeResult(callID: "unchanged", status: .unchanged, category: nil),
            makeResult(callID: "permission", category: .permissionDenied),
            makeResult(callID: "applied", status: .alreadyApplied, category: nil),
            makeResult(callID: "skipped", status: .skipped, category: nil)
        ]

        let plan = planner.makePlan(from: results)

        XCTAssertEqual(plan.items.map(\.callID), ["network", "conflict", "timeout", "permission"])
        XCTAssertEqual(plan.retryCandidates.map(\.callID), ["network", "timeout"])
    }

    func testPlanRecommendationPrioritizesAvailableRetry() {
        let plan = planner.makePlan(from: [
            makeResult(callID: "permission", category: .permissionDenied),
            makeResult(callID: "network", category: .networkError)
        ])

        XCTAssertTrue(plan.hasRetryableFailures)
        XCTAssertTrue(plan.recommendation.contains("重试失败项"))
        XCTAssertTrue(plan.recommendation.contains("不会再次执行"))
    }

    func testFailedResultWithoutErrorIsTerminal() {
        let plan = planner.makePlan(from: [makeResult(category: nil)])

        XCTAssertEqual(plan.items.first?.failureKind, .terminal)
        XCTAssertTrue(plan.retryCandidates.isEmpty)
    }

    func testPartialScheduleSelectsOnlyRetryableFailedItemIDs() {
        let result = AgentToolResult(
            runID: runID,
            callID: "apply-1",
            tool: .applySchedule,
            status: .success,
            result: .init([
                "plan_status": .string("partial"),
                "items": .array([
                    batchItem(id: "done", status: "applied"),
                    batchItem(id: "temporary", status: "failed", category: .eventKitError),
                    batchItem(id: "conflict", status: "failed", category: .preconditionConflict)
                ])
            ])
        )

        let plan = planner.makePlan(from: [result])

        XCTAssertEqual(plan.items.map(\.itemID), ["temporary", "conflict"])
        XCTAssertEqual(plan.retryCandidates.count, 1)
        XCTAssertEqual(plan.retryCandidates.first?.callID, "apply-1")
        XCTAssertEqual(plan.retryCandidates.first?.itemIDs, ["temporary"])
    }

    private func batchItem(
        id: String,
        status: String,
        category: AgentToolErrorCategory? = nil
    ) -> AgentJSONValue {
        var values: [String: AgentJSONValue] = [
            "item_id": .string(id),
            "status": .string(status)
        ]
        if let category {
            values["error_category"] = .string(category.rawValue)
        }
        return .object(values)
    }

    private func assertSingleFailure(
        category: AgentToolErrorCategory,
        kind: AgentRecoveryFailureKind,
        action: AgentRecoveryAction,
        isSelected: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let plan = planner.makePlan(from: [makeResult(category: category)])

        XCTAssertEqual(plan.items.first?.failureKind, kind, file: file, line: line)
        XCTAssertEqual(plan.items.first?.recommendedAction, action, file: file, line: line)
        XCTAssertEqual(plan.retryCandidates.count, isSelected ? 1 : 0, file: file, line: line)
    }

    private func makeResult(
        callID: String = "call-1",
        tool: AgentToolName = .createReminder,
        status: AgentToolExecutionStatus = .failed,
        category: AgentToolErrorCategory?
    ) -> AgentToolResult {
        AgentToolResult(
            runID: runID,
            callID: callID,
            tool: tool,
            status: status,
            error: category.map {
                AgentToolError(category: $0, userVisibleMessage: "test error")
            }
        )
    }
}
