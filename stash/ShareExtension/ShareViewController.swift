import SwiftUI

// What the share sheet opens. The system creates it by the class name given
// in Config/ShareExtension-Info.plist, so the name must stay as it is.

#if os(iOS)
import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: ShareModel(context: extensionContext)))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}
#else
import AppKit

final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSHostingView(rootView: ShareView(model: ShareModel(context: extensionContext))
            .frame(width: 440, height: 420))
    }
}
#endif
