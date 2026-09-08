import SwiftUI
import UIKit

/// The batch handed to the share sheet. Identifiable so `.sheet(item:)` can
/// present it exactly once per export.
struct ShareBatch: Identifiable {
    let id = UUID()
    let files: [ExportedFile]
}

struct ShareSheet: UIViewControllerRepresentable {
    let batch: ShareBatch
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: batch.files.map(\.url),
            applicationActivities: nil
        )
        controller.excludedActivityTypes = [
            .assignToContact, .addToReadingList, .print, .markupAsPDF,
            .postToFacebook, .postToTwitter, .postToWeibo, .postToVimeo,
            .postToFlickr, .postToTencentWeibo,
        ]
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onFinish(completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
