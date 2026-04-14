import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

    var body: some View {
        Group {
            if appModel.onboardingState.isFinished || sessions.isEmpty == false {
                MainTabView()
            } else {
                OnboardingRootView()
            }
        }
        .preferredColorScheme(.light)
        .task {
            AIGTDRemindersApp.mark("root_view_task_begin")
            await appModel.bootstrapAfterLaunch()
            AIGTDRemindersApp.mark("root_view_task_end")
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
