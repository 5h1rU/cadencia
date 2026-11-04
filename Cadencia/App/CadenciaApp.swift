import SwiftUI

@main
struct CadenciaApp: App {
    @UIApplicationDelegateAdaptor(CadenciaAppDelegate.self) private var appDelegate
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            StartupView()
                .environment(model)
        }
    }
}
