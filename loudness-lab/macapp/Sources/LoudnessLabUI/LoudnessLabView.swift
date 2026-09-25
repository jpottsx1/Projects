import SwiftUI

/// Loudness Lab's whole interface, as one view another app can place.
///
/// This exists so the app is EMBEDDED rather than reimplemented. DiscoTags
/// grew a Loudness tab, and the alternative was rebuilding the three panes,
/// the queue, the survey, the A/B player and the settings against
/// `LoudnessKit` — a second front end to the same tool, with its own bugs
/// and its own drift, and a second place to fix anything wrong with either.
/// Everything here is the same code the standalone app runs; the standalone
/// app is now a window around this view and nothing else.
///
/// The host can hand it a starting point. `folders` seeds the folders the
/// queue scans, and `include` ticks exactly those paths once the scan
/// lands — which is how a library app says "work on what I have selected"
/// without the person picking the same folder again in a second file
/// dialog.
public struct LoudnessLabView: View {
    private let folders: [URL]
    private let include: Set<String>?
    private let showsSplash: Bool

    /// - Parameters:
    ///   - folders: folders to scan on appear. Empty leaves the view as the
    ///     standalone app opens it, with nothing chosen.
    ///   - include: paths to tick once the queue has scanned. Nil leaves the
    ///     queue's own default, which is everything it found.
    ///   - showsSplash: the standalone app's splash. Off by default,
    ///     because a splash screen inside another app's tab is a mistake.
    public init(
        folders: [URL] = [],
        include: Set<String>? = nil,
        showsSplash: Bool = false
    ) {
        self.folders = folders
        self.include = include
        self.showsSplash = showsSplash
    }

    @State private var splashVisible: Bool?

    public var body: some View {
        ZStack {
            ContentView(initialFolders: folders, initialInclude: include)
            if splashVisible ?? showsSplash {
                SplashView { splashVisible = false }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.4), value: splashVisible ?? showsSplash)
    }
}

/// The help window's contents, so the standalone app can put it in a
/// `Window` scene and a host can present it however it likes.
public struct LoudnessLabHelpView: View {
    public init() {}
    public var body: some View { HelpView() }
}

/// The commands the interface listens for.
///
/// Posted rather than called because the menu bar belongs to whichever app
/// is hosting: the standalone app wires them to ⇧space and ⌘?, and a host
/// that has its own menu can post the same notifications from wherever it
/// likes. They live here, with the views that receive them, rather than in
/// the app that happens to send them.
extension Notification.Name {
    public static let switchVersion = Notification.Name("loudnesslab.switchVersion")
    public static let showHelp = Notification.Name("loudnesslab.showHelp")
}
