import Foundation

struct AgentContextDocumentsInput: Equatable, Sendable {
    let prompt: String?
    let memory: String?
    let solu: String?
    let operatingGuide: String?
    let fallback: AgentDocumentContext

    init(
        prompt: String?,
        memory: String?,
        solu: String?,
        operatingGuide: String?,
        fallback: AgentDocumentContext
    ) {
        self.prompt = prompt
        self.memory = memory
        self.solu = solu
        self.operatingGuide = operatingGuide
        self.fallback = fallback
    }
}

struct AgentContextBuildInput: Sendable {
    let generatedAt: Date
    let timeZoneIdentifier: String
    let session: SessionContext
    let recentTurns: [AgentConversationTurn]
    let sessionSummary: SessionSummary?
    let reminders: [ReminderContextItem]
    let references: ReferenceContext
    let preferences: [UserMemoryItem]
    let documents: AgentContextDocumentsInput
    let privacy: AgentContextPrivacySettings
    let reminderSnapshotIsStale: Bool

    init(
        generatedAt: Date = .now,
        timeZoneIdentifier: String,
        session: SessionContext,
        recentTurns: [AgentConversationTurn],
        sessionSummary: SessionSummary?,
        reminders: [ReminderContextItem],
        references: ReferenceContext,
        preferences: [UserMemoryItem],
        documents: AgentContextDocumentsInput,
        privacy: AgentContextPrivacySettings = .standard,
        reminderSnapshotIsStale: Bool = false
    ) {
        self.generatedAt = generatedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.session = session
        self.recentTurns = recentTurns
        self.sessionSummary = sessionSummary
        self.reminders = reminders
        self.references = references
        self.preferences = preferences
        self.documents = documents
        self.privacy = privacy
        self.reminderSnapshotIsStale = reminderSnapshotIsStale
    }
}

struct AgentContextBuilder: Sendable {
    static let maximumTurnCount = 8
    static let maximumTurnLength = 300
    static let maximumReminderTitleLength = 120
    static let maximumNotesPreviewLength = 200
    static let maximumDocumentLength = 4_000

    func build(from input: AgentContextBuildInput) -> AgentContextSnapshot {
        let turns = Array(input.recentTurns.suffix(Self.maximumTurnCount)).map { turn in
            AgentConversationTurn(
                role: turn.role,
                text: truncated(turn.text, limit: Self.maximumTurnLength)
            )
        }
        let reminders = builtReminders(from: input)

        return AgentContextSnapshot(
            generatedAt: input.generatedAt,
            timeZoneIdentifier: input.timeZoneIdentifier,
            session: input.session,
            recentTurns: turns,
            sessionSummary: input.sessionSummary,
            reminders: reminders,
            references: input.references,
            preferences: input.preferences,
            documents: builtDocuments(from: input.documents),
            privacy: ContextPrivacyDescriptor(
                includesNotes: input.privacy.includesNotes,
                includesCompletedReminders: input.privacy.includesCompletedReminders,
                maximumReminderCount: input.privacy.maximumReminderCount,
                reminderSnapshotIsStale: input.reminderSnapshotIsStale,
                originalReminderCount: input.reminders.count,
                includedReminderCount: reminders.count,
                truncatedReminderCount: input.reminders.count - reminders.count,
                truncatedTurnCount: max(0, input.recentTurns.count - Self.maximumTurnCount)
            )
        )
    }

    private func builtReminders(from input: AgentContextBuildInput) -> [ReminderContextItem] {
        let referenceReasons = reasonsByReminderID(from: input.references)
        let summaryIDs = Set(input.sessionSummary?.relatedReminderIDs ?? [])

        return input.reminders
            .filter { input.privacy.includesCompletedReminders || !$0.isCompleted }
            .map { item in
                let reasons = mergedReasons(
                    item.relevanceReasons,
                    referenceReasons[item.id] ?? []
                )
                return ReminderContextItem(
                    id: item.id,
                    title: truncated(item.title, limit: Self.maximumReminderTitleLength),
                    listID: item.listID,
                    listTitle: item.listTitle,
                    dueDate: item.dueDate,
                    isCompleted: item.isCompleted,
                    lastModifiedAt: item.lastModifiedAt,
                    relevanceReasons: reasons,
                    notesPreview: input.privacy.includesNotes
                        ? nonEmptyTruncated(item.notesPreview, limit: Self.maximumNotesPreviewLength)
                        : nil
                )
            }
            .sorted { lhs, rhs in
                reminderSortKey(lhs, references: input.references, summaryIDs: summaryIDs)
                    < reminderSortKey(rhs, references: input.references, summaryIDs: summaryIDs)
            }
            .prefix(input.privacy.maximumReminderCount)
            .map { $0 }
    }

    private func builtDocuments(from input: AgentContextDocumentsInput) -> AgentDocumentContext {
        AgentDocumentContext(
            prompt: document(input.prompt, fallback: input.fallback.prompt),
            memory: document(input.memory, fallback: input.fallback.memory),
            solu: document(input.solu, fallback: input.fallback.solu),
            operatingGuide: document(input.operatingGuide, fallback: input.fallback.operatingGuide)
        )
    }

    private func document(_ value: String?, fallback: String) -> String {
        let selected = value.flatMap { nonEmpty($0) } ?? fallback
        return truncated(selected, limit: Self.maximumDocumentLength)
    }

    private func reasonsByReminderID(
        from references: ReferenceContext
    ) -> [String: [ReminderContextRelevance]] {
        var reasons: [String: [ReminderContextRelevance]] = [:]

        func add(_ reference: ReminderReference?, reason: ReminderContextRelevance) {
            guard let reference, !reference.isStale else { return }
            reasons[reference.reminderID, default: []].append(reason)
        }

        add(references.explicitlySelected, reason: .explicitlySelected)
        add(references.recentlyCreated, reason: .recentlyCreated)
        add(references.recentlyModified, reason: .recentlyModified)
        add(references.recentlyMoved, reason: .recentlyMoved)
        add(references.recentlyCompleted, reason: .recentlyCompleted)
        for reference in references.recentlyShown where !reference.isStale {
            reasons[reference.reminderID, default: []].append(.recentlyShown)
        }
        return reasons
    }

    private func mergedReasons(
        _ groups: [ReminderContextRelevance]...
    ) -> [ReminderContextRelevance] {
        var seen = Set<ReminderContextRelevance>()
        return groups.flatMap { $0 }.filter { seen.insert($0).inserted }
    }

    private func reminderSortKey(
        _ item: ReminderContextItem,
        references: ReferenceContext,
        summaryIDs: Set<String>
    ) -> ReminderSortKey {
        let reasons = Set(item.relevanceReasons)
        let referenceRecency = references.allReferences
            .filter { !$0.isStale && $0.reminderID == item.id }
            .map(\.recordedAt)
            .max() ?? .distantPast

        let rank: Int
        if reasons.contains(.explicitlySelected) {
            rank = 0
        } else if reasons.contains(.recentlyCreated)
                    || reasons.contains(.recentlyModified)
                    || reasons.contains(.recentlyMoved)
                    || reasons.contains(.recentlyCompleted)
                    || reasons.contains(.recentlyShown)
                    || summaryIDs.contains(item.id) {
            rank = 1
        } else if reasons.contains(.dateScope) || reasons.contains(.listScope) {
            rank = 2
        } else if reasons.contains(.today) || reasons.contains(.overdue) {
            rank = 3
        } else {
            rank = 4
        }

        return ReminderSortKey(
            rank: rank,
            referenceTimestamp: -referenceRecency.timeIntervalSinceReferenceDate,
            recentlyShownIndex: references.recentlyShown.firstIndex {
                !$0.isStale && $0.reminderID == item.id
            } ?? .max,
            dueTimestamp: item.dueDate?.timeIntervalSinceReferenceDate ?? .greatestFiniteMagnitude,
            modifiedTimestamp: -(item.lastModifiedAt?.timeIntervalSinceReferenceDate ?? 0),
            normalizedTitle: item.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil),
            identifier: item.id
        )
    }

    private func nonEmpty(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private func nonEmptyTruncated(_ value: String?, limit: Int) -> String? {
        guard let value, let value = nonEmpty(value) else { return nil }
        return truncated(value, limit: limit)
    }

    private func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit))
    }
}

private struct ReminderSortKey: Comparable {
    let rank: Int
    let referenceTimestamp: TimeInterval
    let recentlyShownIndex: Int
    let dueTimestamp: TimeInterval
    let modifiedTimestamp: TimeInterval
    let normalizedTitle: String
    let identifier: String

    static func < (lhs: ReminderSortKey, rhs: ReminderSortKey) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        if lhs.referenceTimestamp != rhs.referenceTimestamp {
            return lhs.referenceTimestamp < rhs.referenceTimestamp
        }
        if lhs.recentlyShownIndex != rhs.recentlyShownIndex {
            return lhs.recentlyShownIndex < rhs.recentlyShownIndex
        }
        if lhs.dueTimestamp != rhs.dueTimestamp { return lhs.dueTimestamp < rhs.dueTimestamp }
        if lhs.modifiedTimestamp != rhs.modifiedTimestamp {
            return lhs.modifiedTimestamp < rhs.modifiedTimestamp
        }
        if lhs.normalizedTitle != rhs.normalizedTitle { return lhs.normalizedTitle < rhs.normalizedTitle }
        return lhs.identifier < rhs.identifier
    }
}
