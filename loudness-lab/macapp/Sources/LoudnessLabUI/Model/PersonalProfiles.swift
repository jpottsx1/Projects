import Foundation
import LoudnessKit

/// Personal presets, alongside the measured built-in ones.
///
/// `Profile.builtIn` is a fixed, documented set -- each one backed by a
/// measurement written down in its own description, and not something this
/// app edits. A personal preset carries no such claim: it is whatever was
/// on the sliders when Save was pressed, under whatever name was given,
/// kept until deleted. Persisted in `UserDefaults`, the same place every
/// other small per-user setting in this app already lives.
@MainActor
final class PersonalProfiles: ObservableObject {
    @Published private(set) var profiles: [String: Profile] = [:]

    private static let key = "personalProfiles"

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([String: Profile].self, from: data)
        else { return }
        profiles = decoded
    }

    /// Refused rather than shadowing a built-in name -- a picker showing
    /// "restore" twice, one measured and one whatever was on the sliders,
    /// is a wrong answer that looks like a right one.
    @discardableResult
    func save(_ profile: Profile, as name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Profile.builtIn[trimmed] == nil else { return false }
        var stored = profile
        // A personal preset has no measurement behind it; carrying over
        // whatever built-in's description happened to be on screen would
        // claim one it does not have.
        stored.description = ""
        profiles[trimmed] = stored
        persist()
        return true
    }

    func delete(_ name: String) {
        profiles.removeValue(forKey: name)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
