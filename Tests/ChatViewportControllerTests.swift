import XCTest
@testable import AIGTDReminders

@MainActor
final class ChatViewportControllerTests: XCTestCase {
    func testStartsFollowingLatest() {
        let controller = ChatViewportController()

        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertTrue(controller.isNearBottom)
        XCTAssertFalse(controller.showsReturnToLatest)
    }

    func testUserScrollingAwayEntersReadingHistory() {
        let controller = ChatViewportController()

        controller.viewportDidChange(isNearBottom: false, isUserInteracting: true)
        controller.userInteractionDidEnd(isNearBottom: false)

        XCTAssertEqual(controller.mode, .readingHistory)
        XCTAssertTrue(controller.showsReturnToLatest)
    }

    func testContentAndFocusDoNotPullUserOutOfHistory() {
        let controller = ChatViewportController()
        controller.viewportDidChange(isNearBottom: false, isUserInteracting: true)
        controller.userInteractionDidEnd(isNearBottom: false)
        let originalRequest = controller.scrollRequest

        controller.contentDidChange(.messageInserted)
        controller.contentDidChange(.streamingText)
        controller.contentDidChange(.cardState)
        controller.composerFocused()

        XCTAssertEqual(controller.mode, .readingHistory)
        XCTAssertEqual(controller.scrollRequest, originalRequest)
    }

    func testPassiveGeometryChangeAtBottomExitsHistoryMode() {
        let controller = ChatViewportController()
        controller.viewportDidChange(isNearBottom: false, isUserInteracting: true)
        controller.userInteractionDidEnd(isNearBottom: false)

        controller.viewportDidChange(isNearBottom: true, isUserInteracting: false)

        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertFalse(controller.showsReturnToLatest)
    }

    func testPassiveGeometryChangeAwayFromBottomDoesNotEnterHistoryMode() {
        let controller = ChatViewportController()

        controller.viewportDidChange(isNearBottom: false, isUserInteracting: false)

        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertFalse(controller.showsReturnToLatest)
    }

    func testStreamingAndCardUpdatesFollowWithoutAnimation() {
        let controller = ChatViewportController()

        controller.contentDidChange(.streamingText)
        let streamingRequest = controller.scrollRequest
        controller.contentDidChange(.cardState)

        XCTAssertEqual(streamingRequest.behavior, .immediate)
        XCTAssertEqual(controller.scrollRequest.behavior, .immediate)
        XCTAssertGreaterThan(controller.scrollRequest.sequence, streamingRequest.sequence)
    }

    func testNewMessageUsesSingleAnimatedRequest() {
        let controller = ChatViewportController()
        let originalSequence = controller.scrollRequest.sequence

        controller.contentDidChange(.messageInserted)

        XCTAssertEqual(controller.scrollRequest.sequence, originalSequence + 1)
        XCTAssertEqual(controller.scrollRequest.behavior, .animated)
    }

    func testReturningToBottomResumesFollowing() {
        let controller = ChatViewportController()
        controller.viewportDidChange(isNearBottom: false, isUserInteracting: true)
        controller.userInteractionDidEnd(isNearBottom: false)

        controller.viewportDidChange(isNearBottom: true, isUserInteracting: true)
        controller.userInteractionDidEnd(isNearBottom: true)

        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertFalse(controller.showsReturnToLatest)
    }

    func testUserSendPreparesFollowingAndInsertedMessageScrollsOnce() {
        let controller = ChatViewportController()
        controller.viewportDidChange(isNearBottom: false, isUserInteracting: true)
        controller.userInteractionDidEnd(isNearBottom: false)
        let originalSequence = controller.scrollRequest.sequence

        controller.prepareForUserSend()

        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertEqual(controller.scrollRequest.sequence, originalSequence)

        controller.contentDidChange(.messageInserted)

        XCTAssertEqual(controller.scrollRequest.behavior, .animated)
        XCTAssertEqual(controller.scrollRequest.sequence, originalSequence + 1)
    }

    func testReturnButtonExplicitlyFollowsLatest() {
        let controller = ChatViewportController()
        controller.viewportDidChange(isNearBottom: false, isUserInteracting: true)
        controller.userInteractionDidEnd(isNearBottom: false)

        controller.returnToLatest()

        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertEqual(controller.scrollRequest.behavior, .animated)
    }

    func testInitialTimelinePositionAlwaysRequestsLatestImmediately() {
        let controller = ChatViewportController()
        controller.viewportDidChange(isNearBottom: false, isUserInteracting: true)
        controller.userInteractionDidEnd(isNearBottom: false)
        let originalSequence = controller.scrollRequest.sequence

        controller.positionInitialTimelineAtLatest()

        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertTrue(controller.isNearBottom)
        XCTAssertEqual(controller.scrollRequest.sequence, originalSequence + 1)
        XCTAssertEqual(controller.scrollRequest.behavior, .immediate)
    }
}
