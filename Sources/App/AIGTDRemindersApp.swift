import SwiftData
import SwiftUI

@main
struct AIGTDRemindersApp: App {
    private let modelContainer: ModelContainer
    @State private var appModel = AppModel()

    init() {
        do {
            modelContainer = try ModelContainer(
                for: ChatSession.self,
                ChatMessage.self,
                ActionLog.self,
                AgentDocument.self,
                ModelProfile.self,
                ExecutionPolicy.self,
                UserPreference.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: false)
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
        }
        .modelContainer(modelContainer)
    }
}
