import Foundation

struct LocalSecrets: Sendable {
    var openAIAPIKey: String
    var voiceAppID: String
    var voiceAccessToken: String
    var voiceResourceID: String
    var voiceCluster: String
    var voiceWebSocketURL: String

    static let empty = LocalSecrets(
        openAIAPIKey: "",
        voiceAppID: "",
        voiceAccessToken: "",
        voiceResourceID: "",
        voiceCluster: "",
        voiceWebSocketURL: ""
    )
}

enum LocalSecretsLoader {
    static func load() -> LocalSecrets {
        guard let url = Bundle.main.url(forResource: "Secrets.local", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let rawObject = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = rawObject as? [String: Any] else {
            return .empty
        }

        func value(_ key: String) -> String {
            (dictionary[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        return LocalSecrets(
            openAIAPIKey: value("OPENAI_API_KEY"),
            voiceAppID: value("VOICE_APP_ID"),
            voiceAccessToken: value("VOICE_ACCESS_TOKEN"),
            voiceResourceID: value("VOICE_RESOURCE_ID"),
            voiceCluster: value("VOICE_CLUSTER"),
            voiceWebSocketURL: value("VOICE_WS_URL")
        )
    }
}
