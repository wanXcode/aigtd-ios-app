import SwiftData

enum DefaultConfigurationSeeder {
    static func ensureDefaults(in context: ModelContext) {
        let secrets = LocalSecretsLoader.load()
        ensureDefaultModelProfile(in: context, secrets: secrets)
        ensureDefaultVoicePreference(in: context, secrets: secrets)
        try? context.save()
    }

    private static func ensureDefaultModelProfile(in context: ModelContext, secrets: LocalSecrets) {
        let profiles = (try? context.fetch(FetchDescriptor<ModelProfile>())) ?? []

        if profiles.isEmpty {
            context.insert(
                ModelProfile(
                    apiKeyReference: secrets.openAIAPIKey
                )
            )
            return
        }

        if profiles.contains(where: \.isActive) == false, let first = profiles.first {
            first.isActive = true
        }

        for profile in profiles {
            if profile.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.provider = "OpenAI"
            }
            if profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.displayName = "OpenAI"
            }
            if profile.wireAPI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.wireAPI = "responses"
            }
            if profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.modelID = "gpt-5.4"
            }
            if profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.baseURL = "https://api.5666.net"
            }
            if profile.apiKeyReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               secrets.openAIAPIKey.isEmpty == false {
                profile.apiKeyReference = secrets.openAIAPIKey
            }
        }
    }

    private static func ensureDefaultVoicePreference(in context: ModelContext, secrets: LocalSecrets) {
        let preferences = (try? context.fetch(FetchDescriptor<UserPreference>())) ?? []
        if preferences.isEmpty {
            context.insert(
                UserPreference(
                    voiceBaseURL: secrets.voiceWebSocketURL.isEmpty ? "wss://openspeech.bytedance.com/api/v2/asr" : secrets.voiceWebSocketURL,
                    voiceAppKey: secrets.voiceAppID,
                    voiceAPIKeyReference: secrets.voiceAccessToken,
                    voiceModelID: secrets.voiceResourceID.isEmpty ? "volc.seedasr.sauc.duration" : secrets.voiceResourceID,
                    voiceCluster: secrets.voiceCluster.isEmpty ? "volcengine_input_common" : secrets.voiceCluster
                )
            )
            return
        }

        for preference in preferences {
            if preference.voiceProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preference.voiceProvider = VoiceProviderPreset.doubao.rawValue
            }
            let trimmedVoiceURL = preference.voiceBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedVoiceURL.isEmpty || trimmedVoiceURL.contains("bigmodel") {
                preference.voiceBaseURL = secrets.voiceWebSocketURL.isEmpty ? "wss://openspeech.bytedance.com/api/v2/asr" : secrets.voiceWebSocketURL
            }
            if preference.voiceAppKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               secrets.voiceAppID.isEmpty == false {
                preference.voiceAppKey = secrets.voiceAppID
            }
            if preference.voiceAPIKeyReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               secrets.voiceAccessToken.isEmpty == false {
                preference.voiceAPIKeyReference = secrets.voiceAccessToken
            }
            if preference.voiceModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preference.voiceModelID = secrets.voiceResourceID.isEmpty ? "volc.seedasr.sauc.duration" : secrets.voiceResourceID
            }
            if preference.voiceCluster.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preference.voiceCluster = secrets.voiceCluster.isEmpty ? "volcengine_input_common" : secrets.voiceCluster
            }
            if preference.voiceLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preference.voiceLanguageCode = "zh-CN"
            }
            if preference.voiceEnabled == false {
                preference.voiceEnabled = true
            }
        }
    }
}
