import Foundation

struct AgentUndoCommandParser: Sendable {
    func matches(_ input: String) -> Bool {
        Self.phrases.contains(normalize(input))
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

    private static let phrases: Set<String> = [
        "撤销",
        "撤销刚才的操作",
        "撤销刚才的修改",
        "把刚才的操作撤销",
        "把刚才的修改撤销",
        "恢复刚才的操作",
        "恢复到修改前",
        "回到修改前"
    ]
}
