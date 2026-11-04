import SwiftUI
import UniformTypeIdentifiers

/// Open in place, then let the app coordinate/read the file with its own visible progress.
/// Requesting a copied document can leave a Files-provider transfer hidden behind the picker.
struct GPXDocumentPicker: UIViewControllerRepresentable {
    private static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
    let picked: (URL) -> Void
    let cancelled: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [Self.gpx, .xml], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: GPXDocumentPicker
        init(parent: GPXDocumentPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.picked(url) }
            else { parent.cancelled() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.cancelled() }
    }
}
