import UIKit

/// Asks iOS for time to finish work that must not be cut short when the app moves to the background,
/// such as writing a finished ride, its index and its upload entry. Ends on `end()` or when iOS says
/// the time is up, whichever comes first.
@MainActor
final class BackgroundActivity {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
