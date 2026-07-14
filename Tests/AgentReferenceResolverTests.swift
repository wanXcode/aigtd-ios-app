import Foundation
import XCTest
@testable import AIGTDReminders

final class AgentReferenceResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_100_000_000)
    private let resolver = AgentReferenceResolver()

    func testDuplicateTitlesRemainAmbiguousForDestructiveSafety() {
        let reminders = [
            reminder("first", title: "开会", listTitle: "工作"),
            reminder("second", title: "开会", listTitle: "个人")
        ]

        let result = resolver.resolve(
            AgentReferenceResolutionRequest(target: "开会"),
            references: selected("first"),
            reminders: reminders
        )

        guard case let .ambiguous(candidates) = result else {
            return XCTFail("Expected duplicate titles to require clarification")
        }
        XCTAssertEqual(candidates.map(\.id), ["first", "second"])
    }

    func testExplicitOrdinalUsesOneBasedShownOrder() {
        let reminders = [reminder("first"), reminder("second"), reminder("third")]
        let references = shown(["third", "first", "second"])

        let result = resolver.resolve(
            AgentReferenceResolutionRequest(ordinal: 2),
            references: references,
            reminders: reminders
        )

        XCTAssertEqual(result, .resolved(reminders[0]))
    }

    func testOrdinalOutsideShownRangeIsNotFound() {
        let result = resolver.resolve(
            AgentReferenceResolutionRequest(ordinal: 3),
            references: shown(["first", "second"]),
            reminders: [reminder("first"), reminder("second")]
        )

        XCTAssertEqual(result, .notFound)
    }

    func testMissingExplicitIDIsStaleAndDoesNotFallBackToTitle() {
        let existing = reminder("existing", title: "开会")
        let result = resolver.resolve(
            AgentReferenceResolutionRequest(targetID: "deleted", target: "开会"),
            references: selected("existing"),
            reminders: [existing]
        )

        XCTAssertEqual(result, .staleReference)
    }

    func testExplicitIDMustMatchExplicitTitle() {
        let first = reminder("first", title: "开会")
        let second = reminder("second", title: "写周报")

        let result = resolver.resolve(
            AgentReferenceResolutionRequest(targetID: "second", target: "开会"),
            references: .empty,
            reminders: [first, second]
        )

        XCTAssertEqual(result, .notFound)
    }

    func testExplicitIDMustMatchOrdinalReference() {
        let first = reminder("first")
        let second = reminder("second")

        let result = resolver.resolve(
            AgentReferenceResolutionRequest(targetID: "second", ordinal: 1),
            references: shown(["first", "second"]),
            reminders: [first, second]
        )

        XCTAssertEqual(result, .notFound)
    }

    func testExplicitIDMustMatchRequestedReferenceSource() {
        let created = reminder("created")
        let other = reminder("other")
        var references = ReferenceContext.empty
        references.recentlyCreated = ReminderReference(reminderID: "created", recordedAt: now)

        let result = resolver.resolve(
            AgentReferenceResolutionRequest(targetID: "other", referenceSource: .recentlyCreated),
            references: references,
            reminders: [created, other]
        )

        XCTAssertEqual(result, .notFound)
    }

    func testExplicitTitleIsNotOverriddenByRecentReference() {
        let recent = reminder("recent", title: "写周报")
        let requested = reminder("requested", title: "购买牛奶")

        let result = resolver.resolve(
            AgentReferenceResolutionRequest(target: "购买牛奶", referenceSource: .selected),
            references: selected("recent"),
            reminders: [recent, requested]
        )

        XCTAssertEqual(result, .resolved(requested))
    }

    func testTitleDateAndListConditionsAreMatchedTogether() {
        let targetDate = now.addingTimeInterval(24 * 60 * 60)
        let reminders = [
            reminder("today-work", title: "开会", listTitle: "工作", dueDate: now),
            reminder("tomorrow-personal", title: "开会", listTitle: "个人", dueDate: targetDate),
            reminder("tomorrow-work", title: "开会", listTitle: "工作", dueDate: targetDate)
        ]

        let result = resolver.resolve(
            AgentReferenceResolutionRequest(target: "开会", dueDate: targetDate, listTitle: "工作"),
            references: .empty,
            reminders: reminders,
            calendar: utcCalendar()
        )

        XCTAssertEqual(result, .resolved(reminders[2]))
    }

    func testRecorderPreservesShownOrderAndOrdinalResolution() {
        let timestamp = now
        let recorder = AgentReferenceRecorder(now: { timestamp })
        let references = recorder.recording(
            .shown(reminderIDs: ["third", "first", "second"]),
            in: .empty
        )
        let reminders = [reminder("first"), reminder("second"), reminder("third")]

        XCTAssertEqual(references.recentlyShown.map(\.reminderID), ["third", "first", "second"])
        XCTAssertEqual(
            resolver.resolve(
                AgentReferenceResolutionRequest(ordinal: 1),
                references: references,
                reminders: reminders
            ),
            .resolved(reminders[2])
        )
    }

    func testDeleteInvalidatesEveryMatchingReference() {
        let timestamp = now
        let recorder = AgentReferenceRecorder(now: { timestamp })
        var references = ReferenceContext.empty
        references = recorder.recording(.created(reminderID: "deleted"), in: references)
        references = recorder.recording(.modified(reminderID: "deleted"), in: references)
        references = recorder.recording(.moved(reminderID: "deleted"), in: references)
        references = recorder.recording(.completed(reminderID: "deleted"), in: references)
        references = recorder.recording(.shown(reminderIDs: ["kept", "deleted"]), in: references)
        references = recorder.recording(.selected(reminderID: "deleted"), in: references)

        references = recorder.recording(.deleted(reminderID: "deleted"), in: references)

        let deletedReferences = references.allReferences.filter { $0.reminderID == "deleted" }
        XCTAssertEqual(deletedReferences.count, 6)
        XCTAssertTrue(deletedReferences.allSatisfy(\.isStale))
        XCTAssertTrue(deletedReferences.allSatisfy { $0.staleSince == now })
        XCTAssertFalse(references.recentlyShown[0].isStale)
        XCTAssertEqual(
            resolver.resolve(
                AgentReferenceResolutionRequest(target: "它"),
                references: references,
                reminders: [reminder("kept"), reminder("replacement", title: "deleted")]
            ),
            .staleReference
        )
    }

    func testRecorderWritesEachActionSlot() {
        let timestamp = now
        let recorder = AgentReferenceRecorder(now: { timestamp })
        var references = ReferenceContext.empty
        references = recorder.recording(.created(reminderID: "created"), in: references)
        references = recorder.recording(.modified(reminderID: "modified"), in: references)
        references = recorder.recording(.moved(reminderID: "moved"), in: references)
        references = recorder.recording(.completed(reminderID: "completed"), in: references)
        references = recorder.recording(.selected(reminderID: "selected"), in: references)

        XCTAssertEqual(references.recentlyCreated?.reminderID, "created")
        XCTAssertEqual(references.recentlyModified?.reminderID, "modified")
        XCTAssertEqual(references.recentlyMoved?.reminderID, "moved")
        XCTAssertEqual(references.recentlyCompleted?.reminderID, "completed")
        XCTAssertEqual(references.explicitlySelected?.reminderID, "selected")
    }

    private func reminder(
        _ id: String,
        title: String? = nil,
        listTitle: String = "默认",
        dueDate: Date? = nil
    ) -> ReminderContextItem {
        ReminderContextItem(
            id: id,
            title: title ?? id,
            listID: "list-\(listTitle)",
            listTitle: listTitle,
            dueDate: dueDate,
            isCompleted: false,
            lastModifiedAt: now,
            relevanceReasons: [],
            notesPreview: nil
        )
    }

    private func selected(_ id: String) -> ReferenceContext {
        var references = ReferenceContext.empty
        references.explicitlySelected = ReminderReference(reminderID: id, recordedAt: now)
        return references
    }

    private func shown(_ ids: [String]) -> ReferenceContext {
        var references = ReferenceContext.empty
        references.recentlyShown = ids.map { ReminderReference(reminderID: $0, recordedAt: now) }
        return references
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
