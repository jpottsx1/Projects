import XCTest
@testable import LoudnessLabUI

/// The lines below are what `loudness-lab intro --serve` really wrote for a
/// small synthetic track (tests/test_intro.py builds it), not hand-made
/// look-alikes: a decoder tested against its own author's idea of the format
/// passes until the format is read for the first time.
private enum Real {
    static let prepared = #"{"event": "prepared", "id": 1, "path": "/tmp/x/Song.flac", "name": "Song.flac", "seconds": 50.0, "bpm": 120.023, "join_seconds": 0.136, "pickup_seconds": 0.5, "downbeat_from": "the accents in the low end", "grid_coherence": 0.999, "bars_after_join": 25, "warnings": ["a guess"]}"#
    static let sources = #"{"event": "sources", "id": 2, "loop_bars": 4, "sources": [{"bar": 4, "seconds": 8.0, "vocal_db": -120.0, "vocal_free": true, "repeat": 1.0, "snapped": true}, {"bar": 17, "seconds": 34.0, "vocal_db": -12.4, "vocal_free": false, "repeat": 0.55, "snapped": false}]}"#
    static let intro = #"{"event": "intro", "id": 3, "bpm": 120.0, "grid_bpm": 120.023, "loop_snapped": true, "loop_repeat": 1.0, "bars": 8, "loop_bars": 4, "seconds_of_intro": 16.0, "lead_seconds": 0.01, "join_seconds": 0.0, "pickup_seconds": 0.0, "source_bar": 4, "source_seconds": 8.0, "source_vocal_db": -120.0, "vocal_free": true, "grid_coherence": 0.999, "downbeat_from": "the accents in the low end", "warnings": [], "source": "/tmp/x/Song.flac", "output": "/tmp/x/o/Song (Intro 8).flac"}"#
    static let error = #"{"event": "error", "id": 4, "message": "bar 9999 with 4 bars runs past the end of the track (25 bars after the join)"}"#
    static let file = #"{"event": "file", "name": "Song.flac", "path": "/tmp/x/Song.flac", "index": 2, "total": 5}"#
    static let batchError = #"{"event": "error", "path": "/tmp/x/Bad.flac", "name": "Bad.flac", "message": "decoded to empty audio"}"#
}

final class IntroEventTests: XCTestCase {

    func testPreparedDecodes() throws {
        let e = try XCTUnwrap(IntroEvent(Real.prepared))
        XCTAssertEqual(e.event, "prepared")
        XCTAssertEqual(e.id, 1)
        XCTAssertEqual(e.bpm ?? 0, 120.023, accuracy: 1e-9)
        XCTAssertEqual(e.joinSeconds ?? 0, 0.136, accuracy: 1e-9)
        XCTAssertEqual(e.pickupSeconds ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(e.barsAfterJoin, 25)
        XCTAssertEqual(e.warnings, ["a guess"])
        XCTAssertEqual(e.downbeatFrom, "the accents in the low end")
    }

    func testSourcesDecodeWithTheirScores() throws {
        let e = try XCTUnwrap(IntroEvent(Real.sources))
        let sources = try XCTUnwrap(e.sources)
        XCTAssertEqual(sources.map(\.bar), [4, 17])
        XCTAssertTrue(sources[0].vocalFree)
        XCTAssertEqual(sources[0].repeatScore, 1.0, accuracy: 1e-9)
        XCTAssertFalse(sources[1].vocalFree)
        XCTAssertEqual(sources[1].vocalDB ?? 0, -12.4, accuracy: 1e-9)
        XCTAssertEqual(sources[1].repeatScore, 0.55, accuracy: 1e-9)
        XCTAssertFalse(sources[1].snapped)
    }

    func testARenderedIntroBecomesARender() throws {
        let e = try XCTUnwrap(IntroEvent(Real.intro))
        let render = try XCTUnwrap(IntroEngine.render(from: e))
        XCTAssertEqual(render.bars, 8)
        XCTAssertEqual(render.url.lastPathComponent, "Song (Intro 8).flac")
        XCTAssertEqual(render.name, "Song (Intro 8)")
        XCTAssertEqual(render.sourceBar, 4)
        XCTAssertTrue(render.vocalFree)
        XCTAssertEqual(render.repeatScore, 1.0, accuracy: 1e-9)
    }

    /// The join is where the song arrives. The file starts a few
    /// milliseconds early so the first kick is whole, and a listener sent to
    /// "the join" must be sent to the right place, not to where it would be
    /// without that.
    func testTheJoinIncludesTheLeadIn() throws {
        let e = try XCTUnwrap(IntroEvent(Real.intro))
        XCTAssertEqual(e.joinInOutput ?? 0, 16.01, accuracy: 1e-9)
        XCTAssertEqual(IntroEngine.render(from: e)?.joinSeconds ?? 0, 16.01, accuracy: 1e-9)
    }

    func testAnErrorCarriesItsMessage() throws {
        let e = try XCTUnwrap(IntroEvent(Real.error))
        XCTAssertEqual(e.event, "error")
        XCTAssertTrue(e.message?.contains("runs past the end") ?? false)
    }

    func testBatchEventsDecode() throws {
        let file = try XCTUnwrap(IntroEvent(Real.file))
        XCTAssertEqual(file.index, 2)
        XCTAssertEqual(file.total, 5)
        XCTAssertEqual(file.name, "Song.flac")
        let bad = try XCTUnwrap(IntroEvent(Real.batchError))
        XCTAssertNil(bad.id)
        XCTAssertEqual(bad.name, "Bad.flac")
    }

    func testAnEventItDoesNotKnowStillDecodes() throws {
        let e = try XCTUnwrap(IntroEvent(#"{"event": "something-new", "id": 7, "extra": [1,2]}"#))
        XCTAssertEqual(e.event, "something-new")
    }

    func testNonJSONIsNotAnEvent() {
        XCTAssertNil(IntroEvent("Traceback (most recent call last):"))
        XCTAssertNil(IntroEvent(""))
    }
}

/// The session, against a stand-in for `loudness-lab` that answers the way
/// the real one does: a request line in, its events out, `done` or `error`
/// last. What is tested is the plumbing -- ids matched, events collected,
/// errors thrown, a dead process reported -- not the audio.
final class IntroSessionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("intro-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A tool that replays canned lines. `die` as the command exits mid-request.
    private func fakeTool() throws -> URL {
        let canned = [Real.prepared, Real.sources, Real.intro, Real.error]
        try canned.joined(separator: "\n").write(
            to: directory.appendingPathComponent("lines.jsonl"), atomically: true, encoding: .utf8)
        let script = """
        #!/usr/bin/env python3
        import json, sys, os
        here = os.path.dirname(os.path.abspath(__file__))
        lines = [json.loads(l) for l in open(os.path.join(here, "lines.jsonl"))]
        by = {"prepare": ["prepared"], "sources": ["sources"], "render": ["intro"]}
        for raw in sys.stdin:
            request = json.loads(raw)
            rid, cmd = request["id"], request["cmd"]
            if cmd == "die":
                sys.stderr.write("Traceback: it fell over\\n")
                sys.exit(3)
            if cmd == "fail":
                event = dict(lines[3]); event["id"] = rid
                print(json.dumps(event), flush=True)
                continue
            print(json.dumps({"event": "stage", "id": rid, "stage": cmd}), flush=True)
            for event in lines:
                if event["event"] in by.get(cmd, []):
                    event = dict(event); event["id"] = rid
                    print(json.dumps(event), flush=True)
            print(json.dumps({"event": "done", "id": rid}), flush=True)
        """
        let url = directory.appendingPathComponent("loudness-lab")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testARequestReturnsItsEventsUpToDone() async throws {
        let session = IntroSession(tool: try fakeTool())
        defer { session.close() }
        let events = try await session.request("prepare", ["path": "/tmp/x/Song.flac"])
        XCTAssertEqual(events.map(\.event), ["stage", "prepared", "done"])
        XCTAssertEqual(events.first(where: { $0.event == "prepared" })?.name, "Song.flac")
    }

    func testRequestsAreAnsweredInTurnOnOneProcess() async throws {
        let session = IntroSession(tool: try fakeTool())
        defer { session.close() }
        _ = try await session.request("prepare")
        let sources = try await session.request("sources", ["loop_bars": 4])
        XCTAssertEqual(sources.compactMap(\.sources).first?.count, 2)
        let made = try await session.request("render", ["bars": 8])
        XCTAssertNotNil(made.first(where: { $0.event == "intro" })?.output)
        // Each reply carries its own request's id, not the first one's.
        XCTAssertEqual(Set(made.compactMap(\.id)).count, 1)
        XCTAssertNotEqual(made.first?.id, sources.first?.id)
    }

    func testStageEventsReachTheListenerAsTheyArrive() async throws {
        let session = IntroSession(tool: try fakeTool())
        defer { session.close() }
        let seen = Seen()
        _ = try await session.request("prepare", onEvent: { seen.add($0.event) })
        XCTAssertEqual(seen.all, ["stage", "prepared", "done"])
    }

    func testAnErrorEventIsThrownWithTheToolsOwnMessage() async throws {
        let session = IntroSession(tool: try fakeTool())
        defer { session.close() }
        do {
            _ = try await session.request("fail")
            XCTFail("an error event should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("runs past the end"),
                          error.localizedDescription)
        }
        // And the session is still good afterwards.
        let events = try await session.request("sources")
        XCTAssertEqual(events.last?.event, "done")
    }

    func testAProcessThatDiesMidRequestIsReportedWithItsStderr() async throws {
        let session = IntroSession(tool: try fakeTool())
        defer { session.close() }
        do {
            _ = try await session.request("die")
            XCTFail("a dead process should throw, not hang")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("exit 3"), message)
            XCTAssertTrue(message.contains("it fell over"), message)
        }
    }

    func testAfterItDiesTheNextRequestStartsAFreshProcess() async throws {
        let session = IntroSession(tool: try fakeTool())
        defer { session.close() }
        _ = try? await session.request("die")
        let events = try await session.request("prepare")
        XCTAssertEqual(events.last?.event, "done")
    }

    func testAMissingToolIsAnErrorNotAHang() async {
        let session = IntroSession(tool: directory.appendingPathComponent("nope"))
        do {
            _ = try await session.request("prepare")
            XCTFail("should have thrown")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not start"),
                          error.localizedDescription)
        }
    }

    /// The real tool, the real Demucs, a real file. Off unless pointed at one
    /// (`LOUDNESSLAB_E2E_FILE=/path/to/track.mp3 swift test --filter Real`),
    /// because it takes half a minute and needs the Python environment.
    func testRealToolEndToEnd() async throws {
        guard let file = ProcessInfo.processInfo.environment["LOUDNESSLAB_E2E_FILE"] else {
            throw XCTSkip("set LOUDNESSLAB_E2E_FILE to run against the real tool")
        }
        let tool = try XCTUnwrap(CLI.locate(), "loudness-lab not found")
        let session = IntroSession(tool: tool)
        defer { session.close() }
        let prepared = try await session.request("prepare", ["path": file])
        let info = try XCTUnwrap(prepared.first(where: { $0.event == "prepared" }))
        XCTAssertGreaterThan(info.bpm ?? 0, 60)
        // Where the song arrives, and every bar line to snap to.
        let bars = try XCTUnwrap(info.barSeconds)
        XCTAssertGreaterThan(bars.count, 8)
        XCTAssertEqual(bars, bars.sorted())
        let suggested = try XCTUnwrap(info.suggestedJoinBar)
        XCTAssertTrue((0..<(bars.count - 1)).contains(suggested))
        // The picture of the track, from the same audio.
        let pictured = try await session.request("envelope", ["per_second": 10])
        let envelope = try XCTUnwrap(JoinEnvelope(event: try XCTUnwrap(
            pictured.first(where: { $0.event == "envelope" }))))
        XCTAssertEqual(envelope.seconds, info.seconds ?? 0, accuracy: 1.0)
        let sources = try await session.request("sources", ["loop_bars": 4])
        XCTAssertFalse((sources.compactMap(\.sources).first ?? []).isEmpty)
        let made = try await session.request("render", ["bars": 8, "out": directory.path,
                                                        "join_bar": suggested])
        let intro = try XCTUnwrap(made.first(where: { $0.event == "intro" }))
        let output = try XCTUnwrap(intro.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output), output)
        XCTAssertEqual(intro.joinBar, suggested)
        XCTAssertEqual(intro.cutSeconds ?? -1, max(0, bars[suggested] - (info.pickupSeconds ?? 0)),
                       accuracy: 1.0)
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

/// What a host calls. The notification is the whole mechanism, so what it
/// carries is what is tested.
final class HostAPITests: XCTestCase {

    func testShowIntroCarriesTheTrackToFocus() {
        let url = URL(fileURLWithPath: "/m/Rock With You.mp3")
        let got = expectation(description: "posted")
        nonisolated(unsafe) var carried: URL?
        let token = NotificationCenter.default.addObserver(
            forName: .loudnessLabShowIntro, object: nil, queue: nil) { note in
            carried = note.object as? URL
            got.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        LoudnessLab.showIntro(focus: url)
        wait(for: [got], timeout: 1)
        XCTAssertEqual(carried, url)
    }

    func testShowIntroWithNoFocusCarriesNothing() {
        let got = expectation(description: "posted")
        nonisolated(unsafe) var object: Any?
        let token = NotificationCenter.default.addObserver(
            forName: .loudnessLabShowIntro, object: nil, queue: nil) { note in
            object = note.object
            got.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        LoudnessLab.showIntro()
        wait(for: [got], timeout: 1)
        XCTAssertNil(object)
    }
}
