import SwiftUI
import UIKit

@main
struct CadenciaApp: App {
    @UIApplicationDelegateAdaptor(CadenciaAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            StartupView()
                .environment(model)
                // Recent rides load off the main thread, so Home and Plan never decode them while rendering.
                .task { await model.warmRecentRides() }
                // Saved rides reload from disk on demand, so a memory warning can drop the cached ones.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    model.releaseCachedRides()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // State writes are coalesced off the main thread; the newest one must be on disk before suspension.
            if phase == .background { model.flushPersistence() }
        }
    }
}
