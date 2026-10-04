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

        // A song with a soft 25-second opening, then a groove with a kick on
        // every beat: what the picker exists to show.
        let bpm = 104.0, barLength = 4 * 60 / bpm, firstBar = 2.3
        let barSeconds = (0...94).map { firstBar + Double($0) * barLength }
        let perSecond = 50.0, seconds = 220.0
        var bass = [UInt8](), mid = [UInt8](), treble = [UInt8]()
        for i in 0..<Int(seconds * perSecond) {
            let t = Double(i) / perSecond
            if t < 25.6 {
                bass.append(UInt8(18 + 10 * sin(t * 0.7) + 10)); mid.append(UInt8(60 + 25 * sin(t * 1.3)))
                treble.append(UInt8(25 + 10 * sin(t * 2.1)))
            } else {
                let beat = (t - firstBar) / (60 / bpm), phase = beat - beat.rounded(.down)
                let kick = exp(-phase * 7)
                bass.append(UInt8(min(255, 70 + 185 * kick))); mid.append(UInt8(110 + 50 * sin(t * 9)))
                treble.append(UInt8(70 + 60 * (phase < 0.5 ? exp(-phase * 14) : 0.25)))
            }
        }
        let envelope = JoinEnvelope(perSecond: perSecond, seconds: seconds,
                                    bass: bass, mid: mid, treble: treble)
        let track = IntroEngine.Track(
            path: "/m/Ain't Nobody.mp3", name: "Ain't Nobody.mp3", seconds: seconds,
            bpm: bpm, joinSeconds: barSeconds[10], pickupSeconds: 0.9,
            downbeatFrom: "the song's start (the accents are even)", barsAfterJoin: 94,
            warnings: ["which beat is the bar's first was a guess from the song's start; check the join by ear"],
            barSeconds: barSeconds, suggestedJoinBar: 10,
            joinReason: "the drums come in at bar 10 (25.6 s in); the opening before it is replaced")
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
        ready.seedForSnapshot(track: track, sources: sources, renders: [render],
                              envelope: envelope, joinBar: 10)
        try draw(IntroPanel(engine: ready, ticked: items), named: "4-ready-and-made", in: dir,
                 size: CGSize(width: 560, height: 1300))

        // The same track with the join moved off the suggestion, to see the
        // orange marker for where the tool thought it should go.
        let moved = IntroEngine()
        moved.seedForSnapshot(track: track, sources: sources, envelope: envelope, joinBar: 14)
        try draw(IntroPanel(engine: moved, ticked: items), named: "6-join-moved", in: dir,
                 size: CGSize(width: 560, height: 1050))

        let batch = IntroEngine()
        batch.seedForSnapshot(track: nil, busy: "Working through 3 tracks…",
                              batch: IntroEngine.Batch(index: 2, total: 3, name: "Lost In Music.mp3",
                                                       finished: [render], failures: ["Bad.flac: decoded to empty audio"]),
                              failure: nil)
        try draw(IntroPanel(engine: batch, ticked: items), named: "5-batch", in: dir)
    }
}
