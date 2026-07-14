import Foundation

enum AgentReferenceEvent: Equatable, Sendable {
    case created(reminderID: String, sourceMessageID: UUID? = nil)
    case modified(reminderID: String, sourceMessageID: UUID? = nil)
    case moved(reminderID: String, sourceMessageID: UUID? = nil)
    case completed(reminderID: String, sourceMessageID: UUID? = nil)
    case shown(reminderIDs: [String], sourceMessageID: UUID? = nil)
    case selected(reminderID: String, sourceMessageID: UUID? = nil)
    case deleted(reminderID: String)
}

struct AgentReferenceRecorder: Sendable {
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { .now }) {
        self.now = now
    }

    func recording(
        _ event: AgentReferenceEvent,
        in references: ReferenceContext
    ) -> ReferenceContext {
        var updated = references
        let timestamp = now()

        switch event {
        case let .created(reminderID, sourceMessageID):
            updated.recentlyCreated = makeReference(reminderID, sourceMessageID, timestamp)
        case let .modified(reminderID, sourceMessageID):
            updated.recentlyModified = makeReference(reminderID, sourceMessageID, timestamp)
        case let .moved(reminderID, sourceMessageID):
            updated.recentlyMoved = makeReference(reminderID, sourceMessageID, timestamp)
        case let .completed(reminderID, sourceMessageID):
            updated.recentlyCompleted = makeReference(reminderID, sourceMessageID, timestamp)
        case let .shown(reminderIDs, sourceMessageID):
            updated.recentlyShown = reminderIDs.map {
                makeReference($0, sourceMessageID, timestamp)
            }
        case let .selected(reminderID, sourceMessageID):
            updated.explicitlySelected = makeReference(reminderID, sourceMessageID, timestamp)
        case let .deleted(reminderID):
            invalidate(reminderID, in: &updated, at: timestamp)
        }

        return updated
    }

    private func makeReference(
        _ reminderID: String,
        _ sourceMessageID: UUID?,
        _ recordedAt: Date
    ) -> ReminderReference {
        ReminderReference(
            reminderID: reminderID,
            sourceMessageID: sourceMessageID,
            recordedAt: recordedAt
        )
    }

    private func invalidate(
        _ reminderID: String,
        in references: inout ReferenceContext,
        at timestamp: Date
    ) {
        markStale(&references.recentlyCreated, matching: reminderID, at: timestamp)
        markStale(&references.recentlyModified, matching: reminderID, at: timestamp)
        markStale(&references.recentlyMoved, matching: reminderID, at: timestamp)
        markStale(&references.recentlyCompleted, matching: reminderID, at: timestamp)
        markStale(&references.explicitlySelected, matching: reminderID, at: timestamp)

        for index in references.recentlyShown.indices
        where references.recentlyShown[index].reminderID == reminderID {
            references.recentlyShown[index].isStale = true
            references.recentlyShown[index].staleSince = timestamp
        }
    }

    private func markStale(
        _ reference: inout ReminderReference?,
        matching reminderID: String,
        at timestamp: Date
    ) {
        guard reference?.reminderID == reminderID else { return }
        reference?.isStale = true
        reference?.staleSince = timestamp
    }
}
