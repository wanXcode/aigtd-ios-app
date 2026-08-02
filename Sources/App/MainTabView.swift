import Foundation
import Observation
import SwiftUI

struct MainTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var welcomeStore = XiaomanWelcomeStore()
    @State private var showsSettings = false
#if DEBUG || INTERNAL
    @State private var showsDeveloperSettings = false
#endif

    var body: some View {
        TabView(selection: Binding(
            get: { publicTabSelection },
            set: { appModel.selectedTab = $0 }
        )) {
            NavigationStack {
                ChatHomeView()
                    .environment(welcomeStore)
                    .toolbar { settingsToolbar }
            }
            .tag(AppTab.chat)
            .tabItem {
                Label("AIGTD", systemImage: "message.fill")
            }

            NavigationStack {
                RemindersOverviewView()
                    .toolbar { settingsToolbar }
            }
            .tag(AppTab.reminders)
            .tabItem {
                Label("任务", systemImage: "checklist")
            }
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                PublicSettingsView()
            }
        }
#if DEBUG || INTERNAL
        .sheet(isPresented: $showsDeveloperSettings) {
            NavigationStack {
                AgentHomeView()
            }
        }
#endif
        .onChange(of: appModel.selectedTab) { _, selectedTab in
            guard selectedTab == .agent else { return }
            appModel.selectedTab = .chat
#if DEBUG || INTERNAL
            showsDeveloperSettings = true
#else
            showsSettings = true
#endif
        }
    }

    private var publicTabSelection: AppTab {
        appModel.selectedTab == .reminders ? .reminders : .chat
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("设置")
        }
    }
}

@MainActor
@Observable
final class XiaomanWelcomeStore {
    static let welcomeMessage = "你好，我是小满，你的 AIGTD 事务助理。你可以直接告诉我想记下、调整或整理什么。"

    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var hasPresentedWelcome: Bool

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "aigtd.xiaoman.welcome.presented.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        hasPresentedWelcome = defaults.bool(forKey: storageKey)
    }

    var shouldPresentWelcome: Bool {
        hasPresentedWelcome == false
    }

    func pendingWelcomeMessage() -> String? {
        shouldPresentWelcome ? Self.welcomeMessage : nil
    }

    func markWelcomePresented() {
        guard shouldPresentWelcome else { return }
        hasPresentedWelcome = true
        defaults.set(true, forKey: storageKey)
    }

    /// Kept as a convenience for callers that do not need transactional storage.
    func consumeWelcomeMessage() -> String? {
        guard let message = pendingWelcomeMessage() else { return nil }
        markWelcomePresented()
        return message
    }
}

#Preview {
    MainTabView()
        .environment(AppModel.previewFinished)
}
