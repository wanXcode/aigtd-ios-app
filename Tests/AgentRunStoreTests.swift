import Foundation
import XCTest
@testable import AIGTDReminders

final class AgentRunStoreTests: XCTestCase {
    func testBeginRunPersistsStatusAndStartTime() throws {
        let defaults = makeDefaults()
        let start = Date(timeIntervalSince1970: 2_200_000_000)
        let runID = UUID()
        let store = AgentRunStore(defaults: defaults, now: { start })

        store.beginRun(runID: runID, status: .deciding)

        let reloaded = try XCTUnwrap(AgentRunStore(defaults: defaults).run(for: runID))
        XCTAssertEqual(reloaded.runID, runID)
        XCTAssertEqual(reloaded.status.rawValue, AgentRunStatus.deciding.rawValue)
        XCTAssertEqual(reloaded.startedAt, start)
        XCTAssertNil(reloaded.endedAt)
    }

    func testBeginRunIsIdempotentForSameRunID() {
        let store = AgentRunStore(defaults: makeDefaults())
        let runID = UUID()

        store.beginRun(runID: runID)
        store.beginRun(runID: runID, status: .failed)

        XCTAssertEqual(store.runs().count, 1)
        XCTAssertEqual(store.run(for: runID)?.status.rawValue, AgentRunStatus.preparingContext.rawValue)
    }

    func testModelTurnsArePersistedInTurnOrderAndUpdatedByNumber() throws {
        let store = AgentRunStore(defaults: makeDefaults())
        let runID = store.beginRun().runID
        let firstStart = Date(timeIntervalSince1970: 100)
        let updatedStart = Date(timeIntervalSince1970: 200)

        store.recordModelTurn(runID: runID, turn: 2, phase: .final)
        store.recordModelTurn(runID: runID, turn: 1, phase: .toolCalls, startedAt: firstStart)
        store.recordModelTurn(runID: runID, turn: 1, phase: .awaitingClarification, startedAt: updatedStart)

        let turns = try XCTUnwrap(store.run(for: runID)).modelTurns
        XCTAssertEqual(turns.map(\.turn), [1, 2])
        XCTAssertEqual(turns[0].phase?.rawValue, AgentModelDecisionPhase.awaitingClarification.rawValue)
        XCTAssertEqual(turns[0].startedAt, updatedStart)
    }

    func testInvocationStoresOnlyArgumentStructureAndHash() throws {
        let defaults = makeDefaults()
        let store = AgentRunStore(defaults: defaults)
        let runID = store.beginRun().runID
        let privateTitle = "季度财务复盘-绝不能落盘"
        let privateNotes = "私人备注-绝不能落盘"
        let call = AgentToolCall(
            callID: "call-1",
            tool: .createReminder,
            arguments: AgentToolArguments([
                "title": .string(privateTitle),
                "details": .object(["notes": .string(privateNotes), "flagged": .bool(true)])
            ])
        )

        let invocation = try XCTUnwrap(store.recordToolInvocation(
            runID: runID,
            call: call,
            riskLevel: .lowRiskWrite,
            status: .queued
        ))

        XCTAssertEqual(invocation.arguments.sha256.count, 64)
        XCTAssertEqual(invocation.arguments.fields.map(\.path), ["details", "details.flagged", "details.notes", "title"])
        let persisted = String(decoding: try XCTUnwrap(defaults.data(forKey: AgentRunStore.defaultStorageKey)), as: UTF8.self)
        XCTAssertFalse(persisted.contains(privateTitle))
        XCTAssertFalse(persisted.contains(privateNotes))
    }

    func testInvocationResultAlsoExcludesRawValues() throws {
        let defaults = makeDefaults()
        let store = AgentRunStore(defaults: defaults)
        let runID = store.beginRun().runID
        let privateResult = "返回的私人任务标题"

        let invocation = try XCTUnwrap(store.recordToolInvocation(
            runID: runID,
            call: AgentToolCall(callID: "call-result", tool: .searchReminders),
            riskLevel: .readOnly,
            status: .success,
            result: AgentToolArguments(["items": .array([.object(["title": .string(privateResult)])])])
        ))

        XCTAssertEqual(invocation.result?.fields.map(\.path), ["items", "items[]", "items[].title"])
        let persisted = String(decoding: try XCTUnwrap(defaults.data(forKey: AgentRunStore.defaultStorageKey)), as: UTF8.self)
        XCTAssertFalse(persisted.contains(privateResult))
    }

    func testArgumentHashIsStableAcrossDictionaryOrder() {
        let first = AgentRunPayloadSummary(arguments: AgentToolArguments([
            "title": .string("A"), "count": .integer(2)
        ]))
        let second = AgentRunPayloadSummary(arguments: AgentToolArguments([
            "count": .integer(2), "title": .string("A")
        ]))

        XCTAssertEqual(first.sha256, second.sha256)
        XCTAssertEqual(first.fields, second.fields)
    }

    func testArgumentHashChangesWhenAValueChangesWithoutChangingStructure() {
        let first = AgentRunPayloadSummary(arguments: AgentToolArguments(["title": .string("A")]))
        let second = AgentRunPayloadSummary(arguments: AgentToolArguments(["title": .string("B")]))

        XCTAssertNotEqual(first.sha256, second.sha256)
        XCTAssertEqual(first.fields, second.fields)
    }

    func testArgumentHashMatchesKnownSHA256Vector() {
        let summary = AgentRunPayloadSummary(arguments: AgentToolArguments())

        XCTAssertEqual(summary.sha256, "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
    }

    func testInvocationUpdatePreservesIdentityAndStartTime() throws {
        let store = AgentRunStore(defaults: makeDefaults())
        let runID = store.beginRun().runID
        let startedAt = Date(timeIntervalSince1970: 300)
        let endedAt = Date(timeIntervalSince1970: 320)
        let call = AgentToolCall(callID: "call", tool: .searchReminders)
        let queued = try XCTUnwrap(store.recordToolInvocation(
            runID: runID,
            call: call,
            riskLevel: .readOnly,
            status: .queued,
            startedAt: startedAt
        ))

        let completed = try XCTUnwrap(store.recordToolInvocation(
            runID: runID,
            call: call,
            riskLevel: .readOnly,
            status: .success,
            result: AgentToolArguments(["items": .array([])]),
            endedAt: endedAt
        ))

        XCTAssertEqual(completed.id, queued.id)
        XCTAssertEqual(completed.startedAt, startedAt)
        XCTAssertEqual(completed.endedAt, endedAt)
        XCTAssertEqual(store.run(for: runID)?.toolInvocations.count, 1)
    }

    func testStandardErrorsAreRecordedForRunTurnAndInvocation() throws {
        let store = AgentRunStore(defaults: makeDefaults())
        let runID = store.beginRun().runID
        store.recordModelTurn(runID: runID, turn: 1, errorCategory: .networkError)
        store.recordToolInvocation(
            runID: runID,
            call: AgentToolCall(callID: "call", tool: .updateReminder),
            riskLevel: .mediumRiskWrite,
            status: .failed,
            errorCategory: .notFound
        )
        store.finishRun(runID: runID, status: .failed, errorCategory: .toolExecutionFailed)

        let run = try XCTUnwrap(store.run(for: runID))
        XCTAssertEqual(run.errorCategory?.rawValue, AgentToolErrorCategory.toolExecutionFailed.rawValue)
        XCTAssertEqual(run.modelTurns.first?.errorCategory?.rawValue, AgentToolErrorCategory.networkError.rawValue)
        XCTAssertEqual(run.toolInvocations.first?.errorCategory?.rawValue, AgentToolErrorCategory.notFound.rawValue)
    }

    func testFinishRunRecordsEndTime() throws {
        let end = Date(timeIntervalSince1970: 500)
        let store = AgentRunStore(defaults: makeDefaults(), now: { end })
        let runID = store.beginRun(startedAt: Date(timeIntervalSince1970: 400)).runID

        store.finishRun(runID: runID, status: .succeeded)

        let run = try XCTUnwrap(store.run(for: runID))
        XCTAssertEqual(run.status.rawValue, AgentRunStatus.succeeded.rawValue)
        XCTAssertEqual(run.endedAt, end)
    }

    func testCorruptDataRecoversAndOnlyClearsRunStoreKey() {
        let defaults = makeDefaults()
        defaults.set(Data("not-json".utf8), forKey: AgentRunStore.defaultStorageKey)
        defaults.set("keep-me", forKey: "unrelated-setting")
        let store = AgentRunStore(defaults: defaults)

        XCTAssertTrue(store.runs().isEmpty)
        XCTAssertNil(defaults.object(forKey: AgentRunStore.defaultStorageKey))
        XCTAssertEqual(defaults.string(forKey: "unrelated-setting"), "keep-me")
    }

    func testUnsupportedSchemaRecoversAndOnlyClearsRunStoreKey() throws {
        let defaults = makeDefaults()
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 999, "runs": []])
        defaults.set(data, forKey: AgentRunStore.defaultStorageKey)
        defaults.set(true, forKey: "privacy-setting")

        XCTAssertTrue(AgentRunStore(defaults: defaults).runs().isEmpty)
        XCTAssertNil(defaults.data(forKey: AgentRunStore.defaultStorageKey))
        XCTAssertTrue(defaults.bool(forKey: "privacy-setting"))
    }

    func testClearAndRemoveAreScoped() {
        let defaults = makeDefaults()
        let store = AgentRunStore(defaults: defaults)
        let first = store.beginRun().runID
        let second = store.beginRun().runID
        defaults.set("chat-data", forKey: "chat-history")

        store.remove(runID: first)
        XCTAssertNil(store.run(for: first))
        XCTAssertNotNil(store.run(for: second))
        store.clear()

        XCTAssertTrue(store.runs().isEmpty)
        XCTAssertEqual(defaults.string(forKey: "chat-history"), "chat-data")
    }

    func testCustomDefaultsAndStorageKeyAreUsed() {
        let defaults = makeDefaults()
        let key = "custom-agent-run-key"
        let store = AgentRunStore(defaults: defaults, storageKey: key)

        store.beginRun()

        XCTAssertNotNil(defaults.data(forKey: key))
        XCTAssertNil(defaults.data(forKey: AgentRunStore.defaultStorageKey))
    }

    func testMissingRunMutationsDoNotCreatePartialRun() {
        let store = AgentRunStore(defaults: makeDefaults())
        let missingID = UUID()

        XCTAssertNil(store.updateStatus(runID: missingID, status: .failed))
        XCTAssertNil(store.recordModelTurn(runID: missingID, turn: 1))
        XCTAssertNil(store.recordToolInvocation(
            runID: missingID,
            call: AgentToolCall(callID: "call", tool: .searchReminders),
            riskLevel: .readOnly,
            status: .queued
        ))
        XCTAssertTrue(store.runs().isEmpty)
    }

    func testConcurrentWritesDoNotLoseRuns() {
        let store = AgentRunStore(defaults: makeDefaults())
        let runIDs = (0..<40).map { _ in UUID() }

        DispatchQueue.concurrentPerform(iterations: runIDs.count) { index in
            store.beginRun(runID: runIDs[index])
        }

        XCTAssertEqual(Set(store.runs().map(\.runID)), Set(runIDs))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AgentRunStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
