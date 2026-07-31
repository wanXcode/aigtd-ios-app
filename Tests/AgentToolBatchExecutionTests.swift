import XCTest
@testable import AIGTDReminders

final class AgentToolBatchExecutionTests: XCTestCase {
    private enum TestError: LocalizedError {
        case writeFailed

        var errorDescription: String? { "write failed" }
    }

    func testBestEffortContinuesIndependentItemsAfterFailure() {
        let items = ["one", "two", "three"].map { AgentToolBatchItem(id: $0) }
        var attempted: [String] = []

        let report = AgentToolBatchExecution.execute(items: items) { item in
            attempted.append(item.id)
            if item.id == "two" { throw TestError.writeFailed }
            return item.id == "three" ? .unchanged : .applied
        }

        XCTAssertEqual(attempted, ["one", "two", "three"])
        XCTAssertEqual(report.items.map(\.status), [.applied, .failed, .unchanged])
        XCTAssertEqual(report.appliedCount, 1)
        XCTAssertEqual(report.unchangedCount, 1)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(report.result(for: "two")?.errorMessage, "write failed")
    }

    func testFailedDependencyIsSkippedWhileIndependentItemContinues() {
        let items = [
            AgentToolBatchItem(id: "create-list"),
            AgentToolBatchItem(id: "move", dependencyIDs: ["create-list"]),
            AgentToolBatchItem(id: "independent")
        ]
        var attempted: [String] = []

        let report = AgentToolBatchExecution.execute(items: items) { item in
            attempted.append(item.id)
            if item.id == "create-list" { throw TestError.writeFailed }
            return .applied
        }

        XCTAssertEqual(attempted, ["create-list", "independent"])
        XCTAssertEqual(report.result(for: "move")?.status, .skipped)
        XCTAssertEqual(report.result(for: "move")?.unsuccessfulDependencyIDs, ["create-list"])
        XCTAssertEqual(report.result(for: "independent")?.status, .applied)
    }

    func testRetryRunsOnlyItemsThatHaveNotSucceededAndMergesResults() {
        let items = [
            AgentToolBatchItem(id: "applied"),
            AgentToolBatchItem(id: "unchanged"),
            AgentToolBatchItem(id: "failed"),
            AgentToolBatchItem(id: "dependent", dependencyIDs: ["failed"])
        ]
        let first = AgentToolBatchExecution.execute(items: items) { item in
            switch item.id {
            case "unchanged": return .unchanged
            case "failed": throw TestError.writeFailed
            default: return .applied
            }
        }
        var retried: [String] = []

        let merged = AgentToolBatchExecution.execute(items: items, previousReport: first) { item in
            retried.append(item.id)
            return .applied
        }

        XCTAssertEqual(retried, ["failed", "dependent"])
        XCTAssertEqual(merged.items.map(\.itemID), items.map(\.id))
        XCTAssertEqual(merged.items.map(\.status), [.applied, .unchanged, .applied, .applied])
        XCTAssertEqual(merged.successfulCount, 4)
        XCTAssertEqual(merged.failedCount, 0)
        XCTAssertEqual(merged.skippedCount, 0)
    }

    func testMissingDependencyIsSkipped() {
        let item = AgentToolBatchItem(id: "dependent", dependencyIDs: ["missing"])

        let report = AgentToolBatchExecution.execute(items: [item]) { _ in
            XCTFail("A skipped item must not execute")
            return .applied
        }

        XCTAssertEqual(report.items, [
            AgentToolBatchItemResult(
                itemID: "dependent",
                status: .skipped,
                unsuccessfulDependencyIDs: ["missing"]
            )
        ])
    }

    func testCancellationStopsItemsThatHaveNotStarted() {
        let items = ["one", "two", "three"].map { AgentToolBatchItem(id: $0) }
        var attempted: [String] = []

        let report = AgentToolBatchExecution.execute(items: items) { item in
            attempted.append(item.id)
            if item.id == "two" { throw CancellationError() }
            return .applied
        }

        XCTAssertEqual(attempted, ["one", "two"])
        XCTAssertEqual(report.items.map(\.status), [.applied, .cancelled, .cancelled])
        XCTAssertEqual(report.cancelledCount, 2)
    }

    func testReportMergingReplacesKnownItemsAndAppendsNewItems() {
        let original = AgentToolBatchExecutionReport(items: [
            AgentToolBatchItemResult(itemID: "one", status: .applied),
            AgentToolBatchItemResult(itemID: "two", status: .failed, errorMessage: "old")
        ])
        let newer = AgentToolBatchExecutionReport(items: [
            AgentToolBatchItemResult(itemID: "two", status: .unchanged),
            AgentToolBatchItemResult(itemID: "three", status: .applied)
        ])

        let merged = original.merging(newer)

        XCTAssertEqual(merged.items.map(\.itemID), ["one", "two", "three"])
        XCTAssertEqual(merged.items.map(\.status), [.applied, .unchanged, .applied])
    }
}
