import Foundation
import SwiftData

enum AIGTDAgentDocumentKind: String, CaseIterable {
    case prompt = "prompt"
    case memory = "memory"
    case solu = "solu"
    case operatingGuide = "operating_guide"

    var title: String {
        switch self {
        case .prompt:
            return "Prompt"
        case .memory:
            return "Memory"
        case .solu:
            return "Solu"
        case .operatingGuide:
            return "Operating Guide"
        }
    }

    var defaultContent: String {
        switch self {
        case .prompt:
            return """
            你是 AIGTD，一个长期在线的个人事务管理助手。

            你的角色不是泛泛聊天助手，而是事务秘书。你的首要任务是：
            - 帮用户记事
            - 帮用户改任务
            - 帮用户确认今天 / 明天 / 未来安排
            - 帮用户把事情收口成清晰、可执行的提醒事项

            说话规则：
            - 先结果，后补充
            - 短、清楚、像事务秘书
            - 少讲系统设计，少讲技术话
            - 能直接记就直接记，能直接改就直接改
            - 默认把用户输入当作事务管理指令，而不是泛泛聊天
            """
        case .memory:
            return """
            # AIGTD Memory

            - 用户称呼：哥哥
            - 默认时区：Asia/Shanghai
            - 提到待办、清单、今天、明天、提醒事项时，默认按事务管理来理解
            - 行为偏好：少追问，先执行，再解释
            - 最多做 1~2 轮必要澄清，超过后按合理默认值先落任务
            """
        case .solu:
            return """
            # AIGTD Solu

            - 当前目标：把 iOS 里的 AIGTD 做得更像飞书里的事务秘书，而不是命令解析器
            - 当前执行层：Apple Reminders
            - 当前交互方向：普通对话不出卡，真正执行动作才显示确认卡
            - 当前关注点：降低误判、减少技术味、提升查看类回复的自然度
            """
        case .operatingGuide:
            return """
            # AIGTD Operating Guide

            - 目标：承接用户的日常事务型对话
            - 默认动作：能直接记就直接记，能直接改就直接改
            - 查看类回复要先说人话结论，再补必要说明
            - 不要把内部 schema、intent、category、bucket 当作主回复内容
            - 如果事情超出事务管理边界，简短收口，不要硬接成长篇泛聊
            """
        }
    }
}

enum AIGTDAgentDocumentStore {
    static func ensureDefaults(in context: ModelContext) {
        let existingDocuments = (try? context.fetch(FetchDescriptor<AgentDocument>())) ?? []

        for kind in AIGTDAgentDocumentKind.allCases {
            let existing = existingDocuments.filter { $0.kind == kind.rawValue }
            guard existing.isEmpty else { continue }
            context.insert(
                AgentDocument(
                    kind: kind.rawValue,
                    content: kind.defaultContent,
                    isSystemManaged: false
                )
            )
        }

        try? context.save()
    }

    static func runtimeContext(from documents: [AgentDocument]) -> AIGTDAgentRuntimeContext {
        func content(for kind: AIGTDAgentDocumentKind) -> String {
            documents.first(where: { $0.kind == kind.rawValue })?.content ?? kind.defaultContent
        }

        return AIGTDAgentRuntimeContext(
            prompt: content(for: .prompt),
            memory: content(for: .memory),
            solu: content(for: .solu),
            operatingGuide: content(for: .operatingGuide)
        )
    }
}

struct AIGTDAgentRuntimeContext: Sendable {
    let prompt: String
    let memory: String
    let solu: String
    let operatingGuide: String
}
