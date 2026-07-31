import Foundation

enum AgentToolBatchItemStatus: String, Codable, Equatable, Sendable {
    case applied
    case unchanged
    case failed
    case skipped
    case cancelled

    var isSuccessful: Bool {
        self == .applied || self == .unchanged
    }
}

struct AgentToolBatchItem: Equatable, Sendable {
    let id: String
    let dependencyIDs: [String]

    init(id: String, dependencyIDs: [String] = []) {
        self.id = id
        self.dependencyIDs = dependencyIDs
    }
}

enum AgentToolBatchOperationOutcome: Equatable, Sendable {
    case applied
    case unchanged
}

struct AgentToolBatchItemResult: Codable, Equatable, Sendable {
    let itemID: String
    let status: AgentToolBatchItemStatus
    let errorMessage: String?
    let unsuccessfulDependencyIDs: [String]

    init(
        itemID: String,
        status: AgentToolBatchItemStatus,
        errorMessage: String? = nil,
        unsuccessfulDependencyIDs: [String] = []
    ) {
        self.itemID = itemID
        self.status = status
        self.errorMessage = errorMessage
        self.unsuccessfulDependencyIDs = unsuccessfulDependencyIDs
    }
}

struct AgentToolBatchExecutionReport: Codable, Equatable, Sendable {
    let items: [AgentToolBatchItemResult]

    var appliedCount: Int { count(of: .applied) }
    var unchangedCount: Int { count(of: .unchanged) }
    var failedCount: Int { count(of: .failed) }
    var skippedCount: Int { count(of: .skipped) }
    var cancelledCount: Int { count(of: .cancelled) }
    var successfulCount: Int { items.lazy.filter(\.status.isSuccessful).count }

    func result(for itemID: String) -> AgentToolBatchItemResult? {
        items.first { $0.itemID == itemID }
    }

    func merging(_ newerReport: AgentToolBatchExecutionReport) -> AgentToolBatchExecutionReport {
        var order = items.map(\.itemID)
        var merged = Dictionary(uniqueKeysWithValues: items.map { ($0.itemID, $0) })
        for result in newerReport.items {
            if merged[result.itemID] == nil {
                order.append(result.itemID)
            }
            merged[result.itemID] = result
        }
        return AgentToolBatchExecutionReport(items: order.compactMap { merged[$0] })
    }

    private func count(of status: AgentToolBatchItemStatus) -> Int {
        items.lazy.filter { $0.status == status }.count
    }
}

struct AgentToolBatchExecution {
    static func execute(
        items: [AgentToolBatchItem],
        previousReport: AgentToolBatchExecutionReport? = nil,
        isCancelled: () -> Bool = { false },
        operation: (AgentToolBatchItem) throws -> AgentToolBatchOperationOutcome
    ) -> AgentToolBatchExecutionReport {
        var mergedResults = Dictionary(
            uniqueKeysWithValues: (previousReport?.items ?? []).map { ($0.itemID, $0) }
        )
        var attemptResults: [AgentToolBatchItemResult] = []
        var cancellationRequested = false

        for item in items {
            if let previous = mergedResults[item.id], previous.status.isSuccessful {
                continue
            }

            if cancellationRequested || isCancelled() {
                cancellationRequested = true
                let result = AgentToolBatchItemResult(itemID: item.id, status: .cancelled)
                mergedResults[item.id] = result
                attemptResults.append(result)
                continue
            }

            let unsuccessfulDependencies = item.dependencyIDs.filter {
                mergedResults[$0]?.status.isSuccessful != true
            }
            if unsuccessfulDependencies.isEmpty == false {
                let result = AgentToolBatchItemResult(
                    itemID: item.id,
                    status: .skipped,
                    unsuccessfulDependencyIDs: unsuccessfulDependencies
                )
                mergedResults[item.id] = result
                attemptResults.append(result)
                continue
            }

            let result: AgentToolBatchItemResult
            do {
                switch try operation(item) {
                case .applied:
                    result = AgentToolBatchItemResult(itemID: item.id, status: .applied)
                case .unchanged:
                    result = AgentToolBatchItemResult(itemID: item.id, status: .unchanged)
                }
            } catch is CancellationError {
                cancellationRequested = true
                result = AgentToolBatchItemResult(itemID: item.id, status: .cancelled)
            } catch {
                result = AgentToolBatchItemResult(
                    itemID: item.id,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
            }
            mergedResults[item.id] = result
            attemptResults.append(result)
        }

        let attemptReport = AgentToolBatchExecutionReport(items: attemptResults)
        return previousReport?.merging(attemptReport) ?? attemptReport
    }
}
