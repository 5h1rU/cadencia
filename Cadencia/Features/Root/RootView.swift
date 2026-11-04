import SwiftUI
import CadenciaCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Screen = .home

    enum Screen: Hashable { case home, coach, plan, settings }

    var body: some View {
        if model.isSignedIn {
            TabView(selection: $tab) {
                Tab("Home", systemImage: "house", value: .home) { HomeView() }
                Tab("Coach", systemImage: "waveform.and.mic", value: .coach) { CoachView() }
                Tab("Plan", systemImage: "calendar", value: .plan) { PlanView() }
                Tab("Settings", systemImage: "gearshape", value: .settings) { SettingsView() }
            }
        } else {
            SignInView()
        }
    }
}

#Preview("Signed in") {
    RootView().environment(PreviewData.model())
}

#Preview("Signed out") {
    RootView().environment(PreviewData.model(signedIn: false))
}
