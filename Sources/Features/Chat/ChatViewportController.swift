import Foundation
import Observation

enum ChatViewportGeometryPolicy {
    static let nearBottomTolerance: CGFloat = 72

    static func isNearBottom(
        contentHeight: CGFloat,
        visibleBottom: CGFloat,
        bottomInset: CGFloat
    ) -> Bool {
        remainingDistance(
            contentHeight: contentHeight,
            visibleBottom: visibleBottom,
            bottomInset: bottomInset
        ) <= nearBottomTolerance
    }

    static func remainingDistance(
        contentHeight: CGFloat,
        visibleBottom: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        let totalScrollableBottom = contentHeight + max(0, bottomInset)
        return max(0, totalScrollableBottom - visibleBottom)
    }
}

@MainActor
@Observable
final class ChatViewportController {
    enum Mode: Equatable {
        case followingLatest
        case readingHistory
    }

    enum ContentUpdate: Equatable {
        case messageInserted
        case streamingText
        case cardState
    }

    enum ScrollBehavior: Equatable {
        case immediate
        case animated
    }

    struct ScrollRequest: Equatable {
        let sequence: Int
        let behavior: ScrollBehavior
    }

    private(set) var mode: Mode = .followingLatest
    private(set) var isNearBottom = true
    private(set) var scrollRequest = ScrollRequest(sequence: 0, behavior: .immediate)

    var showsReturnToLatest: Bool {
        mode == .readingHistory && isNearBottom == false
    }

    func viewportDidChange(isNearBottom: Bool, isUserInteracting: Bool) {
        self.isNearBottom = isNearBottom
        if isNearBottom {
            mode = .followingLatest
        } else if isUserInteracting {
            mode = .readingHistory
        }
    }

    func userInteractionDidEnd(isNearBottom: Bool) {
        self.isNearBottom = isNearBottom
        mode = isNearBottom ? .followingLatest : .readingHistory
    }

    func contentDidChange(_ update: ContentUpdate) {
        guard mode == .followingLatest else { return }

        switch update {
        case .messageInserted:
            requestScroll(.animated)
        case .streamingText, .cardState:
            requestScroll(.immediate)
        }
    }

    func composerFocused() {
        guard mode == .followingLatest else { return }
        requestScroll(.immediate)
    }

    func keyboardDidSettle() {
        guard mode == .followingLatest else { return }
        requestScroll(.immediate)
    }

    func chatBecameVisible() {
        guard mode == .followingLatest else { return }
        requestScroll(.immediate)
    }

    func positionInitialTimelineAtLatest() {
        mode = .followingLatest
        isNearBottom = true
        requestScroll(.immediate)
    }

    func prepareForUserSend() {
        mode = .followingLatest
        isNearBottom = true
    }

    func returnToLatest() {
        mode = .followingLatest
        isNearBottom = true
        requestScroll(.animated)
    }

    private func requestScroll(_ behavior: ScrollBehavior) {
        scrollRequest = ScrollRequest(
            sequence: scrollRequest.sequence + 1,
            behavior: behavior
        )
    }
}

@MainActor
@Observable
final class ChatStreamingTextBuffer {
    private(set) var textByMessageID: [UUID: String] = [:]
    private(set) var revision = 0

    @ObservationIgnored private var pendingTextByMessageID: [UUID: String] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    func enqueue(_ text: String, for messageID: UUID) {
        pendingTextByMessageID[messageID] = text
        guard flushTask == nil else { return }

        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            guard Task.isCancelled == false else { return }
            self?.flushPendingText()
        }
    }

    func text(for messageID: UUID) -> String? {
        textByMessageID[messageID]
    }

    func removeText(for messageID: UUID) {
        pendingTextByMessageID.removeValue(forKey: messageID)
        if textByMessageID.removeValue(forKey: messageID) != nil {
            revision += 1
        }
        if pendingTextByMessageID.isEmpty {
            flushTask?.cancel()
            flushTask = nil
        }
    }

    private func flushPendingText() {
        flushTask = nil
        guard pendingTextByMessageID.isEmpty == false else { return }
        for (messageID, text) in pendingTextByMessageID {
            textByMessageID[messageID] = text
        }
        pendingTextByMessageID.removeAll(keepingCapacity: true)
        revision += 1
    }
}
