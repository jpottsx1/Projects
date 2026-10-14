import Foundation
import SafariServices
import StashCore

/// Takes the page Safari's Save to Stash button sends and leaves it in the
/// shared inbox for the app, as the share extension does: the extension
/// never opens the library itself.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    /// Set by `SHARE_EXTENSION` in Config/Stash.xcconfig.
    #if SHARE_EXTENSION
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let reply = NSExtensionItem()
        reply.userInfo = [SFExtensionMessageKey: save(message)]
        context.completeRequest(returningItems: [reply], completionHandler: nil)
    }

    private func save(_ message: [String: Any]?) -> [String: Any] {
        guard Self.isEnabled, let inbox = SharedInbox.forAppGroup() else {
            return ["saved": false, "reason": "Saving from Safari needs sharing turned on (SHARE_EXTENSION)."]
        }
        guard let address = message?["url"] as? String, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return ["saved": false, "reason": "This page can’t be saved."]
        }
        let title = (message?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var entry = SharedEntry(kind: .link, title: title, url: url.absoluteString)
        // From the button's menu: Save to Stash as PDF, and so on.
        entry.saveAs = (message?["format"] as? String).flatMap(PageFormat.init(rawValue:)).map(\.rawValue)
        do {
            try inbox.add(entry)
            ShareSignal.post()
            return ["saved": true]
        } catch {
            return ["saved": false, "reason": error.localizedDescription]
        }
    }
}
