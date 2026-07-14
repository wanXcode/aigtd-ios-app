import XCTest
@testable import AIGTDReminders

final class ReminderCommandSafetyTests: XCTestCase {
    func testExplicitQuotedTitleWinsOverMalformedModelTitle() {
        let title = ReminderCommandSanitizer.title(
            modelTitle: "标题是“重复测试”时间是",
            sourceText: "新建任务，标题是“重复测试”，时间是后天下午 3 点"
        )

        XCTAssertEqual(title, "重复测试")
    }

    func testExplicitColonTitleStopsBeforeTimeField() {
        let title = ReminderCommandSanitizer.title(
            modelTitle: "标题：季度复盘，时间：明天下午 3 点",
            sourceText: "新建任务，标题：季度复盘，时间：明天下午 3 点"
        )

        XCTAssertEqual(title, "季度复盘")
    }

    func testStrictDeleteTreatsExactAndContainingTitlesAsAmbiguous() {
        let candidates = [
            ReminderLookupCandidate(identifier: "exact", normalizedTitle: "重复测试", displayTitle: "重复测试（明天下午）"),
            ReminderLookupCandidate(identifier: "malformed", normalizedTitle: "标题是“重复测试”时间是", displayTitle: "标题是“重复测试”时间是（后天下午）")
        ]

        XCTAssertThrowsError(
            try ReminderCandidateResolver.resolveIdentifier(
                targetText: "重复测试",
                candidates: candidates,
                requireUniquePlausibleMatch: true
            )
        ) { error in
            guard case ReminderStoreError.reminderAmbiguous = error else {
                return XCTFail("Expected reminderAmbiguous, got \(error)")
            }
        }
    }

    func testNonDestructiveLookupCanStillPreferUniqueExactMatch() throws {
        let candidates = [
            ReminderLookupCandidate(identifier: "exact", normalizedTitle: "重复测试", displayTitle: "重复测试"),
            ReminderLookupCandidate(identifier: "related", normalizedTitle: "准备重复测试资料", displayTitle: "准备重复测试资料")
        ]

        let identifier = try ReminderCandidateResolver.resolveIdentifier(
            targetText: "重复测试",
            candidates: candidates,
            requireUniquePlausibleMatch: false
        )

        XCTAssertEqual(identifier, "exact")
    }
}
