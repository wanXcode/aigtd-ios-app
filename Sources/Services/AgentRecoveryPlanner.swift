import Foundation

enum AgentRecoveryFailureKind: String, Codable, Equatable, Sendable {
    case retryable
    case refreshRequired
    case userActionRequired
    case terminal
}

enum AgentRecoveryAction: String, Codable, Equatable, Sendable {
    case retry
    case refreshAndReconfirm
    case requestUserAction
    case stop
}

struct AgentRecoveryRetryCandidate: Codable, Equatable, Sendable {
    let runID: UUID
    let callID: String
    let tool: AgentToolName
    let itemIDs: [String]

    init(result: AgentToolResult, itemIDs: [String] = []) {
        runID = result.runID
        callID = result.callID
        tool = result.tool
        self.itemIDs = itemIDs
    }
}

struct AgentRecoveryItem: Codable, Equatable, Sendable {
    let runID: UUID
    let callID: String
    let itemID: String?
    let tool: AgentToolName
    let status: AgentToolExecutionStatus
    let failureKind: AgentRecoveryFailureKind
    let recommendedAction: AgentRecoveryAction
    let recommendation: String
}

struct AgentRecoveryPlan: Codable, Equatable, Sendable {
    let items: [AgentRecoveryItem]
    let retryCandidates: [AgentRecoveryRetryCandidate]

    var hasRetryableFailures: Bool {
        retryCandidates.isEmpty == false
    }

    var recommendation: String {
        if retryCandidates.isEmpty == false {
            return "可以重试失败项；重试会复用原操作标识，已成功或无需修改的项目不会再次执行。"
        }
        if items.contains(where: { $0.failureKind == .refreshRequired }) {
            return "请先刷新任务状态并重新确认方案，不能直接覆盖当前数据。"
        }
        if items.contains(where: { $0.failureKind == .userActionRequired }) {
            return "需要你先完成授权、补充凭证或明确目标，然后再继续。"
        }
        if items.isEmpty == false {
            return "这些失败无法安全重试，请检查错误后重新发起操作。"
        }
        return "没有可恢复的失败项。"
    }
}

struct AgentRecoveryPlanner: Sendable {
    func makePlan(from results: [AgentToolResult]) -> AgentRecoveryPlan {
        var items: [AgentRecoveryItem] = []
        var retryCandidates: [AgentRecoveryRetryCandidate] = []

        for result in results {
            if let batchItems = batchFailureItems(from: result) {
                items.append(contentsOf: batchItems)
                let retryableItemIDs = batchItems.compactMap { item in
                    item.failureKind == .retryable ? item.itemID : nil
                }
                if retryableItemIDs.isEmpty == false {
                    retryCandidates.append(
                        AgentRecoveryRetryCandidate(result: result, itemIDs: retryableItemIDs)
                    )
                }
                continue
            }
            guard result.status == .failed || result.status == .timedOut else { continue }
            let item = makeItem(for: result)
            items.append(item)
            if item.failureKind == .retryable {
                retryCandidates.append(AgentRecoveryRetryCandidate(result: result))
            }
        }

        return AgentRecoveryPlan(items: items, retryCandidates: retryCandidates)
    }

    private func makeItem(for result: AgentToolResult) -> AgentRecoveryItem {
        let kind = failureKind(for: result)
        let action: AgentRecoveryAction
        let recommendation: String

        switch kind {
        case .retryable:
            action = .retry
            recommendation = "重试此失败项，并复用原 run_id 与 call_id；最多自动重试一次。"
        case .refreshRequired:
            action = .refreshAndReconfirm
            recommendation = "重新查询最新任务或清单状态，生成新方案并再次确认后再执行。"
        case .userActionRequired:
            action = .requestUserAction
            recommendation = userActionRecommendation(for: result.error?.category)
        case .terminal:
            action = .stop
            recommendation = "停止重试；请修正协议或请求后重新发起操作。"
        }

        return AgentRecoveryItem(
            runID: result.runID,
            callID: result.callID,
            itemID: nil,
            tool: result.tool,
            status: result.status,
            failureKind: kind,
            recommendedAction: action,
            recommendation: recommendation
        )
    }

    private func batchFailureItems(from result: AgentToolResult) -> [AgentRecoveryItem]? {
        guard result.tool == .applySchedule,
              case let .string(planStatus)? = result.result?["plan_status"],
              planStatus == "partial",
              case let .array(rawItems)? = result.result?["items"] else {
            return nil
        }

        return rawItems.compactMap { value in
            guard case let .object(item) = value,
                  case let .string(status)? = item["status"],
                  status == "failed",
                  case let .string(itemID)? = item["item_id"] else {
                return nil
            }
            let category: AgentToolErrorCategory?
            if case let .string(rawCategory)? = item["error_category"] {
                category = AgentToolErrorCategory(rawValue: rawCategory)
            } else {
                category = nil
            }
            let kind = failureKind(status: .failed, category: category)
            return AgentRecoveryItem(
                runID: result.runID,
                callID: result.callID,
                itemID: itemID,
                tool: result.tool,
                status: .failed,
                failureKind: kind,
                recommendedAction: action(for: kind),
                recommendation: recommendation(for: kind, category: category)
            )
        }
    }

    private func failureKind(for result: AgentToolResult) -> AgentRecoveryFailureKind {
        failureKind(status: result.status, category: result.error?.category)
    }

    private func failureKind(
        status: AgentToolExecutionStatus,
        category: AgentToolErrorCategory?
    ) -> AgentRecoveryFailureKind {
        if status == .timedOut {
            return .retryable
        }

        switch category {
        case .timeout, .networkError, .eventKitError, .toolExecutionFailed:
            return .retryable

        case .notFound, .listNotFound, .staleReference, .preconditionConflict, .planExpired:
            return .refreshRequired

        case .permissionDenied, .ambiguousTarget, .confirmationRequired:
            return .userActionRequired

        case .invalidArguments, .budgetExhausted, .modelProtocolError, .unknownTool, .cancelled, .none:
            return .terminal
        }
    }

    private func action(for kind: AgentRecoveryFailureKind) -> AgentRecoveryAction {
        switch kind {
        case .retryable: .retry
        case .refreshRequired: .refreshAndReconfirm
        case .userActionRequired: .requestUserAction
        case .terminal: .stop
        }
    }

    private func recommendation(
        for kind: AgentRecoveryFailureKind,
        category: AgentToolErrorCategory?
    ) -> String {
        switch kind {
        case .retryable:
            "重试此失败项，并复用原 run_id 与 call_id；最多自动重试一次。"
        case .refreshRequired:
            "重新查询最新任务或清单状态，生成新方案并再次确认后再执行。"
        case .userActionRequired:
            userActionRecommendation(for: category)
        case .terminal:
            "停止重试；请修正协议或请求后重新发起操作。"
        }
    }

    private func userActionRecommendation(for category: AgentToolErrorCategory?) -> String {
        switch category {
        case .permissionDenied:
            return "请先在系统设置中授予提醒事项权限，然后再继续。"
        case .ambiguousTarget:
            return "请明确要操作的具体任务或清单，然后重新提交。"
        case .confirmationRequired:
            return "请先确认待执行方案，再继续操作。"
        default:
            return "需要你完成必要操作后再继续。"
        }
    }
}
