import Foundation

enum ReminderBatchExecutionStatus: String, Codable, Sendable {
    case success
    case partial
    case failed
}

struct ReminderBatchItemResult: Codable, Hashable, Sendable {
    let reminderID: String
    let title: String
    let succeeded: Bool
    let errorMessage: String?
}

struct ReminderBatchExecutionReport: Codable, Hashable, Sendable {
    let items: [ReminderBatchItemResult]
    let refreshErrorMessage: String?

    var totalCount: Int { items.count }
    var successCount: Int { items.lazy.filter(\.succeeded).count }
    var failureCount: Int { totalCount - successCount }

    var status: ReminderBatchExecutionStatus {
        if successCount == 0 {
            return .failed
        }
        if failureCount > 0 || refreshErrorMessage != nil {
            return .partial
        }
        return .success
    }

    var failedItems: [ReminderBatchItemResult] {
        items.filter { $0.succeeded == false }
    }

    func failureTitles(limit: Int = 3) -> [String] {
        guard limit > 0 else { return [] }
        return failedItems.prefix(limit).map(\.title)
    }

    func recordingRefreshFailure(_ message: String?) -> ReminderBatchExecutionReport {
        let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReminderBatchExecutionReport(
            items: items,
            refreshErrorMessage: trimmedMessage?.isEmpty == false ? trimmedMessage : nil
        )
    }
}

struct ReminderBatchExecution {
    static func execute(
        items: [ReschedulePlanItem],
        operation: (ReschedulePlanItem) throws -> Void
    ) -> ReminderBatchExecutionReport {
        let results = items.map { item in
            do {
                try operation(item)
                return ReminderBatchItemResult(
                    reminderID: item.reminderID,
                    title: item.title,
                    succeeded: true,
                    errorMessage: nil
                )
            } catch {
                return ReminderBatchItemResult(
                    reminderID: item.reminderID,
                    title: item.title,
                    succeeded: false,
                    errorMessage: error.localizedDescription
                )
            }
        }

        return ReminderBatchExecutionReport(items: results, refreshErrorMessage: nil)
    }
}
