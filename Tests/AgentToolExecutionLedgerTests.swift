import XCTest
@testable import AIGTDReminders

final class AgentToolExecutionLedgerTests: XCTestCase {
    func testRunIDAndCallIDTogetherFormIdempotencyKey() {
        let ledger = AgentToolExecutionLedger()

        ledger.record(runID: "run-1", callID: "call-1", result: .init(status: .success))
        ledger.record(runID: "run-1", callID: "call-2", result: .init(status: .unchanged))
        ledger.record(runID: "run-2", callID: "call-1", result: .init(status: .alreadyApplied))

        XCTAssertEqual(ledger.count, 3)
        XCTAssertEqual(ledger.replay(runID: "run-1", callID: "call-1")?.result.status, .success)
        XCTAssertEqual(ledger.replay(runID: "run-1", callID: "call-2")?.result.status, .unchanged)
        XCTAssertEqual(ledger.replay(runID: "run-2", callID: "call-1")?.result.status, .alreadyApplied)
    }

    func testReplayReturnsOriginalTerminalResultWithoutExecutingAgain() {
        let ledger = AgentToolExecutionLedger()
        var executionCount = 0

        let first = ledger.execute(runID: "run", callID: "call") {
            executionCount += 1
            return AgentToolExecutionResult(status: .success, resultJSON: #"{"id":"reminder-1"}"#)
        }
        let replay = ledger.execute(runID: "run", callID: "call") {
            executionCount += 1
            return AgentToolExecutionResult(status: .unchanged)
        }

        XCTAssertFalse(first.isReplay)
        XCTAssertTrue(replay.isReplay)
        XCTAssertEqual(replay.result, first.result)
        XCTAssertEqual(executionCount, 1)
    }

    func testSuccessUnchangedAndAlreadyAppliedAreReplayable() {
        let statuses: [AgentToolExecutionReplayStatus] = [.success, .unchanged, .alreadyApplied]

        for status in statuses {
            let ledger = AgentToolExecutionLedger()
            ledger.record(runID: "run", callID: "call", result: .init(status: status))
            XCTAssertEqual(ledger.replay(runID: "run", callID: "call")?.result.status, status)
        }
    }

    func testEntryIsRetainedAtTwentyFourHourBoundaryAndExpiresAfterward() {
        final class TestClock: @unchecked Sendable {
            var now = Date(timeIntervalSince1970: 2_000_000_000)
        }
        let clock = TestClock()
        let ledger = AgentToolExecutionLedger(now: { clock.now })
        ledger.record(runID: "run", callID: "call", result: .init(status: .success))

        clock.now.addTimeInterval(24 * 60 * 60)
        XCTAssertNotNil(ledger.replay(runID: "run", callID: "call"))

        clock.now.addTimeInterval(0.001)
        XCTAssertNil(ledger.replay(runID: "run", callID: "call"))
        XCTAssertEqual(ledger.count, 0)
    }

    func testExpiredKeyCanExecuteAgain() {
        final class TestClock: @unchecked Sendable {
            var now = Date(timeIntervalSince1970: 2_000_000_000)
        }
        let clock = TestClock()
        let ledger = AgentToolExecutionLedger(now: { clock.now })
        var executionCount = 0

        _ = ledger.execute(runID: "run", callID: "call") {
            executionCount += 1
            return AgentToolExecutionResult(status: .success)
        }
        clock.now.addTimeInterval(24 * 60 * 60 + 1)
        let second = ledger.execute(runID: "run", callID: "call") {
            executionCount += 1
            return AgentToolExecutionResult(status: .unchanged)
        }

        XCTAssertFalse(second.isReplay)
        XCTAssertEqual(second.result.status, .unchanged)
        XCTAssertEqual(executionCount, 2)
    }

    func testCompletedEntryPersistsAcrossLedgerInstances() {
        let defaults = makeLedgerDefaults()
        let first = AgentToolExecutionLedger(defaults: defaults, storageKey: "ledger")
        first.record(
            runID: "run",
            callID: "call",
            result: AgentToolExecutionResult(status: .success, resultJSON: #"{"ok":true}"#)
        )

        let second = AgentToolExecutionLedger(defaults: defaults, storageKey: "ledger")
        let replay = second.replay(runID: "run", callID: "call")

        XCTAssertEqual(replay?.result.status, .success)
        XCTAssertEqual(replay?.result.resultJSON, #"{"ok":true}"#)
        XCTAssertEqual(replay?.isReplay, true)
    }

    func testCorruptPersistenceClearsOnlyLedgerKey() {
        let defaults = makeLedgerDefaults()
        defaults.set(Data("bad".utf8), forKey: "ledger")
        defaults.set("keep", forKey: "unrelated")

        let ledger = AgentToolExecutionLedger(defaults: defaults, storageKey: "ledger")

        XCTAssertEqual(ledger.count, 0)
        XCTAssertNil(defaults.object(forKey: "ledger"))
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
    }

    func testExpiredPersistedEntryIsRemovedOnReload() {
        let defaults = makeLedgerDefaults()
        let clock = LedgerClock()
        let first = AgentToolExecutionLedger(defaults: defaults, storageKey: "ledger", now: { clock.now })
        first.record(runID: "run", callID: "call", result: .init(status: .success))
        clock.now.addTimeInterval(24 * 60 * 60 + 1)

        let second = AgentToolExecutionLedger(defaults: defaults, storageKey: "ledger", now: { clock.now })

        XCTAssertNil(second.replay(runID: "run", callID: "call"))
        XCTAssertEqual(second.count, 0)
    }

    private func makeLedgerDefaults() -> UserDefaults {
        let suite = "AgentToolExecutionLedgerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

private final class LedgerClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000)
}
