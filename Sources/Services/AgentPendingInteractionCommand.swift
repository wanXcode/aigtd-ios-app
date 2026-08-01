import Foundation

enum AgentPendingInteractionCommand: Equatable, Sendable {
    case confirm
    case cancel
    case none
}

struct AgentPendingInteractionCommandParser: Sendable {
    func parse(_ input: String) -> AgentPendingInteractionCommand {
        let normalized = normalize(input)
        guard normalized.isEmpty == false else { return .none }

        if Self.cancellationPhrases.contains(normalized) {
            return .cancel
        }
        if Self.confirmationPhrases.contains(normalized) {
            return .confirm
        }
        return .none
    }

    private func normalize(_ input: String) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .unicodeScalars
            .filter { scalar in
                CharacterSet.whitespacesAndNewlines.contains(scalar) == false
                    && CharacterSet.punctuationCharacters.contains(scalar) == false
            }
            .map(String.init)
            .joined()
    }

    private static let confirmationPhrases: Set<String> = [
        "执行吧",
        "执行",
        "确认",
        "确认执行",
        "就按这个来",
        "就按这个方案来",
        "按这个来",
        "按这个方案执行",
        "执行这个计划",
        "执行这个方案",
        "可以执行",
        "开始执行",
        "没问题执行吧"
    ]

    private static let cancellationPhrases: Set<String> = [
        "算了",
        "算了不执行了",
        "算了不要执行了",
        "取消",
        "取消执行",
        "取消这个计划",
        "取消这个方案",
        "不要执行",
        "不要执行了",
        "先不要执行",
        "先不要执行了",
        "先别执行",
        "别执行",
        "不执行了"
    ]
}
