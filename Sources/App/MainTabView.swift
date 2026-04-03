import SwiftUI

struct MainTabView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        TabView(selection: Binding(
            get: { appModel.selectedTab },
            set: { appModel.selectedTab = $0 }
        )) {
            NavigationStack {
                ChatHomeView()
            }
            .tag(AppTab.chat)
            .tabItem {
                Label("Chat", systemImage: "message.fill")
            }

            NavigationStack {
                RemindersOverviewView()
            }
            .tag(AppTab.reminders)
            .tabItem {
                Label("Reminders", systemImage: "checklist")
            }

            NavigationStack {
                AgentHomeView()
            }
            .tag(AppTab.agent)
            .tabItem {
                Label("Agent", systemImage: "gearshape.fill")
            }
        }
    }
}

#Preview {
    MainTabView()
        .environment(AppModel.previewFinished)
}
