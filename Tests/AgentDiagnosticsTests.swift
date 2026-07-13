import Foundation
import XCTest
@testable import AIGTDReminders

final class AgentDiagnosticsTests: XCTestCase {
    func testDefaultSummaryDoesNotPersistOriginalText() {
        let original = "把季度财务复盘改到周五，备注里有私人信息"

        let summary = AgentDiagnosticRedactor.summarize(
            original,
            structure: ["reply", "action"],
            includesSanitizedPreview: false
        )

        XCTAssertEqual(summary.length, original.utf8.count)
        XCTAssertEqual(summary.sha256.count, 64)
        XCTAssertEqual(summary.structure, ["action", "reply"])
        XCTAssertNil(summary.sanitizedPreview)
        XCTAssertFalse(String(describing: summary).contains(original))
    }

    func testCredentialRedactionIsMandatoryWithPreviewEnabled() throws {
        let apiKey = "sk-secret-value-123456789"
        let content = "Authorization: Bearer \(apiKey) api_key=\(apiKey) access_key=AKLTVOICESECRET123"

        let summary = AgentDiagnosticRedactor.summarize(
            content,
            includesSanitizedPreview: true,
            knownSecrets: [apiKey]
        )

        let preview = try XCTUnwrap(summary.sanitizedPreview)
        XCTAssertFalse(preview.contains(apiKey))
        XCTAssertFalse(preview.localizedCaseInsensitiveContains("Bearer sk-"))
        XCTAssertFalse(preview.contains("AKLTVOICESECRET123"))
        XCTAssertTrue(preview.contains("[REDACTED]"))
    }

    func testUnknownBearerCredentialIsRedactedWithoutKnownSecrets() {
        let preview = AgentDiagnosticRedactor.summarize(
            "Authorization: Bearer provider-generated-secret-987654321",
            includesSanitizedPreview: true
        ).sanitizedPreview

        XCTAssertEqual(preview, "Authorization: Bearer [REDACTED]")
    }

    func testTraceStoreRetainsAtMostTwentyRequests() {
        let defaults = makeDefaults()
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let store = AgentTraceService(defaults: defaults, now: { fixedNow })

        for _ in 0..<25 {
            let traceID = store.beginTrace()
            store.record(traceID: traceID, stage: .inputReceived, status: .success, summaryText: "private title")
        }

        XCTAssertEqual(store.traces().count, 20)
        XCTAssertTrue(store.traces().flatMap(\.stages).allSatisfy { $0.content?.sanitizedPreview == nil })
    }

    func testTraceStorePrunesRequestsOlderThanSevenDays() {
        let defaults = makeDefaults()
        let initialDate = Date(timeIntervalSince1970: 2_000_000_000)
        let initialStore = AgentTraceService(defaults: defaults, now: { initialDate })
        initialStore.beginTrace()
        XCTAssertEqual(initialStore.traces().count, 1)

        let eighthDay = initialDate.addingTimeInterval(8 * 24 * 60 * 60)
        let laterStore = AgentTraceService(defaults: defaults, now: { eighthDay })

        XCTAssertTrue(laterStore.traces().isEmpty)
    }

    func testDisablingFullDebugRemovesPreviouslyStoredPreviews() {
        let defaults = makeDefaults()
        let store = AgentTraceService(defaults: defaults)
        store.isFullDebugEnabled = true
        let traceID = store.beginTrace()
        store.record(traceID: traceID, stage: .remoteResponseReceived, status: .success, summaryText: "private response")
        XCTAssertEqual(store.traces().first?.stages.first?.content?.sanitizedPreview, "private response")

        store.isFullDebugEnabled = false

        XCTAssertNil(store.traces().first?.stages.first?.content?.sanitizedPreview)
    }

    func testRemoteResponseStoreDoesNotPersistRawBodyByDefault() throws {
        let defaults = makeDefaults()
        let store = RemoteResponseDebugStore(defaults: defaults)
        let privateBody = #"{"reply":"private task title","authorization":"Bearer sk-private123456"}"#

        store.save(
            endpoint: "https://example.com/v1/responses",
            wireAPI: "responses",
            statusCode: 200,
            body: privateBody,
            knownSecrets: ["sk-private123456"]
        )

        let snapshot = try XCTUnwrap(store.load())
        XCTAssertNil(snapshot.sanitizedBody)
        XCTAssertEqual(snapshot.bodyLength, privateBody.utf8.count)
        XCTAssertEqual(snapshot.structure, ["authorization", "reply"])
        let persistedData = try XCTUnwrap(defaults.data(forKey: "aigtd.remote-response-debug-snapshots.v2"))
        XCTAssertFalse(String(decoding: persistedData, as: UTF8.self).contains("private task title"))
        XCTAssertFalse(String(decoding: persistedData, as: UTF8.self).contains("sk-private123456"))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AgentDiagnosticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
