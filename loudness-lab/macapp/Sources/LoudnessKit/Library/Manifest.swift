import Foundation

/// What `loudness-lab subbass` writes beside the audio it renders.
///
/// The player reads this rather than scanning a folder, for one reason: the
/// manifest is where the tool states that a track's versions came out of a
/// single decode and are therefore sample-aligned. A folder of files makes
/// no such promise.
public struct Manifest: Codable {
    public let version: Int
    public let rate: Int
    public let aligned: Bool
    public let profile: String?
    public let settings: Profile
    public let tracks: [Track]

    public struct Track: Codable, Identifiable, Equatable {
        public let source: String
        public let name: String
        public let folder: String
        public let subDB: Double
        public let punchDB: Double
        /// Nil for a manifest written before this was added -- an older
        /// run genuinely has no air figure to show, not a zero one.
        public let airDB: Double?
        public let clipsRestored: Int
        public let clipLiftDB: Double
        public let variants: [Variant]

        public var id: String { source }

        enum CodingKeys: String, CodingKey {
            case source, name, folder, variants
            case subDB = "sub_db"
            case punchDB = "punch_db"
            case airDB = "air_db"
            case clipsRestored = "clips_restored"
            case clipLiftDB = "clip_lift_db"
        }
    }

    public struct Variant: Codable, Identifiable, Equatable {
        public let kind: String
        public let label: String
        public let path: String
        public let seconds: Double
        public let lufsI: Double?
        public let sP95: Double?
        public let truePeakDBTP: Double?

        public var id: String { path }
        public var url: URL { URL(fileURLWithPath: path) }

        enum CodingKeys: String, CodingKey {
            case kind, label, path, seconds
            case lufsI = "lufs_i"
            case sP95 = "s_p95"
            case truePeakDBTP = "true_peak_dbtp"
        }
    }

    public static func read(_ url: URL) throws -> Manifest {
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
    public func matchGains(using estimator: KeyPath<Manifest.Variant, Double?>) -> [String: Float] {
        let levels = variants.compactMap { $0[keyPath: estimator] }
        guard levels.count == variants.count, let quietest = levels.min() else {
            return Dictionary(uniqueKeysWithValues: variants.map { ($0.id, Float(0)) })
        }
        return Dictionary(uniqueKeysWithValues: variants.map {
            ($0.id, Float(quietest - ($0[keyPath: estimator] ?? quietest)))
        })
    }
}
