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
    private let introFocus: URL?

    /// - Parameters:
    ///   - folders: folders to scan on appear. Empty leaves the view as the
    ///     standalone app opens it, with nothing chosen.
    ///   - include: paths to tick once the queue has scanned. Nil leaves the
    ///     queue's own default, which is everything it found.
    ///   - showsSplash: the standalone app's splash. Off by default,
    ///     because a splash screen inside another app's tab is a mistake.
    ///   - introFocus: open on the Intro tab with this track selected, for a
    ///     host whose "make an intro edit" action is what created the view.
    ///     (A view that already exists is told with `LoudnessLab.showIntro`;
    ///     a notification posted before it exists is simply lost.)
    public init(
        folders: [URL] = [],
        include: Set<String>? = nil,
        showsSplash: Bool = false,
        introFocus: URL? = nil
    ) {
        self.folders = folders
        self.include = include
        self.showsSplash = showsSplash
        self.introFocus = introFocus
    }

    @State private var splashVisible: Bool?

    public var body: some View {
        ZStack {
            ContentView(initialFolders: folders, initialInclude: include,
                        initialIntroFocus: introFocus)
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
    /// Posted by `LoudnessLab.addSources`, carrying `[URL]` as `object`.
    public static let loudnessLabAddSources = Notification.Name("loudnesslab.addSources")
    /// Posted by `LoudnessLab.showIntro`: switches the right pane to Intro.
    public static let loudnessLabShowIntro = Notification.Name("loudnesslab.showIntro")
    /// Posted by `LoudnessLab.togglePreview`: play or stop the queue's highlighted track.
    public static let loudnessLabTogglePreview = Notification.Name("loudnesslab.togglePreview")
    /// Posted by `LoudnessLab.skipPreview`, carrying seconds (`Double`) as `object`.
    public static let loudnessLabSkipPreview = Notification.Name("loudnesslab.skipPreview")
    /// Posted by `LoudnessLab.moveHighlight`, carrying `Int` (+1/-1) as `object`.
    public static let loudnessLabMoveHighlight = Notification.Name("loudnesslab.moveHighlight")
}

/// Commands a host can send into an already-embedded `LoudnessLabView`,
/// once it is showing and its queue already holds something of its own.
public enum LoudnessLab {
    /// Makes the queue list exactly the given files, ticked: the tracks a
    /// host means, not the whole folder with some of it ticked. Files the
    /// queue does not hold yet are added. Unlike handing `include` to a fresh
    /// `LoudnessLabView`, this leaves the survey and A/B player exactly as
    /// they are -- for a host that already has the view open.
    public static func addSources(_ urls: [URL]) {
        NotificationCenter.default.post(name: .loudnessLabAddSources, object: urls)
    }

    /// The help page that ships in this library's bundle, for a host that
    /// wants to open it in a browser. Public because the resource belongs to
    /// this module: `Bundle.module` is not reachable from the app target.
    public static var helpPageURL: URL? {
        Bundle.module.url(forResource: "loudness-lab", withExtension: "html",
                          subdirectory: "Help")
    }

    /// Space bar for a host that owns the keyboard: previews the highlighted
    /// track in the queue (the first one if none is), or stops it.
    public static func togglePreview() {
        NotificationCenter.default.post(name: .loudnessLabTogglePreview, object: nil)
    }

    /// Jumps the running preview ahead by `seconds`, clamped to the track's end.
    public static func skipPreview(by seconds: Double = 30) {
        NotificationCenter.default.post(name: .loudnessLabSkipPreview, object: seconds)
    }

    /// Moves the queue's highlight for a host that has claimed the arrow keys.
    public static func moveHighlight(by step: Int) {
        NotificationCenter.default.post(name: .loudnessLabMoveHighlight, object: step)
    }

    /// Shows the Intro tab, which makes intro edits from the ticked tracks.
    /// A host pairs it with `addSources` to say "make intros for these".
    /// `focus` is the track the tab should have selected, which is not
    /// necessarily the first ticked one: someone who right-clicked one song
    /// means that song.
    public static func showIntro(focus: URL? = nil) {
        NotificationCenter.default.post(name: .loudnessLabShowIntro, object: focus)
    }
}
