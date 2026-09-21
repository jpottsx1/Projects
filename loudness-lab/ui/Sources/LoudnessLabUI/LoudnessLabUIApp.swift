import SwiftUI

@main
struct LoudnessLabUIApp: App {
    var body: some Scene {
        WindowGroup("Loudness Lab") {
            ContentView()
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Compare") {
                Button("Switch version") {
                    NotificationCenter.default.post(name: .switchVersion, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [.shift])
            }
        }
    }
}

extension Notification.Name {
    static let switchVersion = Notification.Name("loudnesslab.switchVersion")
}
