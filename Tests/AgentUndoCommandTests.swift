import XCTest
@testable import AIGTDReminders

final class AgentUndoCommandTests: XCTestCase {
    private let parser = AgentUndoCommandParser()

    func testRecognizesExplicitUndoControlPhrases() {
        for phrase in ["撤销", "撤销刚才的操作。", " 把刚才的修改撤销 ", "恢复到修改前！"] {
            XCTAssertTrue(parser.matches(phrase), phrase)
        }
    }

    func testDoesNotTreatNewTaskRequestsAsUndoControl() {
        for phrase in ["撤销明天的会议", "把项目改回昨天", "撤销删除任务前先问我", "为什么不能撤销"] {
            XCTAssertFalse(parser.matches(phrase), phrase)
        }
    }

    func testEmptyInputDoesNotMatch() {
        XCTAssertFalse(parser.matches(" \n "))
    }
}
