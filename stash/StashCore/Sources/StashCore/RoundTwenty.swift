import Foundation

/// The checkboxes in a note, for the Tasks view: `- [ ] Call the bank
/// @due(2026-10-20)`. A due date is written `@due(2026-10-20)` (or with
/// `📅 2026-10-20`, as Obsidian's Tasks plugin does).
public enum NoteTasks {
    public struct Task: Equatable {
        /// Where it is in the note, for ticking it.
        public var line: Int
        /// The text, without its due date.
        public var text: String
        public var isDone: Bool
        public var due: DateComponents?
    }

    public static func tasks(in text: String) -> [Task] {
        var tasks: [Task] = []
        var inFence = false
        for (number, line) in MarkdownBlocks.sourceLines(text).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, let (done, body) = MarkdownBlocks.task(trimmed) else { continue }
            let (rest, due) = dueDate(in: body)
            tasks.append(Task(line: number, text: rest, isDone: done, due: due))
        }
        return tasks
    }

    /// The text without its due date, and the date.
    static func dueDate(in text: String) -> (String, DateComponents?) {
        for pattern in [#"@due\((\d{4})-(\d{1,2})-(\d{1,2})\)"#, #"📅\s*(\d{4})-(\d{1,2})-(\d{1,2})"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(match.range, in: text) else { continue }
            let parts = (1...3).compactMap { Range(match.range(at: $0), in: text).flatMap { Int(text[$0]) } }
            guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { continue }
            var rest = text
            rest.removeSubrange(whole)
            rest = rest.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            return (rest, DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        return (text, nil)
    }

    /// The task's line with its due date set to `day`, or taken away with nil.
    public static func settingDue(_ day: DateComponents?, onLine line: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line), MarkdownBlocks.task(lines[line].trimmingCharacters(in: .whitespaces)) != nil else { return text }
        var current = lines[line]
        for pattern in [#"\s*@due\([^)]*\)"#, #"\s*📅\s*\d{4}-\d{1,2}-\d{1,2}"#] {
            current = current.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        if let day, let year = day.year, let month = day.month, let date = day.day {
            current += String(format: " @due(%04d-%02d-%02d)", year, month, date)
        }
        lines[line] = current
        return lines.joined(separator: "\n")
    }

    /// Where a task falls, for grouping.
    public enum When: Int, CaseIterable, Comparable {
        case overdue, today, upcoming, someday, done

        public static func < (a: When, b: When) -> Bool { a.rawValue < b.rawValue }

        public var name: String {
            switch self {
            case .overdue: "Overdue"
            case .today: "Today"
            case .upcoming: "Upcoming"
            case .someday: "No Date"
            case .done: "Done"
            }
        }
    }

    public static func when(_ task: Task, now: Date = .now, calendar: Calendar = .current) -> When {
        if task.isDone { return .done }
        guard let due = task.due, let day = calendar.date(from: due) else { return .someday }
        let today = calendar.startOfDay(for: now)
        if day < today { return .overdue }
        return calendar.isDate(day, inSameDayAs: today) ? .today : .upcoming
    }
}

/// Automatic backups: what they're called, and which to delete once
/// there are more than are kept.
public enum BackupRotation {
    public static let prefix = "Stash Backup "

    /// "Stash Backup Work 2026-10-14 0930.zip"
    public static func fileName(library: String, date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(format: "%04d-%02d-%02d %02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                           parts.hour ?? 0, parts.minute ?? 0)
        let name = library.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return prefix + (name.isEmpty ? "" : name + " ") + stamp + ".zip"
    }

    /// The library's backups among `names`, newest first (the stamp sorts as text).
    public static func backups(among names: [String], library: String) -> [String] {
        let name = library.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let start = prefix + (name.isEmpty ? "" : name + " ")
        return names.filter { file in
            guard file.hasPrefix(start), file.hasSuffix(".zip") else { return false }
            // The rest is just the stamp: "2026-10-14 0930".
            let stamp = file.dropFirst(start.count).dropLast(4)
            return stamp.count == 15 && stamp.allSatisfy { $0.isNumber || $0 == "-" || $0 == " " }
        }
        .sorted(by: >)
    }

    /// The backups beyond the newest `keep`, to delete.
    public static func surplus(among names: [String], library: String, keep: Int) -> [String] {
        Array(backups(among: names, library: library).dropFirst(max(keep, 1)))
    }
}

/// Sizes and rectangles for the picture tools.
public enum PictureGeometry {
    /// `size` scaled down (never up) to fit within `maxDimension` on its longer side.
    public static func fitting(width: Double, height: Double, maxDimension: Double) -> (width: Int, height: Int) {
        let longer = max(width, height)
        guard longer > maxDimension, longer > 0 else { return (Int(width.rounded()), Int(height.rounded())) }
        let scale = maxDimension / longer
        return (max(Int((width * scale).rounded()), 1), max(Int((height * scale).rounded()), 1))
    }

    /// A rectangle chosen on a picture shown `shownWidth` by `shownHeight`,
    /// in the picture's own pixels (origin top left), kept inside it.
    public static func pixelRect(x: Double, y: Double, width: Double, height: Double,
                                 shownWidth: Double, shownHeight: Double,
                                 pixelWidth: Int, pixelHeight: Int) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard shownWidth > 0, shownHeight > 0 else { return nil }
        let sx = Double(pixelWidth) / shownWidth, sy = Double(pixelHeight) / shownHeight
        let left = max(0, min(x, x + width)) * sx, top = max(0, min(y, y + height)) * sy
        let right = min(shownWidth, max(x, x + width)) * sx, bottom = min(shownHeight, max(y, y + height)) * sy
        let rect = (x: Int(left.rounded()), y: Int(top.rounded()), width: Int((right - left).rounded()), height: Int((bottom - top).rounded()))
        return rect.width >= 2 && rect.height >= 2 ? rect : nil
    }
}
