import XCTest
@testable import LoudnessLabUI

/// A results manifest is read back from disk, including ones written by older
/// versions of the tool, so a malformed one must not take the app down.
final class ManifestTests: XCTestCase {

    /// The 2026-10-12 crash: "Pt. 1" put A and B on one path, and opening
    /// the track trapped on the duplicate key.
    func testTwoVersionsOnOnePathDoNotTrap() throws {
        let path = "/tmp/002 - Janet Jackson - Nasty (Cool Summer Mix _ Pt.mp3"
        let json = """
            {"source": "/src/002 - Janet Jackson - Nasty (Cool Summer Mix _ Pt. 1).mp3",
             "name": "Nasty", "folder": "Funk", "sub_db": 0, "punch_db": 4,
             "clips_restored": 0, "clip_lift_db": 0,
             "variants": [
               {"kind": "original", "label": "original", "path": "\(path)",
                "seconds": 1, "lufs_i": -15, "s_p95": -12, "true_peak_dbtp": -1},
               {"kind": "processed", "label": "punch+4dB", "path": "\(path)",
                "seconds": 1, "lufs_i": -14, "s_p95": -10, "true_peak_dbtp": -1}]}
            """
        let track = try JSONDecoder().decode(Manifest.Track.self, from: Data(json.utf8))
        let gains = track.matchGains(using: \.sP95)
        XCTAssertEqual(gains.count, 1)
        XCTAssertEqual(try XCTUnwrap(gains[path]), -2, accuracy: 1e-6)
    }
}
