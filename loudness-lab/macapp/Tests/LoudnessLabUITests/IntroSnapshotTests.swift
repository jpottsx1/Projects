import XCTest
import SwiftUI
import AppKit
@testable import LoudnessLabUI

/// Draws the Intro tab in a few states and writes PNGs, so the layout can be
/// looked at. Off unless `LOUDNESSLAB_SNAPSHOT_DIR` names a folder: it needs
/// a window server, and a picture is not an assertion.
@MainActor
final class IntroSnapshotTests: XCTestCase {

    private func ticked(_ names: [String]) -> [Queue.Item] {
        names.map { Queue.Item(path: "/m/\($0).mp3", name: $0, folder: "Music") }
    }

    private func draw(_ view: some View, named name: String, in dir: String,
                      size: CGSize = CGSize(width: 560, height: 760)) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        // A window made in code is released when closed by default, and ARC
        // releases it again: a double free that shows up as a segfault as
        // the test ends, long after the pictures were written.
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        window.contentView = nil
        window.close()
    }

    func testSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["LOUDNESSLAB_SNAPSHOT_DIR"] else {
            throw XCTSkip("set LOUDNESSLAB_SNAPSHOT_DIR to draw the Intro tab")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let items = ticked(["Rock With You", "Lost In Music", "Do You Love Me"])

        let empty = IntroEngine()
        try draw(IntroPanel(engine: empty, ticked: []), named: "1-nothing-ticked", in: dir)

        let fresh = IntroEngine()
        try draw(IntroPanel(engine: fresh, ticked: items), named: "2-ticked", in: dir)

        let working = IntroEngine()
        working.seedForSnapshot(track: nil, busy: "Separating into stems… about half a minute.")
        try draw(IntroPanel(engine: working, ticked: items), named: "3-separating", in: dir)

        let track = IntroEngine.Track(
            path: "/m/Rock With You.mp3", name: "Rock With You.mp3", seconds: 220,
            bpm: 114.75, joinSeconds: 0.14, pickupSeconds: 0.0,
            downbeatFrom: "the song's start (the accents are even)", barsAfterJoin: 100,
            warnings: ["which beat is the bar's first was a guess from the song's start; check the join by ear"])
        let sources = [
            IntroSource(bar: 4, seconds: 8.5, vocalDB: -120, vocalFree: true, repeatScore: 0.89, snapped: true),
            IntroSource(bar: 8, seconds: 16.9, vocalDB: -12.1, vocalFree: false, repeatScore: 0.76, snapped: true),
            IntroSource(bar: 28, seconds: 58.8, vocalDB: -13.0, vocalFree: false, repeatScore: 0.55, snapped: false),
        ]
        let render = IntroEngine.Render(
            url: URL(fileURLWithPath: "/m/Intro Edits/Rock With You (Intro 16).mp3"),
            bars: 16, loopBars: 4, joinSeconds: 33.5, introSeconds: 33.49, sourceBar: 4,
            sourceSeconds: 8.5, vocalDB: nil, vocalFree: true, repeatScore: 0.89,
            warnings: ["these bars do not repeat in the record (match 0.55): a build or a fill, so the seams may not land on the beat"])
        let ready = IntroEngine()
        ready.seedForSnapshot(track: track, sources: sources, renders: [render])
        try draw(IntroPanel(engine: ready, ticked: items), named: "4-ready-and-made", in: dir,
                 size: CGSize(width: 560, height: 1000))

        let batch = IntroEngine()
        batch.seedForSnapshot(track: nil, busy: "Working through 3 tracks…",
                              batch: IntroEngine.Batch(index: 2, total: 3, name: "Lost In Music.mp3",
                                                       finished: [render], failures: ["Bad.flac: decoded to empty audio"]),
                              failure: nil)
        try draw(IntroPanel(engine: batch, ticked: items), named: "5-batch", in: dir)
    }
}
