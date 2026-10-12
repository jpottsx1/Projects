#if os(iOS)
import QuickLook
import SwiftUI

/// Quick Look with its markup tools: draw, write, add shapes and a
/// signature on a PDF or a picture. Changes are saved into the file.
struct MarkupView: UIViewControllerRepresentable {
    let url: URL
    let onSaved: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        preview.setEditing(true, animated: false)
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let parent: MarkupView

        init(_ parent: MarkupView) {
            self.parent = parent
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            parent.url as NSURL
        }

        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            .updateContents
        }

        func previewController(_ controller: QLPreviewController, didUpdateContentsOf previewItem: QLPreviewItem) {
            DispatchQueue.main.async { self.parent.onSaved() }
        }
    }
}
#endif
