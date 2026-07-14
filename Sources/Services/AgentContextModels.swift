import Foundation

struct AgentContextSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let timeZoneIdentifier: String
    let session: SessionContext
    let recentTurns: [AgentConversationTurn]
    let sessionSummary: SessionSummary?
    let reminders: [ReminderContextItem]
    let references: ReferenceContext
    let preferences: [UserMemoryItem]
    let documents: AgentDocumentContext
    let privacy: ContextPrivacyDescriptor

    init(
        generatedAt: Date,
        timeZoneIdentifier: String,
        session: SessionContext,
        recentTurns: [AgentConversationTurn],
        sessionSummary: SessionSummary?,
        reminders: [ReminderContextItem],
        references: ReferenceContext,
        preferences: [UserMemoryItem],
        documents: AgentDocumentContext,
        privacy: ContextPrivacyDescriptor,
        schemaVersion: Int = AgentContextSnapshot.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
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
    }
}

struct SessionContext: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
}

struct SessionSummary: Codable, Equatable, Sendable {
    var currentGoal: String?
    var taskScope: String?
    var confirmedConstraints: [String]
    var pendingQuestions: [String]
    var relatedReminderIDs: [String]
    var coveredThroughMessageID: UUID?
    var updatedAt: Date
}

enum ReminderContextRelevance: String, Codable, CaseIterable, Sendable {
    case explicitlySelected = "explicitly_selected"
    case recentlyCreated = "recently_created"
    case recentlyModified = "recently_modified"
    case recentlyMoved = "recently_moved"
    case recentlyCompleted = "recently_completed"
    case recentlyShown = "recently_shown"
    case dateScope = "date_scope"
    case listScope = "list_scope"
    case overdue = "overdue"
    case today = "today"
    case openItem = "open_item"
}

struct ReminderContextItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let listID: String?
    let listTitle: String
    let dueDate: Date?
    let isCompleted: Bool
    let lastModifiedAt: Date?
    let relevanceReasons: [ReminderContextRelevance]
    let notesPreview: String?
}

struct ReminderReference: Codable, Equatable, Sendable {
    let reminderID: String
    let sourceMessageID: UUID?
    let recordedAt: Date
    var isStale: Bool
    var staleSince: Date?

    init(
        reminderID: String,
        sourceMessageID: UUID? = nil,
        recordedAt: Date,
        isStale: Bool = false,
        staleSince: Date? = nil
    ) {
        self.reminderID = reminderID
        self.sourceMessageID = sourceMessageID
        self.recordedAt = recordedAt
        self.isStale = isStale
        self.staleSince = staleSince
    }
}

struct ReferenceContext: Codable, Equatable, Sendable {
    var recentlyCreated: ReminderReference?
    var recentlyModified: ReminderReference?
    var recentlyMoved: ReminderReference?
    var recentlyCompleted: ReminderReference?
    var recentlyShown: [ReminderReference]
    var explicitlySelected: ReminderReference?

    static let empty = ReferenceContext(
        recentlyCreated: nil,
        recentlyModified: nil,
        recentlyMoved: nil,
        recentlyCompleted: nil,
        recentlyShown: [],
        explicitlySelected: nil
    )

    var allReferences: [ReminderReference] {
        [recentlyCreated, recentlyModified, recentlyMoved, recentlyCompleted, explicitlySelected]
            .compactMap { $0 } + recentlyShown
    }

    func removingStaleReferences(olderThan cutoff: Date) -> ReferenceContext {
        func retained(_ reference: ReminderReference?) -> ReminderReference? {
            guard let reference else { return nil }
            guard reference.isStale, let staleSince = reference.staleSince else { return reference }
            return staleSince >= cutoff ? reference : nil
        }

        return ReferenceContext(
            recentlyCreated: retained(recentlyCreated),
            recentlyModified: retained(recentlyModified),
            recentlyMoved: retained(recentlyMoved),
            recentlyCompleted: retained(recentlyCompleted),
            recentlyShown: recentlyShown.compactMap { retained($0) },
            explicitlySelected: retained(explicitlySelected)
        )
    }
}

enum UserMemoryCategory: String, Codable, CaseIterable, Sendable {
    case preferredName = "preferred_name"
    case timeZone = "time_zone"
    case defaultTaskTime = "default_task_time"
    case defaultList = "default_list"
    case workingSchedule = "working_schedule"
    case transactionRule = "transaction_rule"
}

struct UserMemoryItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let category: UserMemoryCategory
    var value: String
    let sourceMessageID: UUID?
    let createdAt: Date
    var updatedAt: Date
}

struct AgentDocumentContext: Codable, Equatable, Sendable {
    let prompt: String
    let memory: String
    let solu: String
    let operatingGuide: String
}

struct ContextPrivacyDescriptor: Codable, Equatable, Sendable {
    let includesNotes: Bool
    let includesCompletedReminders: Bool
    let maximumReminderCount: Int
    let reminderSnapshotIsStale: Bool
    let originalReminderCount: Int
    let includedReminderCount: Int
    let truncatedReminderCount: Int
    let truncatedTurnCount: Int
}

struct AgentContextPrivacySettings: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let standard = AgentContextPrivacySettings(
        schemaVersion: currentSchemaVersion,
        includesNotes: false,
        includesCompletedReminders: false,
        maximumReminderCount: 40
    )

    let schemaVersion: Int
    var includesNotes: Bool
    var includesCompletedReminders: Bool
    var maximumReminderCount: Int

    init(
        schemaVersion: Int = AgentContextPrivacySettings.currentSchemaVersion,
        includesNotes: Bool = false,
        includesCompletedReminders: Bool = false,
        maximumReminderCount: Int = 40
    ) {
        self.schemaVersion = schemaVersion
        self.includesNotes = includesNotes
        self.includesCompletedReminders = includesCompletedReminders
        self.maximumReminderCount = min(max(maximumReminderCount, 1), 100)
    }
}
