import Foundation
import XCTest
@testable import AIGTDReminders

final class AgentSessionSummaryTests: XCTestCase {
    private let service = AgentSessionSummaryService()

    func testDoesNotCreateSummaryAtEightValidMessages() {
        XCTAssertNil(service.update(existing: nil, messages: messages(count: 8)))
    }

    func testCreatesDeterministicStructuredSummaryAfterEightMessages() {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        var input = messages(count: 8)
        let finalID = UUID()
        input.append(AgentSummaryMessage(
            id: finalID,
            role: .user,
            currentGoal: "整理本周任务",
            taskScope: "工作清单",
            confirmedConstraints: ["周五前完成", "周五前完成"],
            pendingQuestions: ["是否包含已完成任务？"]
        ))

        let summary = service.update(existing: nil, messages: input, now: now)

        XCTAssertEqual(summary?.currentGoal, "整理本周任务")
        XCTAssertEqual(summary?.taskScope, "工作清单")
        XCTAssertEqual(summary?.confirmedConstraints, ["周五前完成"])
        XCTAssertEqual(summary?.pendingQuestions, ["是否包含已完成任务？"])
        XCTAssertEqual(summary?.coveredThroughMessageID, finalID)
        XCTAssertEqual(summary?.updatedAt, now)
    }

    func testIncrementalUpdateWaitsForSixNewValidMessages() {
        let initialMessages = messages(count: 9)
        let existing = service.update(existing: nil, messages: initialMessages)!
        let fiveMore = initialMessages + messages(count: 5)
        let sixMore = initialMessages + messages(count: 6)

        XCTAssertEqual(service.update(existing: existing, messages: fiveMore), existing)
        XCTAssertNotEqual(service.update(existing: existing, messages: sixMore), existing)
    }

    func testSystemMessagesDoNotCountAsValidMessages() {
        let input = messages(count: 8) + [AgentSummaryMessage(id: UUID(), role: .system)]
        XCTAssertNil(service.update(existing: nil, messages: input))
    }

    func testSuccessfulActionUpdatesImmediatelyAndRetainsFactAndIDs() {
        let input = messages(count: 2)
        let action = AgentActionSummaryFact(
            messageID: input.last?.id,
            kind: .move,
            succeeded: true,
            readableFact: "已将季度复盘移动到工作清单",
            reminderIDs: ["reminder-2", "reminder-2"]
        )

        let summary = service.update(existing: nil, messages: input, actionFacts: [action])

        XCTAssertEqual(summary?.confirmedConstraints, ["已执行：已将季度复盘移动到工作清单"])
        XCTAssertEqual(summary?.relatedReminderIDs, ["reminder-2"])
    }

    func testFailedActionAndCredentialsNeverEnterSummary() {
        var input = messages(count: 8)
        input.append(AgentSummaryMessage(
            id: UUID(),
            role: .user,
            currentGoal: "使用 API Key secret-value",
            confirmedConstraints: ["Authorization: Bearer abc", "只处理工作任务"]
        ))
        let failed = AgentActionSummaryFact(
            kind: .delete,
            succeeded: false,
            readableFact: "已删除任务",
            reminderIDs: ["must-not-appear"]
        )

        let summary = service.update(existing: nil, messages: input, actionFacts: [failed])

        XCTAssertNil(summary?.currentGoal)
        XCTAssertEqual(summary?.confirmedConstraints, ["只处理工作任务"])
        XCTAssertTrue(summary?.relatedReminderIDs.isEmpty == true)
    }

    func testSummaryContentStaysWithinPRDBudgetAndRetainsIDs() {
        var input = messages(count: 8)
        input.append(AgentSummaryMessage(
            id: UUID(),
            role: .user,
            currentGoal: String(repeating: "目标", count: 120),
            taskScope: String(repeating: "范围", count: 120),
            confirmedConstraints: (0..<16).map { "约束\($0)" + String(repeating: "甲", count: 230) },
            pendingQuestions: (0..<12).map { "问题\($0)" + String(repeating: "乙", count: 230) }
        ))
        let action = AgentActionSummaryFact(kind: .show, succeeded: true, reminderIDs: ["important-id"])

        let summary = service.update(existing: nil, messages: input, actionFacts: [action])!
        let contentCount = [summary.currentGoal, summary.taskScope].compactMap { $0 }.joined().count
            + summary.confirmedConstraints.joined().count
            + summary.pendingQuestions.joined().count
            + summary.relatedReminderIDs.joined().count

        XCTAssertLessThanOrEqual(contentCount, AgentSessionSummaryService.maximumSummaryCharacterCount)
        XCTAssertEqual(summary.relatedReminderIDs, ["important-id"])
    }

    private func messages(count: Int) -> [AgentSummaryMessage] {
        (0..<count).map { index in
            AgentSummaryMessage(id: UUID(), role: index.isMultiple(of: 2) ? .user : .assistant)
        }
    }
}
