import Foundation
import SwiftData

@Model
final class ChatSession {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var lastMessagePreview: String

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        updatedAt: Date = .now,
        title: String = "Main Session",
        lastMessagePreview: String = ""
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.lastMessagePreview = lastMessagePreview
    }
}

@Model
final class ChatMessage {
    var id: UUID
    var sessionID: UUID
    var role: String
    var text: String
    var createdAt: Date
    var actionResultSummary: String
    var status: String

    init(
        id: UUID = UUID(),
        sessionID: UUID = UUID(),
        role: String,
        text: String,
        createdAt: Date = .now,
        actionResultSummary: String = "",
        status: String = "sent"
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.actionResultSummary = actionResultSummary
        self.status = status
    }
}

@Model
final class ActionLog {
    var id: UUID
    var sessionID: UUID
    var messageID: UUID?
    var actionType: String
    var payloadJSON: String
    var executionStatus: String
    var errorMessage: String
    var createdAt: Date
    var executedAt: Date?
    var undoToken: String

    init(
        id: UUID = UUID(),
        sessionID: UUID = UUID(),
        messageID: UUID? = nil,
        actionType: String,
        payloadJSON: String = "{}",
        executionStatus: String = "pending",
        errorMessage: String = "",
        createdAt: Date = .now,
        executedAt: Date? = nil,
        undoToken: String = ""
    ) {
        self.id = id
        self.sessionID = sessionID
        self.messageID = messageID
        self.actionType = actionType
        self.payloadJSON = payloadJSON
        self.executionStatus = executionStatus
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.executedAt = executedAt
        self.undoToken = undoToken
    }
}

@Model
final class AgentDocument {
    var id: UUID
    var kind: String
    var content: String
    var updatedAt: Date
    var isSystemManaged: Bool

    init(
        id: UUID = UUID(),
        kind: String,
        content: String = "",
        updatedAt: Date = .now,
        isSystemManaged: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.updatedAt = updatedAt
        self.isSystemManaged = isSystemManaged
    }
}

@Model
final class ModelProfile {
    var id: UUID
    var displayName: String
    var provider: String
    var wireAPI: String
    var modelID: String
    var baseURL: String
    var apiKeyReference: String
    var temperature: Double
    var maxTokens: Int
    var timeoutSeconds: Double
    var isActive: Bool

    init(
        id: UUID = UUID(),
        displayName: String = "Default",
        provider: String = "",
        wireAPI: String = "chat_completions",
        modelID: String = "",
        baseURL: String = "",
        apiKeyReference: String = "",
        temperature: Double = 0.2,
        maxTokens: Int = 800,
        timeoutSeconds: Double = 30,
        isActive: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.wireAPI = wireAPI
        self.modelID = modelID
        self.baseURL = baseURL
        self.apiKeyReference = apiKeyReference
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.timeoutSeconds = timeoutSeconds
        self.isActive = isActive
    }
}

@Model
final class ExecutionPolicy {
    var id: UUID
    var confirmDeletion: Bool
    var confirmBulkChange: Bool
    var confirmNewListCreation: Bool
    var autoExecuteSimpleCreate: Bool
    var autoExecuteSimpleUpdate: Bool

    init(
        id: UUID = UUID(),
        confirmDeletion: Bool = true,
        confirmBulkChange: Bool = true,
        confirmNewListCreation: Bool = true,
        autoExecuteSimpleCreate: Bool = true,
        autoExecuteSimpleUpdate: Bool = true
    ) {
        self.id = id
        self.confirmDeletion = confirmDeletion
        self.confirmBulkChange = confirmBulkChange
        self.confirmNewListCreation = confirmNewListCreation
        self.autoExecuteSimpleCreate = autoExecuteSimpleCreate
        self.autoExecuteSimpleUpdate = autoExecuteSimpleUpdate
    }
}

@Model
final class UserPreference {
    var id: UUID
    var timeZone: String
    var language: String
    var defaultReminderTime: String
    var preferredListMappingsJSON: String
    var stylePreferencesJSON: String

    init(
        id: UUID = UUID(),
        timeZone: String = "Asia/Shanghai",
        language: String = "zh-CN",
        defaultReminderTime: String = "09:00",
        preferredListMappingsJSON: String = "{}",
        stylePreferencesJSON: String = "{}"
    ) {
        self.id = id
        self.timeZone = timeZone
        self.language = language
        self.defaultReminderTime = defaultReminderTime
        self.preferredListMappingsJSON = preferredListMappingsJSON
        self.stylePreferencesJSON = stylePreferencesJSON
    }
}
