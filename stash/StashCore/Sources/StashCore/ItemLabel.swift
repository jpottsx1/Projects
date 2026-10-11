import Foundation

/// A colour to mark an item with, as in the Finder. One per item; stored
/// on the item as its raw value, 0 for none.
public enum ItemLabel: Int, CaseIterable, Codable, Identifiable {
    case none = 0, red, orange, yellow, green, blue, purple, gray

    public var id: Int { rawValue }

    public var name: String {
        self == .none ? "None" : String(describing: self).capitalized
    }

    /// The colours, without `.none`.
    public static var colors: [ItemLabel] { allCases.filter { $0 != .none } }

    init?(typed: String) {
        let text = typed.lowercased()
        if text == "grey" {
            self = .gray
        } else if let found = Self.allCases.first(where: { String(describing: $0) == text }) {
            self = found
        } else {
            return nil
        }
    }
}
