import SwiftData

enum DefaultConfigurationSeeder {
    static func ensureDefaults(in context: ModelContext) {
        ensureDefaultModelProfile(in: context)
        ensureDefaultVoicePreference(in: context)
        try? context.save()
    }

    private static func ensureDefaultModelProfile(in context: ModelContext) {
        let profiles = (try? context.fetch(FetchDescriptor<ModelProfile>())) ?? []

        if profiles.isEmpty {
            context.insert(ModelProfile())
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
            if profile.apiKeyReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.apiKeyReference = ""
            }
        }
    }

    private static func ensureDefaultVoicePreference(in context: ModelContext) {
        let preferences = (try? context.fetch(FetchDescriptor<UserPreference>())) ?? []
        if preferences.isEmpty {
            context.insert(UserPreference())
            return
        }

        for preference in preferences {
            if preference.voiceProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preference.voiceProvider = VoiceProviderPreset.doubao.rawValue
            }
            let trimmedVoiceURL = preference.voiceBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedVoiceURL.isEmpty || trimmedVoiceURL.contains("bigmodel") {
                preference.voiceBaseURL = "wss://openspeech.bytedance.com/api/v2/asr"
            }
            if preference.voiceAppKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preference.voiceAppKey = ""
            }
            if preference.voiceAPIKeyReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preference.voiceAPIKeyReference = ""
            }
            if preference.voiceModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preference.voiceModelID = "volc.seedasr.sauc.duration"
            }
            if preference.voiceCluster.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preference.voiceCluster = "volcengine_input_common"
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
