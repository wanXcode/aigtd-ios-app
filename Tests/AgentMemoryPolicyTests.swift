import Foundation
import XCTest
@testable import AIGTDReminders

final class AgentMemoryPolicyTests: XCTestCase {
    private let policy = AgentMemoryPolicy()

    func testAcceptsEveryPRDWhitelistCategoryWithExplicitLongTermMeaning() {
        let cases: [(String, UserMemoryCategory)] = [
            ("以后叫我小万", .preferredName),
            ("记住我的默认时区是 Asia/Shanghai", .timeZone),
            ("以后新任务默认上午九点", .defaultTaskTime),
            ("记住我的默认清单是工作", .defaultList),
            ("以后工作日是周一到周五上午九点到下午六点", .workingSchedule),
            ("记住所有删除任务都要先确认", .transactionRule)
        ]

        for (message, category) in cases {
            guard case let .candidate(candidate) = policy.evaluate(message: message) else {
                return XCTFail("Expected candidate for: \(message)")
            }
            XCTAssertEqual(candidate.category, category)
            XCTAssertFalse(candidate.value.isEmpty)
            XCTAssertFalse(candidate.readableDescription.isEmpty)
        }
    }

    func testOrdinaryPreferenceWithoutLongTermMeaningIsNotCandidate() {
        XCTAssertEqual(policy.evaluate(message: "我喜欢上午处理任务"), .notLongTerm)
    }

    func testExplicitButNonWhitelistContentIsRejected() {
        XCTAssertEqual(
            policy.evaluate(message: "记住我最喜欢的电影是花样年华"),
            .rejected(.outsideWhitelist)
        )
    }

    func testRejectsSensitiveCategoriesEvenWhenUserSaysRemember() {
        let cases: [(String, AgentMemoryRejectionReason)] = [
            ("记住我的手机号是 13800138000", .sensitiveContact),
            ("以后寄到我的家庭地址上海市某路", .sensitiveAddress),
            ("记住我有糖尿病", .sensitiveHealth),
            ("记住我的账户余额是 5000 元", .sensitiveFinancial),
            ("记住 sk-secret", .credential)
        ]

        for (message, reason) in cases {
            XCTAssertEqual(policy.evaluate(message: message), .rejected(reason))
        }
    }

    func testRejectsOneTimeTaskAndOrdinaryEmotion() {
        XCTAssertEqual(
            policy.evaluate(message: "记住明天提醒我交报告"),
            .rejected(.oneTimeTask)
        )
        XCTAssertEqual(
            policy.evaluate(message: "记住我今天心情很难过"),
            .rejected(.ordinaryEmotion)
        )
    }

    func testCandidateIsReadableAndCarriesSourceWithoutCreatingMemoryItem() {
        let sourceID = UUID()
        guard case let .candidate(candidate) = policy.evaluate(
            message: "请记住我的默认清单是项目",
            sourceMessageID: sourceID
        ) else {
            return XCTFail("Expected candidate")
        }

        XCTAssertEqual(candidate.sourceMessageID, sourceID)
        XCTAssertEqual(candidate.value, "我的默认清单是项目")
        XCTAssertEqual(candidate.readableDescription, "默认清单：我的默认清单是项目")
    }
}
