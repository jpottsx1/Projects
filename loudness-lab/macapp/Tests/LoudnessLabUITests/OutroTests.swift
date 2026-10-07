import XCTest
@testable import LoudnessLabUI

/// Lines `loudness-lab intro --serve` really wrote for the outro commands, on a
/// small synthetic track that fades away (tests/test_outro.py builds it; paths
/// shortened). Not hand-made look-alikes: a decoder tested against its own
/// author's idea of the format passes until the format is read for the first time.
private enum RealOutro {
    static let prepared = #"{"event": "prepared", "id": 1, "path": "/tmp/x/Song.flac", "name": "Song.flac", "seconds": 50.0, "bpm": 120.04, "grid_coherence": 0.999, "first_bar_seconds": 0.0, "suggested_exit_bar": 18, "exit_reason": "the drums fall away after bar 17 (36.0 s in); the rest of the song is replaced", "exit_seconds": 36.0, "tail_seconds": 0.25, "suggested_join_bar": 0, "join_reason": "the track starts at full level", "join_seconds": 0.0, "pickup_seconds": 0.0, "bar_seconds": [0.0, 2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 21.995, 24.0, 26.0, 28.0, 30.0, 32.0, 34.0, 36.0, 38.0, 39.999, 41.999, 43.998, 45.997, 47.997, 49.996], "downbeat_from": "the accents in the low end", "bars_after_join": 25, "warnings": []}"#
    static let sources = #"{"event": "outro_sources", "id": 2, "loop_bars": 4, "sources": [{"bar": 8, "seconds": 16.0, "vocal_db": -120.0, "vocal_free": true, "repeat": 1.0, "snapped": true, "fill": 0.01, "feel": 0.097, "tempo_off": -1e-05, "chroma_match": 1.0, "level_vs_join_db": 1.5}, {"bar": 12, "seconds": 24.0, "vocal_db": -120.0, "vocal_free": true, "repeat": 0.98, "snapped": true, "fill": 0.1, "feel": 0.098, "tempo_off": -1e-05, "chroma_match": 0.999, "level_vs_join_db": 1.5}]}"#
    static let outro = #"{"event": "outro", "id": 3, "bpm": 120.0, "grid_bpm": 120.04, "loop_snapped": true, "loop_repeat": 1.0, "bars": 8, "loop_bars": 4, "seconds_of_outro": 16.0, "outro_samples": 768000, "style": "strip", "handin_bars": 1.0, "fade_bars": 4.0, "retuned_pct": 0.0, "tempo_off_pct": 0.001, "exit_bar": 18, "exit_seconds": 36.0, "tail_seconds": 0.25, "suggested_exit_bar": 18, "cut_seconds": 13.75, "source_bar": 8, "source_seconds": 16.0, "source_vocal_db": -120.0, "vocal_free": true, "grid_coherence": 0.999, "downbeat_from": "the accents in the low end", "warnings": [], "source": "/tmp/x/Song.flac", "output": "/tmp/x/o/Song (Outro 8 Strip).flac"}"#
}

final class OutroEventTests: XCTestCase {

    func testPreparedCarriesWhereTheSongWouldLeave() throws {
        let e = try XCTUnwrap(IntroEvent(RealOutro.prepared))
        XCTAssertEqual(e.suggestedExitBar, 18)
        XCTAssertEqual(e.exitSeconds ?? 0, 36.0, accuracy: 1e-9)
        XCTAssertEqual(e.tailSeconds ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertTrue(e.exitReason?.contains("fall away") ?? false)
        // ...alongside what an intro needs, unchanged.
        XCTAssertEqual(e.suggestedJoinBar, 0)
        XCTAssertEqual(e.barSeconds?.count, 26)
    }

    func testOutroLoopsDecodeLikeAnyOther() throws {
        let e = try XCTUnwrap(IntroEvent(RealOutro.sources))
        XCTAssertEqual(e.event, "outro_sources")
        XCTAssertEqual(e.sources?.map(\.bar), [8, 12])
        XCTAssertEqual(e.sources?.first?.vocalFree, true)
    }

    func testTheOutroEventBuildsARenderThatKnowsItIsOne() throws {
        let e = try XCTUnwrap(IntroEvent(RealOutro.outro))
        let render = try XCTUnwrap(IntroEngine.outroRender(from: e))
        XCTAssertEqual(render.kind, .outro)
        XCTAssertEqual(render.bars, 8)
        XCTAssertEqual(render.exitBar, 18)
        XCTAssertEqual(render.exitSeconds, 36.0, accuracy: 1e-9)
        XCTAssertEqual(render.tailSeconds, 0.25, accuracy: 1e-9)
        XCTAssertEqual(render.cutSeconds, 13.75, accuracy: 1e-9)
        XCTAssertEqual(render.introSeconds, 16.0, accuracy: 1e-9)    // the length of what was added
        XCTAssertEqual(render.style, "strip")
        XCTAssertEqual(render.fadeBars, 4.0, accuracy: 1e-9)
        XCTAssertEqual(render.name, "Song (Outro 8 Strip)")
    }

    func testAnIntroEventIsStillAnIntroRender() throws {
        // `render(from:)` must not have become an outro by default.
        let line = #"{"event": "intro", "id": 3, "bars": 8, "loop_bars": 4, "seconds_of_intro": 16.0, "lead_seconds": 0.01, "source_bar": 4, "source_seconds": 8.0, "vocal_free": true, "loop_repeat": 1.0, "warnings": [], "output": "/tmp/x/o/Song (Intro 8).flac"}"#
        let render = try XCTUnwrap(IntroEngine.render(from: try XCTUnwrap(IntroEvent(line))))
        XCTAssertEqual(render.kind, .intro)
    }
}

final class ExitMathTests: XCTestCase {
    // Bar lines every 2 s from 0: 0, 2, 4 ... 20 (eleven lines, ten bars).
    private let bars = (0...10).map { Double($0) * 2 }

    func testAnExitMayBeTheLastBarLineButNotTheFirstFew() {
        XCTAssertEqual(JoinMath.clampExit(10, in: bars), 10)
        XCTAssertEqual(JoinMath.clampExit(99, in: bars), 10)
        XCTAssertEqual(JoinMath.clampExit(0, in: bars), JoinMath.firstExitBar)
        XCTAssertEqual(JoinMath.clampExit(1, in: bars), JoinMath.firstExitBar)
    }

    func testAJoinStillStopsOneBarShortOfTheEnd() {
        // The two clamps differ on purpose: an intro's song needs a bar of itself.
        XCTAssertEqual(JoinMath.clamp(99, in: bars), 9)
    }

    func testTheNearestExitSnapsToABarLine() {
        XCTAssertEqual(JoinMath.nearestExit(to: 8.9, in: bars), 4)
        XCTAssertEqual(JoinMath.nearestExit(to: 9.1, in: bars), 5)
        XCTAssertEqual(JoinMath.nearestExit(to: 500, in: bars), 10)     // past the end: the last line
        XCTAssertEqual(JoinMath.nearestExit(to: 0.1, in: bars), JoinMath.firstExitBar)
    }
}

/// The engine in outro mode, against a stand-in for the tool that logs what it
/// was asked and answers with the real lines above.
@MainActor
final class OutroEngineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("outro-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fakeTool() throws -> URL {
        let envelope = #"{"event": "envelope", "per_second": 50.0, "seconds": 2.0, "bass": [10,20], "mid": [10,20], "treble": [10,20]}"#
        let sources = #"{"event": "sources", "loop_bars": 4, "sources": [{"bar": 4, "seconds": 8.0, "vocal_db": -120.0, "vocal_free": true, "repeat": 1.0, "snapped": true}], "suggested_style": "build", "style_reason": "x"}"#
        let canned: [String: String] = [
            "prepare": RealOutro.prepared, "sources": sources, "outro_sources": RealOutro.sources,
            "outro_render": RealOutro.outro, "envelope": envelope,
        ]
        let data = try JSONSerialization.data(withJSONObject: canned)
        try data.write(to: directory.appendingPathComponent("canned.json"))
        let script = """
        #!/usr/bin/env python3
        import json, sys, os
        here = os.path.dirname(os.path.abspath(__file__))
        canned = json.load(open(os.path.join(here, "canned.json")))
        for raw in sys.stdin:
            request = json.loads(raw)
            with open(os.path.join(here, "requests.jsonl"), "a") as log:
                log.write(raw if raw.endswith("\\n") else raw + "\\n")
            rid, cmd = request["id"], request["cmd"]
            if cmd in canned:
                event = json.loads(canned[cmd]); event["id"] = rid
                print(json.dumps(event), flush=True)
            print(json.dumps({"event": "done", "id": rid}), flush=True)
        """
        let url = directory.appendingPathComponent("loudness-lab")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func requests() -> [[String: Any]] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private func eventually(_ timeout: Double = 5, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > deadline { XCTFail("timed out waiting"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testPreparingTakesTheSuggestedExitAndLeavesTheModeAlone() async throws {
        let engine = IntroEngine(tool: try fakeTool(), clearsDrafts: false)
        await engine.prepare("/tmp/x/Song.flac")
        XCTAssertEqual(engine.mode, .intro)
        XCTAssertEqual(engine.track?.suggestedExitBar, 18)
        XCTAssertEqual(engine.exitBar, 18)
        XCTAssertEqual(engine.track?.exitSeconds ?? 0, 36.0, accuracy: 1e-9)
    }

    func testSwitchingToOutroAsksForOutroLoopsAtTheExit() async throws {
        let engine = IntroEngine(tool: try fakeTool(), clearsDrafts: false)
        await engine.prepare("/tmp/x/Song.flac")
        XCTAssertEqual(engine.sources.map(\.bar), [4])             // the intro's, from `sources`
        engine.mode = .outro
        try await eventually { engine.sources.map(\.bar) == [8, 12] }
        let ask = try XCTUnwrap(requests().last(where: { $0["cmd"] as? String == "outro_sources" }))
        XCTAssertEqual(ask["exit_bar"] as? Int, 18)
        XCTAssertEqual(ask["loop_bars"] as? Int, 4)
        // and back: the intro's list returns
        engine.mode = .intro
        try await eventually { engine.sources.map(\.bar) == [4] }
    }

    func testMovingTheExitAsksAgainAtTheNewBar() async throws {
        let engine = IntroEngine(tool: try fakeTool(), clearsDrafts: false)
        await engine.prepare("/tmp/x/Song.flac")
        engine.mode = .outro
        try await eventually { engine.sources.map(\.bar) == [8, 12] }
        engine.exitBar = 14
        try await eventually(5) {
            self.requests().contains { ($0["cmd"] as? String) == "outro_sources" && ($0["exit_bar"] as? Int) == 14 }
        }
    }

    func testMovingTheJoinInOutroModeDoesNotAskForIntroLoops() async throws {
        let engine = IntroEngine(tool: try fakeTool(), clearsDrafts: false)
        await engine.prepare("/tmp/x/Song.flac")
        engine.mode = .outro
        try await eventually { engine.sources.map(\.bar) == [8, 12] }
        let before = requests().count
        engine.joinBar = 3
        try await Task.sleep(nanoseconds: 1_200_000_000)           // longer than the debounce
        XCTAssertEqual(requests().count, before)
    }

    func testRenderingAnOutroSendsTheOutroRequestAndListsAnOutro() async throws {
        let engine = IntroEngine(tool: try fakeTool(), clearsDrafts: false)
        await engine.prepare("/tmp/x/Song.flac")
        engine.mode = .outro
        try await eventually { engine.sources.map(\.bar) == [8, 12] }
        engine.lengths = [8]
        engine.outroStyle = "beat"
        engine.outroFadeBars = 4
        await engine.render()
        let ask = try XCTUnwrap(requests().last(where: { $0["cmd"] as? String == "outro_render" }))
        XCTAssertEqual(ask["exit_bar"] as? Int, 18)
        XCTAssertEqual(ask["style"] as? String, "beat")
        XCTAssertEqual(ask["fade_bars"] as? Double, 4.0)
        XCTAssertEqual(ask["bars"] as? Int, 8)
        XCTAssertEqual(engine.renders.count, 1)
        XCTAssertEqual(engine.renders.first?.kind, .outro)
        // an intro render was not asked for
        XCTAssertNil(requests().first(where: { $0["cmd"] as? String == "render" }))
    }

    func testAnOutrosPlayheadIsTheOriginalsOwn() async throws {
        let engine = IntroEngine(tool: try fakeTool(), clearsDrafts: false)
        await engine.prepare("/tmp/x/Song.flac")
        engine.mode = .outro
        try await eventually { engine.sources.map(\.bar) == [8, 12] }
        engine.lengths = [8]
        await engine.render()
        let render = try XCTUnwrap(engine.renders.first)
        engine.play(render, from: 30)
        XCTAssertEqual(engine.originalTime(atPlayerPosition: 33.5), 33.5)
        engine.stopPlaying()
    }
}
