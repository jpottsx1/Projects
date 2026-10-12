import Foundation
import OSLog
import SwiftData
import StashCore

/// Filling the test library with a big made-up library, to see how Stash
/// copes: launch with `-StashTestLibrary YES -StashGenerateItems 10000`, or
/// use the sidebar's ⋯ menu in the test library. The same items each time,
/// from a fixed seed, so runs can be compared.
extension Library {
    static let performanceLog = Logger(subsystem: "com.jpottsx1.stash", category: "performance")

    /// Asked for at launch: how many items to make, if any.
    static var requestedTestItems: Int {
        StashStore.isTestLibrary ? UserDefaults.standard.integer(forKey: "StashGenerateItems") : 0
    }

    func generateTestItems(_ count: Int) {
        guard StashStore.isTestLibrary, count > 0 else { return }
        let started = ContinuousClock.now
        var random = SeededRandom(seed: 2026)
        let words = Self.lorem.split(separator: " ").map(String.init)
        func sentence(_ length: Int) -> String {
            let picked = (0..<length).map { _ in words[random.next(below: words.count)] }.joined(separator: " ")
            return picked.prefix(1).uppercased() + picked.dropFirst() + "."
        }
        func paragraph() -> String { (0..<(3 + random.next(below: 5))).map { _ in sentence(6 + random.next(below: 10)) }.joined(separator: " ") }

        // Places to put things.
        let tags = (0..<40).map { number -> Tag in
            let tag = Tag(name: "\(words[number % words.count])-\(number)")
            context.insert(tag)
            return tag
        }
        var categories: [ItemCategory] = []
        for number in 0..<12 {
            let parent = ItemCategory(name: "Area \(number + 1)")
            context.insert(parent)
            categories.append(parent)
            for child in 0..<2 {
                let category = ItemCategory(name: "Project \(number + 1).\(child + 1)", parent: parent)
                context.insert(category)
                categories.append(category)
            }
        }
        let lists = ["Reading", "Ideas", "Errands"].map { name -> ItemList in
            let list = ItemList(name: name)
            context.insert(list)
            return list
        }
        let status = FieldDefinition(name: "Status", kind: .choice, order: 0)
        status.choiceList = ["Open", "In Progress", "Done"]
        let price = FieldDefinition(name: "Price", kind: .number, order: 1)
        context.insert(status)
        context.insert(price)
        save()

        let threeYears: TimeInterval = 3 * 365 * 86_400
        for number in 0..<count {
            let isLink = random.next(below: 4) == 0
            let item = Item(kind: isLink ? .link : .note, title: sentence(2 + random.next(below: 5)).dropLast().description)
            let created = Date.now.addingTimeInterval(-Double(random.next(below: Int(threeYears))))
            item.createdAt = created
            item.modifiedAt = created.addingTimeInterval(Double(random.next(below: 30 * 86_400)))
            if isLink {
                item.urlString = "https://example.com/\(number)/\(words[random.next(below: words.count)])"
                item.summary = sentence(12)
                item.extractedText = (0..<(4 + random.next(below: 20))).map { _ in paragraph() }.joined(separator: "\n\n")
                item.readLaterAt = random.next(below: 10) == 0 ? created : nil
                item.readingProgress = item.readLaterAt != nil ? Double(random.next(below: 100)) / 100 : 0
            } else {
                item.body = (0..<(1 + random.next(below: 6))).map { _ in paragraph() }.joined(separator: "\n\n")
            }
            context.insert(item)
            if random.next(below: 3) > 0 { item.category = categories[random.next(below: categories.count)] }
            item.tags = (0..<random.next(below: 4)).map { _ in tags[random.next(below: tags.count)] }
            item.labelRaw = random.next(below: 5) == 0 ? 1 + random.next(below: 7) : 0
            item.rating = random.next(below: 6) == 0 ? 1 + random.next(below: 5) : 0
            item.isFavorite = random.next(below: 20) == 0
            if random.next(below: 15) == 0 { item.lists = [lists[random.next(below: lists.count)]] }
            if random.next(below: 6) == 0 {
                var values = [status.uuid: status.choiceList[random.next(below: 3)]]
                if random.next(below: 2) == 0 { values[price.uuid] = String(random.next(below: 2000)) }
                item.customFields = CustomField.encode(values)
            }
            if number % 500 == 499 { save() }
        }
        save()
        Self.performanceLog.info("Made \(count) test items in \(ContinuousClock.now - started)")
        refreshAfterStoreChange()
    }

    private static let lorem = """
        lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt labore dolore magna \
        aliqua enim minim veniam quis nostrud exercitation ullamco laboris nisi aliquip commodo consequat duis aute \
        irure reprehenderit voluptate velit esse cillum fugiat nulla pariatur excepteur sint occaecat cupidatat non \
        proident sunt culpa officia deserunt mollit anim garden boiler invoice recipe travel meeting budget sourdough \
        tomatoes plumber bicycle library chapter quarterly zebra harbour lantern meadow orchard
        """
}

/// The same numbers every run, for a library that's the same every time.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(below bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(next() % UInt64(bound))
    }
}
