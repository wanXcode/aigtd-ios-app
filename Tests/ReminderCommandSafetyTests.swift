import XCTest
@testable import AIGTDReminders

final class ReminderCommandSafetyTests: XCTestCase {
    func testNaturalTitleEndingInDateIsPreserved() {
        let title = ReminderCommandSanitizer.title(
            modelTitle: "验证卡片日期",
            sourceText: "7 月 19 日提醒我验证卡片日期"
        )

        XCTAssertEqual(title, "验证卡片日期")
    }

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

    func testStrictDeletePrefersOneExactTitleOverContainingTitles() throws {
        let candidates = [
            ReminderLookupCandidate(identifier: "exact", normalizedTitle: "重复测试", displayTitle: "重复测试（明天下午）", dueDate: nil),
            ReminderLookupCandidate(identifier: "malformed", normalizedTitle: "标题是“重复测试”时间是", displayTitle: "标题是“重复测试”时间是（后天下午）", dueDate: nil)
        ]

        let identifier = try ReminderCandidateResolver.resolveIdentifier(
            targetText: "重复测试",
            candidates: candidates,
            requireUniquePlausibleMatch: true
        )

        XCTAssertEqual(identifier, "exact")
    }

    func testStrictDeleteStillRejectsMultipleExactTitles() {
        let candidates = [
            ReminderLookupCandidate(identifier: "first", normalizedTitle: "重复测试", displayTitle: "重复测试（明天）", dueDate: nil),
            ReminderLookupCandidate(identifier: "second", normalizedTitle: "重复测试", displayTitle: "重复测试（后天）", dueDate: nil)
        ]

        XCTAssertThrowsError(
            try ReminderCandidateResolver.resolveIdentifier(
                targetText: "重复测试",
                candidates: candidates,
                requireUniquePlausibleMatch: true
            )
        )
    }

    func testNonDestructiveLookupCanStillPreferUniqueExactMatch() throws {
        let candidates = [
            ReminderLookupCandidate(identifier: "exact", normalizedTitle: "重复测试", displayTitle: "重复测试", dueDate: nil),
            ReminderLookupCandidate(identifier: "related", normalizedTitle: "准备重复测试资料", displayTitle: "准备重复测试资料", dueDate: nil)
        ]

        let identifier = try ReminderCandidateResolver.resolveIdentifier(
            targetText: "重复测试",
            candidates: candidates,
            requireUniquePlausibleMatch: false
        )

        XCTAssertEqual(identifier, "exact")
    }

    func testDeleteDueDateSelectsOneOfDuplicateTitles() throws {
        let calendar = Calendar(identifier: .gregorian)
        let first = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 15))!
        let second = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 15))!
        let candidates = [
            ReminderLookupCandidate(identifier: "tomorrow", normalizedTitle: "重复测试", displayTitle: "重复测试（7月15日 15:00）", dueDate: first),
            ReminderLookupCandidate(identifier: "day-after", normalizedTitle: "重复测试", displayTitle: "重复测试（7月16日 15:00）", dueDate: second)
        ]

        let identifier = try ReminderCandidateResolver.resolveIdentifier(
            targetText: "重复测试",
            candidates: candidates,
            requireUniquePlausibleMatch: true,
            targetDueDate: first,
            calendar: calendar
        )

        XCTAssertEqual(identifier, "tomorrow")
    }

    func testDeleteDueDateDoesNotFallBackWhenTimeDoesNotMatch() throws {
        let calendar = Calendar(identifier: .gregorian)
        let existing = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 15))!
        let requested = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 15))!
        let candidates = [
            ReminderLookupCandidate(identifier: "other-day", normalizedTitle: "重复测试", displayTitle: "重复测试（7月16日 15:00）", dueDate: existing)
        ]

        let identifier = try ReminderCandidateResolver.resolveIdentifier(
            targetText: "“重复测试”",
            candidates: candidates,
            requireUniquePlausibleMatch: true,
            targetDueDate: requested,
            calendar: calendar
        )

        XCTAssertNil(identifier)
    }
}
