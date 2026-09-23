import SwiftUI
import AppKit

/// Without this the window does not come to the front, and may not appear
/// at all.
///
/// `swift run` produces a bare executable with no bundle and no Info.plist,
/// so macOS has nothing telling it this process owns windows. It launches
/// as a background process: no Dock icon, no menu bar, and the window --
/// built, laid out and live -- opens behind whatever is already on screen.
/// The fix is two lines, and it is worth keeping even once the app is
/// bundled, because running it straight from the package is the fastest way
/// to see a change.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// One window, one job. Leaving the process running with nothing on
    /// screen would leave audio nodes holding the output device.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct LoudnessLabUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var showingSplash = true

    var body: some Scene {
        WindowGroup("Loudness Lab") {
            ZStack {
                ContentView()
                    // Three panes: what to do, what to do it to, what came out.
                    .frame(minWidth: 1120, minHeight: 640)

                if showingSplash {
                    SplashView { showingSplash = false }
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.4), value: showingSplash)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Compare") {
                Button("Switch version") {
                    NotificationCenter.default.post(name: .switchVersion, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [.shift])
            }
            // Routed through a notification rather than opening the window
            // from here. `openWindow` is read from the environment, which a
            // view has and a menu builder does not reliably; ContentView
            // already receives the switch command this way, so the path is
            // one that is known to work.
            CommandGroup(replacing: .help) {
                Button("Loudness Lab Help") {
                    NotificationCenter.default.post(name: .showHelp, object: nil)
                }
                .keyboardShortcut("?", modifiers: [.command])

                // The same document, in a browser: printable, searchable
                // with the browser's own find, and readable with the app
                // closed. It is the file that ships in the bundle, so the
                // two cannot say different things.
                Button("Open the Help Page in a Browser") {
                    if let url = Bundle.module.url(forResource: "loudness-lab",
                                                   withExtension: "html",
                                                   subdirectory: "Help") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        // A window rather than a sheet: the whole point is to read it WHILE
        // setting something, which a modal would prevent.
        Window("Loudness Lab Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 560, height: 680)
    }
}

extension Notification.Name {
    static let switchVersion = Notification.Name("loudnesslab.switchVersion")
    static let showHelp = Notification.Name("loudnesslab.showHelp")
}
