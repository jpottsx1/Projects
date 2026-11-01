import Foundation
import LoudnessKit

/// What `loudness-lab subbass` writes beside the audio it renders.
///
/// The player reads this rather than scanning a folder, for one reason: the
/// manifest is where the tool states that a track's versions came out of a
/// single decode and are therefore sample-aligned. A folder of files makes
/// no such promise.
struct Manifest: Codable {
    let version: Int
    let rate: Int
    let aligned: Bool
    let profile: String?
    let settings: Profile
    let tracks: [Track]

    struct Track: Codable, Identifiable, Equatable {
        let source: String
        let name: String
        let folder: String
        let subDB: Double
        let punchDB: Double
        /// Nil for a manifest written before this was added -- an older
        /// run genuinely has no air figure to show, not a zero one.
        let airDB: Double?
        /// The 200-400 Hz change the mud cut made (negative), and why a
        /// track got none. Nil in a manifest from before the cut existed.
        let mudDB: Double?
        let mudNote: String?
        /// The 63-160 Hz lift the body stage made, and why a track got
        /// none. Nil in a manifest from before the stage existed.
        let bodyDB: Double?
        let bodyNote: String?
        let clipsRestored: Int
        let clipLiftDB: Double
        let variants: [Variant]
        /// What the sub was asked for (the track's shortfall against the
        /// reference, capped) and why it got what it got. Nil in a
        /// manifest written before these were added.
        let subAskedDB: Double?
        let subNote: String?
        /// dB the limiter took off the tallest peak, 0 where it did not run.
        let limitDB: Double?
        /// What the levelling did: the level on `levelEstimator` ("lufs_i"
        /// or "s_p95") going in and coming out, the target, and the gain.
        /// Nil where nothing was levelled -- a dry run, a level-matched
        /// pair, or a manifest from before these were written.
        let levelEstimator: String?
        let levelTarget: Double?
        let levelBefore: Double?
        let levelAfter: Double?
        let gainDB: Double?

        var id: String { source }

        /// How far the levelled track ended under its target, where it
        /// ended more than a tenth of a dB under: the peaks stopped it.
        var shortOfTarget: Double? {
            guard let levelTarget, let levelAfter, levelTarget - levelAfter > 0.1 else { return nil }
            return levelTarget - levelAfter
        }

        enum CodingKeys: String, CodingKey {
            case source, name, folder, variants
            case subDB = "sub_db"
            case punchDB = "punch_db"
            case airDB = "air_db"
            case mudDB = "mud_db"
            case mudNote = "mud_note"
            case bodyDB = "body_db"
            case bodyNote = "body_note"
            case clipsRestored = "clips_restored"
            case clipLiftDB = "clip_lift_db"
            case subAskedDB = "sub_asked_db"
            case subNote = "sub_note"
            case limitDB = "limit_db"
            case levelEstimator = "level_estimator"
            case levelTarget = "level_target"
            case levelBefore = "level_before"
            case levelAfter = "level_after"
            case gainDB = "gain_db"
        }
    }

    struct Variant: Codable, Identifiable, Equatable {
        let kind: String
        let label: String
        let path: String
        let seconds: Double
        let lufsI: Double?
        let sP95: Double?
        let truePeakDBTP: Double?

        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }

        enum CodingKeys: String, CodingKey {
            case kind, label, path, seconds
            case lufsI = "lufs_i"
            case sP95 = "s_p95"
            case truePeakDBTP = "true_peak_dbtp"
        }
    }

    static func read(_ url: URL) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }
}

extension Manifest.Track {
    /// Per-version gain that brings every version to the quietest of them.
    ///
    /// Downwards only, and on the same estimator the tool levels on. Matching
    /// upwards would risk clipping the thing you are auditioning, and not
    /// matching at all would mean the louder version wins on loudness alone --
    /// which it reliably does, whatever else is true of it.
    ///
    /// Two versions on one path keep the larger cut rather than trapping. The
    /// tool once wrote a dotted name's A and B to the same file ("Pt. 1" made
    /// both "...Pt.mp3"), and `uniqueKeysWithValues` on that manifest took
    /// DiscoTags down the moment the track was opened (2026-10-12).
    func matchGains(using estimator: KeyPath<Manifest.Variant, Double?>) -> [String: Float] {
        let levels = variants.compactMap { $0[keyPath: estimator] }
        guard levels.count == variants.count, let quietest = levels.min() else {
            return Dictionary(variants.map { ($0.id, Float(0)) }, uniquingKeysWith: min)
        }
        return Dictionary(variants.map {
            ($0.id, Float(quietest - ($0[keyPath: estimator] ?? quietest)))
        }, uniquingKeysWith: min)
    }
}
