import Foundation

/// How a rollup or formula field is set up, kept on the field as JSON.
public struct FieldConfig: Codable, Equatable {
    /// Rollup: the relation field to follow, and what to summarise on the
    /// items it leads to: a field of theirs, or (nil) their titles.
    public var relation: UUID?
    public var target: UUID?
    public var function: Rollup.Function = .count
    /// Formula: the expression.
    public var formula: String = ""

    public init(relation: UUID? = nil, target: UUID? = nil, function: Rollup.Function = .count, formula: String = "") {
        self.relation = relation
        self.target = target
        self.function = function
        self.formula = formula
    }

    public init(json: String) {
        self = (try? JSONDecoder().decode(FieldConfig.self, from: Data(json.utf8))) ?? FieldConfig()
    }

    public var json: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// Notion's rollups: a summary of a field across the items a relation leads to.
public enum Rollup {
    public enum Function: String, Codable, CaseIterable, Identifiable {
        case count, countValues, sum, average, minimum, maximum, earliest, latest, list, unique

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .count: "Count Items"
            case .countValues: "Count Values"
            case .sum: "Sum"
            case .average: "Average"
            case .minimum: "Smallest"
            case .maximum: "Largest"
            case .earliest: "Earliest Date"
            case .latest: "Latest Date"
            case .list: "List"
            case .unique: "List Unique"
            }
        }
    }

    /// `values` as stored, one per related item; `kind` theirs. Gives the
    /// result as stored, and its kind.
    public static func compute(_ values: [String], kind: CustomField.Kind, function: Function) -> (String, CustomField.Kind) {
        let present = values.filter { !$0.isEmpty }
        let numbers = present.compactMap(CustomField.number(from:))
        switch function {
        case .count: return (String(values.count), .number)
        case .countValues: return (String(present.count), .number)
        case .sum: return (format(numbers.reduce(0, +)), .number)
        case .average: return (numbers.isEmpty ? "" : format(numbers.reduce(0, +) / Double(numbers.count)), .number)
        case .minimum: return (numbers.min().map(format) ?? "", .number)
        case .maximum: return (numbers.max().map(format) ?? "", .number)
        // Stored dates (2026-10-12) sort as text.
        case .earliest: return (present.filter { CustomField.date(from: $0) != nil }.min() ?? "", .date)
        case .latest: return (present.filter { CustomField.date(from: $0) != nil }.max() ?? "", .date)
        case .list: return (present.map { CustomField.display($0, kind: kind) }.joined(separator: ", "), .text)
        case .unique:
            var seen: Set<String> = []
            return (present.map { CustomField.display($0, kind: kind) }.filter { seen.insert($0).inserted }.joined(separator: ", "), .text)
        }
    }

    /// Whole numbers without ".0"; others to at most four places.
    public static func format(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
        let text = String(format: "%.4f", number)
        return text.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }
}

/// Notion's formulas, a small language: numbers, "text", true and false,
/// fields by name in braces (`{Price}`) or `prop("Price")`, + - * / %,
/// & to join text, comparisons (== != < <= > >=), and, or, not, and the
/// functions if, round, abs, min, max, floor, ceil, length, upper, lower,
/// contains, concat, today, days, dateAdd, year, month, day, empty.
public enum Formula {
    public enum Value: Equatable {
        case number(Double), text(String), bool(Bool), date(Date), empty

        /// As a field stores it, and the kind it reads as.
        public var stored: (String, CustomField.Kind) {
            switch self {
            case .number(let number): (Rollup.format(number), .number)
            case .text(let text): (text, .text)
            case .bool(let bool): (bool ? "true" : "false", .yesNo)
            case .date(let date): (CustomField.storedDate(date), .date)
            case .empty: ("", .text)
            }
        }

        var number: Double? {
            switch self {
            case .number(let number): number
            case .bool(let bool): bool ? 1 : 0
            case .text(let text): CustomField.number(from: text)
            default: nil
            }
        }

        var text: String {
            switch self {
            case .number(let number): Rollup.format(number)
            case .text(let text): text
            case .bool(let bool): bool ? "true" : "false"
            case .date(let date): CustomField.storedDate(date)
            case .empty: ""
            }
        }

        var truth: Bool {
            switch self {
            case .bool(let bool): bool
            case .number(let number): number != 0
            case .text(let text): !text.isEmpty
            case .date: true
            case .empty: false
            }
        }
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    /// A stored field value as a formula sees it.
    public static func value(_ stored: String, kind: CustomField.Kind) -> Value {
        guard !stored.isEmpty else { return .empty }
        switch kind {
        case .number: return CustomField.number(from: stored).map(Value.number) ?? .text(stored)
        case .date: return CustomField.date(from: stored).map(Value.date) ?? .text(stored)
        case .yesNo: return .bool(stored == "true")
        default: return .text(stored)
        }
    }

    public static func evaluate(_ expression: String, field: (String) -> Value?, now: Date = .now,
                                calendar: Calendar = .current) throws -> Value {
        let read = try tokens(expression)
        return try withoutActuallyEscaping(field) { field in
            var parser = Parser(tokens: read, field: field, now: now, calendar: calendar)
            let result = try parser.expression()
            guard parser.position == parser.tokens.count else {
                throw Failure(message: "Unexpected “\(parser.tokens[parser.position].text)”")
            }
            return result
        }
    }

    // MARK: - Reading

    struct Token: Equatable {
        enum Kind { case number, string, field, name, symbol }
        var kind: Kind
        var text: String
    }

    static func tokens(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        func peek(_ offset: Int = 0) -> Character? {
            guard let at = text.index(index, offsetBy: offset, limitedBy: text.endIndex), at < text.endIndex else { return nil }
            return text[at]
        }
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                index = text.index(after: index)
            } else if character.isNumber || (character == "." && peek(1)?.isNumber == true) {
                let start = index
                while index < text.endIndex, text[index].isNumber || text[index] == "." { index = text.index(after: index) }
                tokens.append(Token(kind: .number, text: String(text[start..<index])))
            } else if character == "\"" {
                index = text.index(after: index)
                var value = ""
                while index < text.endIndex, text[index] != "\"" {
                    value.append(text[index])
                    index = text.index(after: index)
                }
                guard index < text.endIndex else { throw Failure(message: "A \" isn't closed") }
                index = text.index(after: index)
                tokens.append(Token(kind: .string, text: value))
            } else if character == "{" {
                index = text.index(after: index)
                var name = ""
                while index < text.endIndex, text[index] != "}" {
                    name.append(text[index])
                    index = text.index(after: index)
                }
                guard index < text.endIndex else { throw Failure(message: "A { isn't closed") }
                index = text.index(after: index)
                tokens.append(Token(kind: .field, text: name.trimmingCharacters(in: .whitespaces)))
            } else if character.isLetter || character == "_" {
                let start = index
                while index < text.endIndex, text[index].isLetter || text[index].isNumber || text[index] == "_" {
                    index = text.index(after: index)
                }
                tokens.append(Token(kind: .name, text: String(text[start..<index])))
            } else {
                let two = String(character) + (peek(1).map(String.init) ?? "")
                if ["==", "!=", "<=", ">=", "&&", "||"].contains(two) {
                    tokens.append(Token(kind: .symbol, text: two))
                    index = text.index(index, offsetBy: 2)
                } else if "+-*/%&<>(),=!".contains(character) {
                    tokens.append(Token(kind: .symbol, text: character == "=" ? "==" : String(character)))
                    index = text.index(after: index)
                } else {
                    throw Failure(message: "“\(character)” can't be used here")
                }
            }
        }
        return tokens
    }

    struct Parser {
        let tokens: [Token]
        let field: (String) -> Value?
        let now: Date
        let calendar: Calendar
        var position = 0

        init(tokens: [Token], field: @escaping (String) -> Value?, now: Date, calendar: Calendar) {
            self.tokens = tokens
            self.field = field
            self.now = now
            self.calendar = calendar
        }

        mutating func take(_ symbol: String) -> Bool {
            guard position < tokens.count, tokens[position].kind != .string,
                  tokens[position].text.lowercased() == symbol else { return false }
            position += 1
            return true
        }

        mutating func expression() throws -> Value { try or() }

        mutating func or() throws -> Value {
            var left = try and()
            while take("||") || take("or") { let right = try and(); left = .bool(left.truth || right.truth) }
            return left
        }

        mutating func and() throws -> Value {
            var left = try comparison()
            while take("&&") || take("and") { let right = try comparison(); left = .bool(left.truth && right.truth) }
            return left
        }

        mutating func comparison() throws -> Value {
            let left = try joined()
            for symbol in ["==", "!=", "<=", ">=", "<", ">"] where take(symbol) {
                let right = try joined()
                return .bool(Formula.compare(left, right, symbol))
            }
            return left
        }

        mutating func joined() throws -> Value {
            var left = try sum()
            while take("&") { let right = try sum(); left = .text(left.text + right.text) }
            return left
        }

        mutating func sum() throws -> Value {
            var left = try product()
            while true {
                if take("+") {
                    let right = try product()
                    if case .date(let date) = left, let days = right.number {
                        left = .date(calendar.date(byAdding: .day, value: Int(days), to: date) ?? date)
                    } else if case .text = left, right.number == nil || left.number == nil {
                        left = .text(left.text + right.text)
                    } else {
                        left = .number(try Formula.number(left) + Formula.number(right))
                    }
                } else if take("-") {
                    let right = try product()
                    if case .date(let a) = left, case .date(let b) = right {
                        left = .number(Double(calendar.dateComponents([.day], from: b, to: a).day ?? 0))
                    } else if case .date(let date) = left, let days = right.number {
                        left = .date(calendar.date(byAdding: .day, value: -Int(days), to: date) ?? date)
                    } else {
                        left = .number(try Formula.number(left) - Formula.number(right))
                    }
                } else {
                    return left
                }
            }
        }

        mutating func product() throws -> Value {
            var left = try unary()
            while true {
                if take("*") {
                    left = .number(try Formula.number(left) * Formula.number(try unary()))
                } else if take("/") {
                    let divisor = try Formula.number(try unary())
                    guard divisor != 0 else { throw Failure(message: "Division by zero") }
                    left = .number(try Formula.number(left) / divisor)
                } else if take("%") {
                    let divisor = try Formula.number(try unary())
                    guard divisor != 0 else { throw Failure(message: "Division by zero") }
                    left = .number(try Formula.number(left).truncatingRemainder(dividingBy: divisor))
                } else {
                    return left
                }
            }
        }

        mutating func unary() throws -> Value {
            if take("-") { return .number(-(try Formula.number(try unary()))) }
            if take("!") || take("not") { return .bool(!(try unary()).truth) }
            return try primary()
        }

        mutating func primary() throws -> Value {
            guard position < tokens.count else { throw Failure(message: "The formula ends too soon") }
            let token = tokens[position]
            position += 1
            switch token.kind {
            case .number:
                guard let number = Double(token.text) else { throw Failure(message: "“\(token.text)” isn't a number") }
                return .number(number)
            case .string:
                return .text(token.text)
            case .field:
                guard let value = field(token.text) else { throw Failure(message: "There's no field called “\(token.text)”") }
                return value
            case .symbol:
                guard token.text == "(" else { throw Failure(message: "Unexpected “\(token.text)”") }
                let inner = try expression()
                guard take(")") else { throw Failure(message: "A ( isn't closed") }
                return inner
            case .name:
                let name = token.text.lowercased()
                if name == "true" { return .bool(true) }
                if name == "false" { return .bool(false) }
                guard take("(") else { throw Failure(message: "“\(token.text)” needs ( ) after it") }
                var arguments: [Value] = []
                if !take(")") {
                    repeat { arguments.append(try expression()) } while take(",")
                    guard take(")") else { throw Failure(message: "\(token.text)( isn't closed") }
                }
                return try Formula.call(name, arguments, field: field, now: now, calendar: calendar)
            }
        }
    }

    static func number(_ value: Value) throws -> Double {
        if case .empty = value { return 0 }
        guard let number = value.number else { throw Failure(message: "“\(value.text)” isn't a number") }
        return number
    }

    static func compare(_ left: Value, _ right: Value, _ symbol: String) -> Bool {
        let ordered: ComparisonResult
        if let a = left.number, let b = right.number, !(isText(left) && isText(right)) {
            ordered = a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        } else if case .date(let a) = left, case .date(let b) = right {
            ordered = a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        } else {
            ordered = left.text.localizedStandardCompare(right.text)
        }
        switch symbol {
        case "==": return ordered == .orderedSame
        case "!=": return ordered != .orderedSame
        case "<": return ordered == .orderedAscending
        case "<=": return ordered != .orderedDescending
        case ">": return ordered == .orderedDescending
        default: return ordered != .orderedAscending
        }
    }

    private static func isText(_ value: Value) -> Bool {
        if case .text = value { return true }
        return false
    }

    static func call(_ name: String, _ arguments: [Value], field: (String) -> Value?, now: Date, calendar: Calendar) throws -> Value {
        func argument(_ index: Int) throws -> Value {
            guard arguments.indices.contains(index) else { throw Failure(message: "\(name)( needs more values") }
            return arguments[index]
        }
        func date(_ index: Int) throws -> Date {
            let value = try argument(index)
            if case .date(let date) = value { return date }
            if case .text(let text) = value, let date = CustomField.date(from: text) { return date }
            throw Failure(message: "\(name)( needs a date")
        }
        switch name {
        case "if": return try argument(0).truth ? argument(1) : (arguments.count > 2 ? arguments[2] : .empty)
        case "round":
            let places = arguments.count > 1 ? try number(arguments[1]) : 0
            let scale = pow(10, places)
            return .number((try number(argument(0)) * scale).rounded() / scale)
        case "abs": return .number(abs(try number(argument(0))))
        case "floor": return .number((try number(argument(0))).rounded(.down))
        case "ceil": return .number((try number(argument(0))).rounded(.up))
        case "min": return .number(try arguments.map(number).min() ?? 0)
        case "max": return .number(try arguments.map(number).max() ?? 0)
        case "length": return .number(Double(try argument(0).text.count))
        case "upper": return .text(try argument(0).text.uppercased())
        case "lower": return .text(try argument(0).text.lowercased())
        case "contains": return .bool(try argument(0).text.localizedCaseInsensitiveContains(try argument(1).text))
        case "concat": return .text(arguments.map(\.text).joined())
        case "empty": return .bool(arguments.first.map { $0 == .empty || $0.text.isEmpty } ?? true)
        case "prop":
            let name = try argument(0).text
            guard let value = field(name) else { throw Failure(message: "There's no field called “\(name)”") }
            return value
        case "today", "now": return .date(calendar.startOfDay(for: now))
        case "days": return .number(Double(calendar.dateComponents([.day], from: try date(1), to: try date(0)).day ?? 0))
        case "dateadd":
            let start = try date(0)
            return .date(calendar.date(byAdding: .day, value: Int(try number(argument(1))), to: start) ?? start)
        case "year": return .number(Double(calendar.component(.year, from: try date(0))))
        case "month": return .number(Double(calendar.component(.month, from: try date(0))))
        case "day": return .number(Double(calendar.component(.day, from: try date(0))))
        default: throw Failure(message: "There's no function called \(name)(")
        }
    }
}
