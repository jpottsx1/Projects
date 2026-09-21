import SwiftUI
import AppKit

/// The logo, full-screen over the window, for the first five seconds.
///
/// Five seconds is long enough to read as an intentional greeting rather
/// than a flash of the wrong window, and short enough not to make Jeff
/// wait to get to his library.
struct SplashView: View {
    let onFinished: () -> Void

    private static let duration: Duration = .seconds(5)

    private var logo: NSImage? {
        Bundle.module.url(forResource: "SplashLogo", withExtension: "jpg")
            .flatMap(NSImage.init(contentsOf:))
    }

    var body: some View {
        ZStack {
            Color.black
            if let logo {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(80)
            }
        }
        .ignoresSafeArea()
        .task {
            try? await Task.sleep(for: Self.duration)
            onFinished()
        }
    }
}
