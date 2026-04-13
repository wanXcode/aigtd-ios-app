import SwiftData
import SwiftUI

@main
struct AIGTDRemindersApp: App {
    private let modelContainer: ModelContainer
    @State private var appModel = AppModel()
    private let rootContext: ModelContext

    init() {
        Self.mark("app_init_begin")
        do {
            let container = try Self.makeModelContainer()
            modelContainer = container
            rootContext = ModelContext(container)
            Self.mark("model_container_ready")
        } catch {
            do {
                try Self.resetPersistentStoreFiles()
                let container = try Self.makeModelContainer()
                modelContainer = container
                rootContext = ModelContext(container)
                Self.mark("model_container_ready_after_reset")
            } catch {
                fatalError("Failed to create ModelContainer: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .task(priority: .utility) {
                    _ = DoubaoOfficialASRSession.prepareEnvironmentIfNeeded()
                    Self.mark("defaults_seed_begin")
                    AIGTDAgentDocumentStore.ensureDefaults(in: rootContext)
                    DefaultConfigurationSeeder.ensureDefaults(in: rootContext)
                    Self.mark("defaults_seed_end")
                }
        }
        .modelContainer(modelContainer)
    }
}

extension AIGTDRemindersApp {
    static func makeModelContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ChatSession.self,
            ChatMessage.self,
            ActionLog.self,
            AgentDocument.self,
            ModelProfile.self,
            ExecutionPolicy.self,
            UserPreference.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: false)
        )
    }

    static func resetPersistentStoreFiles() throws {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let candidates = [
            appSupportURL.appendingPathComponent("default.store"),
            appSupportURL.appendingPathComponent("default.store-shm"),
            appSupportURL.appendingPathComponent("default.store-wal"),
            appSupportURL.appendingPathComponent("AIGTDReminders.store"),
            appSupportURL.appendingPathComponent("AIGTDReminders.store-shm"),
            appSupportURL.appendingPathComponent("AIGTDReminders.store-wal")
        ]

        for url in candidates where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    static func mark(_ label: String) {
        #if DEBUG
        print("[Startup] \(label) \(Date().timeIntervalSince1970)")
        #endif
    }
}
