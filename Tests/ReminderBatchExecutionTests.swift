import XCTest
@testable import AIGTDReminders

final class ReminderBatchExecutionTests: XCTestCase {
    private enum TestError: LocalizedError {
        case writeFailed

        var errorDescription: String? { "模拟写入失败" }
    }

    func testExecutionContinuesAfterIndividualFailureAndReturnsPartial() {
        let items = makeItems(count: 4)
        var attemptedIDs: [String] = []

        let report = ReminderBatchExecution.execute(items: items) { item in
            attemptedIDs.append(item.reminderID)
            if item.reminderID == "id-2" {
                throw TestError.writeFailed
            }
        }

        XCTAssertEqual(attemptedIDs, ["id-1", "id-2", "id-3", "id-4"])
        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.totalCount, 4)
        XCTAssertEqual(report.successCount, 3)
        XCTAssertEqual(report.failureCount, 1)
        XCTAssertEqual(report.failedItems.first?.title, "任务 2")
        XCTAssertEqual(report.failedItems.first?.errorMessage, "模拟写入失败")
    }

    func testAllSuccessfulItemsReturnSuccess() {
        let report = ReminderBatchExecution.execute(items: makeItems(count: 3)) { _ in }

        XCTAssertEqual(report.status, .success)
        XCTAssertEqual(report.successCount, 3)
        XCTAssertEqual(report.failureCount, 0)
    }

    func testAllFailedItemsReturnFailed() {
        let report = ReminderBatchExecution.execute(items: makeItems(count: 2)) { _ in
            throw TestError.writeFailed
        }

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.successCount, 0)
        XCTAssertEqual(report.failureCount, 2)
    }

    func testRefreshFailureIsRecordedSeparatelyAndDowngradesToPartial() {
        let writeReport = ReminderBatchExecution.execute(items: makeItems(count: 2)) { _ in }
        let report = writeReport.recordingRefreshFailure("同步服务暂不可用")

        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.successCount, 2)
        XCTAssertEqual(report.failureCount, 0)
        XCTAssertEqual(report.refreshErrorMessage, "同步服务暂不可用")
    }

    func testFailureTitlesAreLimitedToThree() {
        let report = ReminderBatchExecution.execute(items: makeItems(count: 5)) { _ in
            throw TestError.writeFailed
        }

        XCTAssertEqual(report.failureTitles(limit: 3), ["任务 1", "任务 2", "任务 3"])
    }

    private func makeItems(count: Int) -> [ReschedulePlanItem] {
        (1...count).map { index in
            ReschedulePlanItem(
                reminderID: "id-\(index)",
                title: "任务 \(index)",
                listTitle: "收集箱",
                dueDateISO8601: "2026-07-\(String(format: "%02d", 13 + index))T01:00:00Z"
            )
        }
    }
}
