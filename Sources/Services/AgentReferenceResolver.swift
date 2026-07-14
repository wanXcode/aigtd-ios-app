import Foundation

enum AgentReferenceSource: String, Codable, CaseIterable, Sendable {
    case selected
    case recentlyCreated = "recently_created"
    case recentlyModified = "recently_modified"
    case recentlyMoved = "recently_moved"
    case recentlyCompleted = "recently_completed"
    case recentlyShown = "recently_shown"
    case recent
}

struct AgentReferenceResolutionRequest: Equatable, Sendable {
    let targetID: String?
    let target: String?
    let ordinal: Int?
    let referenceSource: AgentReferenceSource?
    let dueDate: Date?
    let listID: String?
    let listTitle: String?

    init(
        targetID: String? = nil,
        target: String? = nil,
        ordinal: Int? = nil,
        referenceSource: AgentReferenceSource? = nil,
        dueDate: Date? = nil,
        listID: String? = nil,
        listTitle: String? = nil
    ) {
        self.targetID = targetID
        self.target = target
        self.ordinal = ordinal
        self.referenceSource = referenceSource
        self.dueDate = dueDate
        self.listID = listID
        self.listTitle = listTitle
    }
}

enum AgentReferenceResolution: Equatable, Sendable {
    case resolved(ReminderContextItem)
    case ambiguous([ReminderContextItem])
    case notFound
    case staleReference
}

struct AgentReferenceResolver: Sendable {
    func resolve(
        _ request: AgentReferenceResolutionRequest,
        references: ReferenceContext,
        reminders: [ReminderContextItem],
        calendar: Calendar = .current
    ) -> AgentReferenceResolution {
        if let targetID = nonempty(request.targetID) {
            guard let reminder = reminders.first(where: { $0.id == targetID }) else {
                return .staleReference
            }
            guard matchesExplicitConstraints(
                reminder,
                request: request,
                references: references,
                calendar: calendar
            ) else {
                return .notFound
            }
            return .resolved(reminder)
        }

        if let ordinal = request.ordinal {
            guard ordinal > 0, ordinal <= references.recentlyShown.count else { return .notFound }
            return resolve(
                reference: references.recentlyShown[ordinal - 1],
                reminders: reminders
            )
        }

        let target = nonempty(request.target)
        if target == nil || target.map(isPronoun) == true {
            guard let reference = contextualReference(
                source: request.referenceSource,
                references: references
            ) else {
                return .notFound
            }
            return resolve(reference: reference, reminders: reminders)
        }

        guard let target else { return .notFound }
        let candidates = reminders.filter { reminder in
            matchesTitle(reminder.title, target: target) &&
                matchesDate(reminder.dueDate, requestedDate: request.dueDate, calendar: calendar) &&
                matchesList(reminder, listID: request.listID, listTitle: request.listTitle)
        }

        switch candidates.count {
        case 0: return .notFound
        case 1: return .resolved(candidates[0])
        default: return .ambiguous(candidates)
        }
    }

    private func resolveStableID(
        _ identifier: String,
        reminders: [ReminderContextItem]
    ) -> AgentReferenceResolution {
        guard let reminder = reminders.first(where: { $0.id == identifier }) else {
            return .staleReference
        }
        return .resolved(reminder)
    }

    private func matchesExplicitConstraints(
        _ reminder: ReminderContextItem,
        request: AgentReferenceResolutionRequest,
        references: ReferenceContext,
        calendar: Calendar
    ) -> Bool {
        if let target = nonempty(request.target), !isPronoun(target),
           !matchesTitle(reminder.title, target: target) {
            return false
        }
        guard matchesDate(reminder.dueDate, requestedDate: request.dueDate, calendar: calendar),
              matchesList(reminder, listID: request.listID, listTitle: request.listTitle) else {
            return false
        }
        if let ordinal = request.ordinal {
            guard ordinal > 0, ordinal <= references.recentlyShown.count,
                  references.recentlyShown[ordinal - 1].reminderID == reminder.id,
                  references.recentlyShown[ordinal - 1].isStale == false else {
                return false
            }
        }
        if let source = request.referenceSource {
            guard let reference = contextualReference(source: source, references: references),
                  reference.reminderID == reminder.id,
                  reference.isStale == false else { return false }
        }
        return true
    }

    private func resolve(
        reference: ReminderReference,
        reminders: [ReminderContextItem]
    ) -> AgentReferenceResolution {
        guard reference.isStale == false else { return .staleReference }
        return resolveStableID(reference.reminderID, reminders: reminders)
    }

    private func contextualReference(
        source: AgentReferenceSource?,
        references: ReferenceContext
    ) -> ReminderReference? {
        switch source {
        case .selected:
            return references.explicitlySelected
        case .recentlyCreated:
            return references.recentlyCreated
        case .recentlyModified:
            return references.recentlyModified
        case .recentlyMoved:
            return references.recentlyMoved
        case .recentlyCompleted:
            return references.recentlyCompleted
        case .recentlyShown:
            return references.recentlyShown.first
        case .recent, nil:
            return references.explicitlySelected ?? mostRecentReference(in: references)
        }
    }

    private func mostRecentReference(in references: ReferenceContext) -> ReminderReference? {
        let recent = [
            references.recentlyCreated,
            references.recentlyModified,
            references.recentlyMoved,
            references.recentlyCompleted
        ].compactMap { $0 }
        return recent.max { $0.recordedAt < $1.recordedAt }
    }

    private func matchesTitle(_ title: String, target: String) -> Bool {
        let normalizedTitle = normalize(title)
        let normalizedTarget = normalize(target)
        return normalizedTitle.contains(normalizedTarget) || normalizedTarget.contains(normalizedTitle)
    }

    private func matchesDate(
        _ dueDate: Date?,
        requestedDate: Date?,
        calendar: Calendar
    ) -> Bool {
        guard let requestedDate else { return true }
        guard let dueDate else { return false }
        return calendar.isDate(dueDate, inSameDayAs: requestedDate)
    }

    private func matchesList(
        _ reminder: ReminderContextItem,
        listID: String?,
        listTitle: String?
    ) -> Bool {
        if let listID = nonempty(listID), reminder.listID != listID { return false }
        if let listTitle = nonempty(listTitle), normalize(reminder.listTitle) != normalize(listTitle) {
            return false
        }
        return true
    }

    private func isPronoun(_ value: String) -> Bool {
        let normalized = normalize(value)
        return [
            "它", "他", "她", "这条", "那条", "这一条", "那一条", "刚才那条",
            "刚刚那条", "上一条", "这个", "那个", "this", "that", "it"
        ].contains(normalized)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
