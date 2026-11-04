import SwiftUI
import UIKit

struct GPXShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Garmin's supported iOS course-import handoff. Completion means sharing ended, not Edge receipt.
struct GPXShareSheet: UIViewControllerRepresentable {
    let file: URL
    let finished: (String?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            Task { @MainActor in finished(error?.localizedDescription) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
