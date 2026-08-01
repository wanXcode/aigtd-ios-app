import XCTest
@testable import AIGTDReminders

final class AgentPendingInteractionCommandTests: XCTestCase {
    private let parser = AgentPendingInteractionCommandParser()

    func testRecognizesExplicitConfirmationPhrases() {
        let phrases = [
            "执行吧",
            "确认执行",
            "就按这个来。",
            " 按这个方案执行 ",
            "执行这个计划！"
        ]

        for phrase in phrases {
            XCTAssertEqual(parser.parse(phrase), .confirm, phrase)
        }
    }

    func testRecognizesExplicitCancellationPhrasesBeforeConfirmation() {
        let phrases = [
            "算了",
            "算了，不执行了",
            "算了，不要执行了。",
            "取消这个方案",
            "不要执行",
            "先不要执行了。",
            "先别执行"
        ]

        for phrase in phrases {
            XCTAssertEqual(parser.parse(phrase), .cancel, phrase)
        }
    }

    func testDoesNotTreatTaskRequestsAsPlanControl() {
        let phrases = [
            "执行方案前先把第二条改到周五",
            "你可以执行删除任务吗",
            "把会议改到下午五点",
            "第二条不要改",
            "为什么没有执行"
        ]

        for phrase in phrases {
            XCTAssertEqual(parser.parse(phrase), .none, phrase)
        }
    }

    func testEmptyInputDoesNotMatch() {
        XCTAssertEqual(parser.parse(" \n "), .none)
    }
}
