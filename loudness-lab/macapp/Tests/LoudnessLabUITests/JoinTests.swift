import XCTest
@testable import LoudnessLabUI

final class JoinMathTests: XCTestCase {

    /// Bar lines every 2 s from 0.5: 0.5, 2.5, 4.5, ... 18.5 (10 of them, so
    /// the song can arrive at bars 0...8: the last bar line has no bar after it).
    private let bars: [Double] = (0..<10).map { 0.5 + Double($0) * 2 }

    func testTheNearestBarLine() {
        XCTAssertEqual(JoinMath.nearestBar(to: 4.4, in: bars), 2)     // 4.5
        XCTAssertEqual(JoinMath.nearestBar(to: 3.4, in: bars), 1)     // 2.5, not 4.5
        XCTAssertEqual(JoinMath.nearestBar(to: 3.6, in: bars), 2)
        XCTAssertEqual(JoinMath.nearestBar(to: 2.5, in: bars), 1)     // exactly on one
    }

    func testBeforeTheFirstBarLineIsTheFirst() {
        XCTAssertEqual(JoinMath.nearestBar(to: -3, in: bars), 0)
        XCTAssertEqual(JoinMath.nearestBar(to: 0, in: bars), 0)
    }

    func testPastTheEndIsTheLastBarThatHasABarAfterIt() {
        XCTAssertEqual(JoinMath.nearestBar(to: 999, in: bars), 8)
        XCTAssertEqual(JoinMath.nearestBar(to: 18.5, in: bars), 8)    // the final line
    }

    func testTooFewBarLinesAreBarZero() {
        XCTAssertEqual(JoinMath.nearestBar(to: 5, in: []), 0)
        XCTAssertEqual(JoinMath.nearestBar(to: 5, in: [1.0]), 0)
    }

    func testClamping() {
        XCTAssertEqual(JoinMath.clamp(-4, in: bars), 0)
        XCTAssertEqual(JoinMath.clamp(5, in: bars), 5)
        XCTAssertEqual(JoinMath.clamp(40, in: bars), 8)
        XCTAssertEqual(JoinMath.clamp(3, in: []), 0)
    }

    func testTheTimeOfABar() {
        XCTAssertEqual(JoinMath.seconds(ofBar: 3, in: bars), 6.5, accuracy: 1e-9)
        XCTAssertEqual(JoinMath.seconds(ofBar: -1, in: bars), 0.5, accuracy: 1e-9)
        XCTAssertEqual(JoinMath.seconds(ofBar: 99, in: bars), 18.5, accuracy: 1e-9)
        XCTAssertEqual(JoinMath.seconds(ofBar: 0, in: []), 0)
    }

    func testTheWindowFollowsTheCentreAndStaysInsideTheTrack() {
        let middle = JoinMath.window(center: 50, width: 20, total: 100)
        XCTAssertEqual(middle.lowerBound, 40, accuracy: 1e-9)
        XCTAssertEqual(middle.upperBound, 60, accuracy: 1e-9)
        // Near either end it slides rather than shrinking.
        let start = JoinMath.window(center: 2, width: 20, total: 100)
        XCTAssertEqual(start.lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(start.upperBound, 20, accuracy: 1e-9)
        let end = JoinMath.window(center: 99, width: 20, total: 100)
        XCTAssertEqual(end.lowerBound, 80, accuracy: 1e-9)
        XCTAssertEqual(end.upperBound, 100, accuracy: 1e-9)
        // A track shorter than the window is shown whole.
        let short = JoinMath.window(center: 3, width: 20, total: 8)
        XCTAssertEqual(short.lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(short.upperBound, 8, accuracy: 1e-9)
    }

    func testPixelsAndSecondsAreInversesOfEachOther() {
        let window = 40.0...60.0
        for seconds in [40.0, 47.25, 55.5, 60.0] {
            let x = JoinMath.x(for: seconds, in: window, width: 400)
            XCTAssertEqual(JoinMath.seconds(forX: x, in: window, width: 400), seconds, accuracy: 1e-9)
        }
        XCTAssertEqual(JoinMath.x(for: 50, in: window, width: 400), 200, accuracy: 1e-9)
    }

    func testAClickLandsOnTheBarLineNearestIt() {
        // 20 s across 400 pt: 20 pt a second. A click at x=210 is 50.5 s,
        // nearest the bar line at 50.5 in this layout.
        let layout: [Double] = (0..<20).map { 40.5 + Double($0) * 2 }       // 40.5, 42.5, ...
        let seconds = JoinMath.seconds(forX: 210, in: 40.0...60.0, width: 400)
        XCTAssertEqual(JoinMath.seconds(ofBar: JoinMath.nearestBar(to: seconds, in: layout), in: layout),
                       50.5, accuracy: 1e-9)
    }

    func testReadingATimeOff() {
        XCTAssertEqual(JoinMath.clock(0), "0:00.0")
        XCTAssertEqual(JoinMath.clock(25.6), "0:25.6")
        XCTAssertEqual(JoinMath.clock(85.64), "1:25.6")
        XCTAssertEqual(JoinMath.clock(-3), "0:00.0")
    }
}

final class JoinEnvelopeTests: XCTestCase {

    func testTheRealEnvelopeDecodes() throws {
        let event = try XCTUnwrap(IntroEvent(RealJoin.envelope))
        let envelope = try XCTUnwrap(JoinEnvelope(event: event))
        XCTAssertEqual(envelope.perSecond, 5, accuracy: 1e-9)
        XCTAssertEqual(envelope.seconds, 30, accuracy: 1e-6)
        XCTAssertEqual(envelope.columns, 150)
        XCTAssertEqual(envelope.mid.count, 150)
        XCTAssertEqual(envelope.treble.count, 150)
    }

    /// The soft opening against the groove, in the real data: the whole point
    /// of drawing it is that the drop is visible.
    func testTheDropIsVisibleInTheRealBassBand() throws {
        let event = try XCTUnwrap(IntroEvent(RealJoin.envelope))
        let envelope = try XCTUnwrap(JoinEnvelope(event: event))
        let opening = envelope.peak(envelope.bass, from: 1, to: 7)       // bars 0-3: the pad
        let groove = envelope.peak(envelope.bass, from: 10, to: 20)      // the groove
        XCTAssertGreaterThan(groove, 3 * max(opening, 0.01))
    }

    func testAnEnvelopeNeedsAllThreeBandsOfOneLength() throws {
        func event(_ json: String) throws -> IntroEvent { try XCTUnwrap(IntroEvent(json)) }
        XCTAssertNil(JoinEnvelope(event: try event(#"{"event":"envelope","per_second":5}"#)))
        XCTAssertNil(JoinEnvelope(event: try event(
            #"{"event":"envelope","per_second":5,"bass":[1,2],"mid":[1],"treble":[1,2]}"#)))
        XCTAssertNil(JoinEnvelope(event: try event(
            #"{"event":"envelope","per_second":0,"bass":[1],"mid":[1],"treble":[1]}"#)))
        XCTAssertNotNil(JoinEnvelope(event: try event(
            #"{"event":"envelope","per_second":5,"bass":[1,2],"mid":[1,2],"treble":[1,2]}"#)))
    }

    func testAPeakIsTheLargestValueNotTheMean() {
        let envelope = JoinEnvelope(perSecond: 10, seconds: 1,
                                    bass: [0, 0, 255, 0, 0, 0, 0, 0, 0, 0],
                                    mid: Array(repeating: 0, count: 10),
                                    treble: Array(repeating: 0, count: 10))
        // A one-column kick inside a wide span must still show at full height.
        XCTAssertEqual(envelope.peak(envelope.bass, from: 0, to: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(envelope.peak(envelope.bass, from: 0.5, to: 1), 0, accuracy: 1e-6)
    }

    func testPeaksOutsideTheTrackAreClampedNotACrash() {
        let envelope = JoinEnvelope(perSecond: 10, seconds: 1, bass: [10, 20, 30],
                                    mid: [0, 0, 0], treble: [0, 0, 0])
        XCTAssertEqual(envelope.peak(envelope.bass, from: -5, to: 100), 30 / 255, accuracy: 1e-6)
        XCTAssertEqual(envelope.peak([], from: 0, to: 1), 0)
    }
}

final class JoinEventTests: XCTestCase {

    func testPreparedCarriesTheSuggestedJoinAndEveryBarLine() throws {
        let e = try XCTUnwrap(IntroEvent(RealJoin.prepared))
        XCTAssertEqual(e.suggestedJoinBar, 4)
        XCTAssertEqual(e.barSeconds?.count, 15)
        XCTAssertEqual(e.barSeconds?.first ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(e.barSeconds?[4] ?? 0, 8, accuracy: 0.02)          // the drop
        XCTAssertEqual(e.firstBarSeconds ?? -1, 0, accuracy: 0.01)
        XCTAssertTrue(e.joinReason?.contains("drums come in") ?? false)
        XCTAssertEqual(e.pickupSeconds ?? 0, 1.0, accuracy: 0.05)         // the kept vocal lead-in
    }

    func testARenderReportsWhereTheSongArrivedAndWhatWasCut() throws {
        let e = try XCTUnwrap(IntroEvent(RealJoin.intro))
        let render = try XCTUnwrap(IntroEngine.render(from: e))
        XCTAssertEqual(render.joinBar, 5)
        XCTAssertEqual(render.cutSeconds, 10, accuracy: 0.05)
        // Where the song begins IN THE FILE is the intro, not where it was
        // in the original: the two are easy to confuse.
        XCTAssertEqual(render.joinSeconds, 16.01, accuracy: 0.01)
    }
}

/// The engine's handling of the join, against a stand-in for the tool that
/// replays the real lines above and echoes the join it was asked for.
@MainActor
final class IntroEngineJoinTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("join-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// A stand-in for the tool that replays the real lines and keeps just
    /// enough state to be forgetful: it holds the track from a `prepare` until
    /// told to forget (a `forget` file appears, as an idle session lets go),
    /// answers `no_track` while it holds nothing, and logs each `prepare`.
    /// With a `stuck` file it never holds one at all (a broken tool).
    private func fakeTool(envelopeFails: Bool = false) throws -> URL {
        let lines = ["prepared": RealJoin.prepared, "sources": RealJoin.sources,
                     "envelope": RealJoin.envelope, "intro": RealJoin.intro]
        try JSONSerialization.data(withJSONObject: lines).write(
            to: directory.appendingPathComponent("lines.json"))
        let script = """
        #!/usr/bin/env python3
        import json, sys, os
        here = os.path.dirname(os.path.abspath(__file__))
        canned = {k: json.loads(v) for k, v in json.load(open(os.path.join(here, "lines.json"))).items()}
        by = {"prepare": "prepared", "sources": "sources", "envelope": "envelope", "render": "intro"}
        held = False
        for raw in sys.stdin:
            request = json.loads(raw)
            rid, cmd = request["id"], request["cmd"]
            forget = os.path.join(here, "forget")
            if os.path.exists(forget):
                os.remove(forget); held = False
            if cmd == "prepare":
                open(os.path.join(here, "prepares.log"), "a").write(request["path"] + "\\n")
                held = not os.path.exists(os.path.join(here, "stuck"))
            elif not held:
                print(json.dumps({"event": "error", "id": rid, "code": "no_track",
                                  "message": "no track is prepared: send `prepare` first"}), flush=True)
                continue
            if cmd == "envelope" and \(envelopeFails ? "True" : "False"):
                print(json.dumps({"event": "error", "id": rid, "message": "no picture today"}), flush=True)
                continue
            if cmd == "rephase":
                open(os.path.join(here, "rephases.log"), "a").write(str(request["beats"]) + "\\n")
                event = dict(canned["prepared"]); event["event"] = "grid"; event["id"] = rid
                event["bar_seconds"] = [t + 0.5 * request["beats"] for t in event["bar_seconds"]]
                event["downbeat_from"] = "set by hand"; event["suggested_join_bar"] = 2
                print(json.dumps(event), flush=True)
                print(json.dumps({"event": "done", "id": rid}), flush=True)
                continue
            event = dict(canned[by[cmd]]); event["id"] = rid
            if cmd == "render":
                event["join_bar"] = request.get("join_bar")      # echo what it was asked for
                if request.get("lead_in") == "auto":
                    event["lead_in_bar"] = 5; event["lead_in_seconds"] = 11.2
            print(json.dumps(event), flush=True)
            print(json.dumps({"event": "done", "id": rid}), flush=True)
        """
        let url = directory.appendingPathComponent("loudness-lab")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func touch(_ name: String) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
    }

    private var prepareCount: Int {
        (try? String(contentsOf: directory.appendingPathComponent("prepares.log"), encoding: .utf8))?
            .split(separator: "\n").count ?? 0
    }

    private var rephases: [String] {
        (try? String(contentsOf: directory.appendingPathComponent("rephases.log"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    func testMovingBeatOneRelaysTheBarLinesAndOffersANewJoin() async throws {
        let engine = IntroEngine(tool: try fakeTool())
        await engine.prepare("/tmp/x/Song.flac")
        let before = engine.track!.barSeconds
        await engine.moveBeatOne(by: 1)
        XCTAssertNil(engine.failure)
        XCTAssertEqual(engine.track?.barSeconds.first ?? 0, before[0] + 0.5, accuracy: 1e-9)
        XCTAssertEqual(engine.track?.downbeatFrom, "set by hand")
        XCTAssertEqual(engine.beatShift, 1)
        XCTAssertEqual(engine.joinBar, 2)                       // the new suggestion
        engine.reset()
    }

    func testTheBeatShiftWrapsAroundTheBar() async throws {
        let engine = IntroEngine(tool: try fakeTool())
        await engine.prepare("/tmp/x/Song.flac")
        await engine.moveBeatOne(by: -1)
        XCTAssertEqual(engine.beatShift, 3)
        await engine.moveBeatOne(by: 1)
        XCTAssertEqual(engine.beatShift, 0)
        engine.reset()
    }

    func testAReloadedTrackKeepsTheBeatItWasMovedTo() async throws {
        let tool = try fakeTool()
        let engine = IntroEngine(tool: tool)
        await engine.prepare("/tmp/x/Song.flac")
        await engine.moveBeatOne(by: 1)
        touch("forget")                                     // the idle session let go
        await engine.loadSources()
        XCTAssertNil(engine.failure)
        XCTAssertEqual(prepareCount, 2)
        XCTAssertEqual(rephases, ["1", "1"])                // moved, then put back
        engine.reset()
    }

    func testPreparingStartsOnTheSuggestedJoinWithItsPicture() async throws {
        let engine = IntroEngine(tool: try fakeTool())
        await engine.prepare("/tmp/x/Song.flac")
        XCTAssertNil(engine.failure)
        XCTAssertEqual(engine.track?.suggestedJoinBar, 4)
        XCTAssertEqual(engine.joinBar, 4)
        XCTAssertEqual(engine.track?.barSeconds.count, 15)
        XCTAssertEqual(engine.track?.lastJoinBar, 13)         // 14 bars, so 0...13
        XCTAssertEqual(engine.envelope?.columns, 150)
        engine.reset()
    }

    func testEndingOnTheSongsBreakIsAskedForOnlyWhenChosen() async throws {
        let engine = IntroEngine(tool: try fakeTool())
        await engine.prepare("/tmp/x/Song.flac")
        await engine.render(to: nil)
        XCTAssertNil(engine.renders.first?.leadInBar)            // off by default
        engine.endOnBreak = true
        await engine.render(to: nil)
        XCTAssertEqual(engine.renders.first?.leadInBar, 5)
        XCTAssertEqual(engine.renders.first?.leadInSeconds, 11.2)
        engine.reset()
    }

    func testTheChosenJoinIsWhatGetsRendered() async throws {
        let engine = IntroEngine(tool: try fakeTool())
        await engine.prepare("/tmp/x/Song.flac")
        engine.joinBar = 7
        await engine.render(to: nil)
        XCTAssertNil(engine.failure)
        // The stand-in echoes the join it was sent, so this is what went out.
        XCTAssertEqual(engine.renders.first?.joinBar, 7)
        engine.reset()
    }

    func testMovingTheJoinDoesNotMoveTheSuggestion() async throws {
        let engine = IntroEngine(tool: try fakeTool())
        await engine.prepare("/tmp/x/Song.flac")
        engine.joinBar = 9
        XCTAssertEqual(engine.track?.suggestedJoinBar, 4)
        engine.reset()
    }

    func testAnotherPrepareStartsOverOnItsOwnSuggestion() async throws {
        let engine = IntroEngine(tool: try fakeTool())
        await engine.prepare("/tmp/x/Song.flac")
        engine.joinBar = 9
        await engine.prepare("/tmp/x/Song.flac")
        XCTAssertEqual(engine.joinBar, 4, "a new track must not inherit the last one's join")
        engine.reset()
    }

    func testResettingForgetsTheJoinAndThePicture() async throws {
        let engine = IntroEngine(tool: try fakeTool())
        await engine.prepare("/tmp/x/Song.flac")
        engine.joinBar = 9
        engine.reset()
        XCTAssertNil(engine.envelope)
        XCTAssertEqual(engine.joinBar, 0)
        XCTAssertNil(engine.track)
    }

    func testWithoutThePictureThePickerStillWorks() async throws {
        let engine = IntroEngine(tool: try fakeTool(envelopeFails: true))
        await engine.prepare("/tmp/x/Song.flac")
        XCTAssertNil(engine.failure, "a missing picture is not a failed analysis")
        XCTAssertNil(engine.envelope)
        XCTAssertEqual(engine.track?.suggestedJoinBar, 4)
        XCTAssertEqual(engine.joinBar, 4)
        engine.joinBar = 6
        await engine.render(to: nil)
        XCTAssertEqual(engine.renders.first?.joinBar, 6)
        engine.reset()
    }
    // MARK: - A session that let the track go

    func testATrackTheToolLetGoOfIsLoadedAgainAndTheRenderStillHappens() async throws {
        let engine = IntroEngine(tool: try fakeTool())
        await engine.prepare("/tmp/x/Song.flac")
        engine.joinBar = 7                                   // the person's choice
        XCTAssertEqual(prepareCount, 1)
        touch("forget")                                      // an idle session lets go
        await engine.render(to: nil)
        XCTAssertNil(engine.failure, "an idle session must cost a pause, not an error")
        XCTAssertEqual(prepareCount, 2, "the track was prepared again")
        XCTAssertEqual(engine.renders.first?.joinBar, 7, "and the render used the join they chose")
        XCTAssertEqual(engine.joinBar, 7, "reloading must not move it back to the suggestion")
        engine.reset()
    }

    func testTheSecondRequestAfterReloadingDoesNotLoadItAgain() async throws {
        let engine = IntroEngine(tool: try fakeTool())
        await engine.prepare("/tmp/x/Song.flac")
        touch("forget")
        await engine.render(to: nil)
        await engine.render(to: nil)
        XCTAssertEqual(prepareCount, 2)
        engine.reset()
    }

    func testReloadingTheTrackReloadsTheTrackThatWasAnalysed() async throws {
        let engine = IntroEngine(tool: try fakeTool())
        await engine.prepare("/tmp/x/Song.flac")
        touch("forget")
        await engine.loadSources()
        let log = try String(contentsOf: directory.appendingPathComponent("prepares.log"), encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").map(String.init),
                       ["/tmp/x/Song.flac", "/tmp/x/Song.flac"])
        engine.reset()
    }

    func testAToolThatNeverHoldsTheTrackIsReportedNotLoopedOn() async throws {
        let engine = IntroEngine(tool: try fakeTool())
        await engine.prepare("/tmp/x/Song.flac")
        touch("stuck")                                       // from now on, prepare does not stick
        touch("forget")
        await engine.render(to: nil)
        XCTAssertNotNil(engine.failure)
        XCTAssertEqual(prepareCount, 2, "one retry, then give up; never a loop")
        engine.reset()
    }
}

final class PlayheadMathTests: XCTestCase {
    // A render whose intro is 20 s long, replacing the first 30 s of the original.
    func testTheIntroSweepsTheReplacedStretch() {
        XCTAssertEqual(JoinMath.playhead(atFileTime: 0, songArrivesAt: 20, cutSeconds: 30), 0, accuracy: 1e-9)
        XCTAssertEqual(JoinMath.playhead(atFileTime: 10, songArrivesAt: 20, cutSeconds: 30), 15, accuracy: 1e-9)
    }

    func testAfterTheJoinItFollowsTheSong() {
        XCTAssertEqual(JoinMath.playhead(atFileTime: 20, songArrivesAt: 20, cutSeconds: 30), 30, accuracy: 1e-9)
        XCTAssertEqual(JoinMath.playhead(atFileTime: 25, songArrivesAt: 20, cutSeconds: 30), 35, accuracy: 1e-9)
    }

    func testNoIntroIsJustTheSongFromTheCut() {
        XCTAssertEqual(JoinMath.playhead(atFileTime: 4, songArrivesAt: 0, cutSeconds: 30), 34, accuracy: 1e-9)
    }
}

@MainActor
final class QueueAdoptTests: XCTestCase {
    func testAFileOutsideEveryScannedFolderIsAddedAndTicked() {
        let queue = Queue()
        queue.adopt([URL(fileURLWithPath: "/Volumes/Crate/Song One.mp3")])
        XCTAssertEqual(queue.items.map(\.path), ["/Volumes/Crate/Song One.mp3"])
        XCTAssertEqual(queue.items.first?.name, "Song One")
        XCTAssertTrue(queue.items.first?.included ?? false)
    }

    func testAskingTwiceDoesNotDuplicate() {
        let queue = Queue()
        let url = URL(fileURLWithPath: "/a/b.mp3")
        queue.adopt([url]); queue.adopt([url])
        XCTAssertEqual(queue.items.count, 1)
    }

    func testARefreshWithNoFoldersKeepsThem() async {
        let queue = Queue()
        queue.adopt([URL(fileURLWithPath: "/a/b.mp3")])
        await queue.refresh(folders: [], databaseURL: URL(fileURLWithPath: "/nonexistent.db"))
        XCTAssertEqual(queue.items.map(\.path), ["/a/b.mp3"])
    }
}

@MainActor
final class MadeListTests: XCTestCase {
    private func render(_ name: String) -> IntroEngine.Render {
        IntroEngine.Render(url: URL(fileURLWithPath: "/m/\(name).mp3"), bars: 16, loopBars: 4,
                           joinSeconds: 30, introSeconds: 30, sourceBar: 4, sourceSeconds: 8,
                           vocalDB: nil, vocalFree: true, repeatScore: 0.9, warnings: [])
    }

    func testForgettingTheMadeEditsEmptiesTheList() {
        let engine = IntroEngine()
        engine.seedForSnapshot(track: nil, renders: [render("a"), render("b")])
        XCTAssertEqual(engine.renders.count, 2)
        engine.forgetMade()
        XCTAssertTrue(engine.renders.isEmpty)
    }
}
