import Foundation

public struct FileRecord: Codable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date
    public init(path: String, isDirectory: Bool, size: Int64, modified: Date) {
        self.path = path; self.name = URL(fileURLWithPath: path).lastPathComponent
        self.isDirectory = isDirectory; self.size = size; self.modified = modified
    }
}

/// Parsed once per search. Regex and wildcard patterns are compiled once, not per file.
public struct SearchQuery {
    private indirect enum Expression {
        case term((FileRecord) -> Bool), and([Expression]), or([Expression]), not(Expression)
        func matches(_ f: FileRecord) -> Bool {
            switch self {
            case .term(let predicate): return predicate(f)
            case .and(let values): return values.allSatisfy { $0.matches(f) }
            case .or(let values): return values.contains { $0.matches(f) }
            case .not(let value): return !value.matches(f)
            }
        }
    }
    private let expression: Expression
    public let error: String?
    public let readsContent: Bool
    public init(_ text: String, caseSensitive: Bool = false, matchPath: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        var parser = Parser(text, caseSensitive: caseSensitive, matchPath: matchPath, wholeWord: wholeWord)
        if regex {
            expression = parser.compile("regex:" + text)
        } else { expression = parser.parse() }
        error = parser.error; readsContent = text.lowercased().contains("content:")
    }
    public func matches(_ file: FileRecord) -> Bool { error == nil && expression.matches(file) }

    private struct Parser {
        var tokens: [String] = []
        var position = 0
        var error: String?
        let sensitive: Bool, path: Bool, whole: Bool
        init(_ text: String, caseSensitive: Bool, matchPath: Bool, wholeWord: Bool) {
            sensitive = caseSensitive; path = matchPath; whole = wholeWord
            var token = "", quoted = false
            func flush() { if !token.isEmpty { tokens.append(token); token = "" } }
            for character in text {
                if character == "\"" { quoted.toggle() }
                else if !quoted && (character == "|" || character == "<" || character == ">") {
                    // Comparisons following a property colon belong to the token.
                    if (character == "<" || character == ">") && token.hasSuffix(":") { token.append(character) }
                    else { flush(); tokens.append(String(character)) }
                } else if !quoted && character == "!" && token.isEmpty { tokens.append("!") }
                else if !quoted && character.isWhitespace { flush() }
                else { token.append(character) }
            }
            flush()
            if quoted { error = "Unclosed quotation mark" }
        }
        mutating func parse() -> Expression {
            let result = parseOr()
            if position < tokens.count { error = "Unexpected \(tokens[position])" }
            return result
        }
        mutating func parseOr() -> Expression {
            var terms = [parseAnd()]
            while position < tokens.count && tokens[position] == "|" { position += 1; terms.append(parseAnd()) }
            return .or(terms)
        }
        mutating func parseAnd() -> Expression {
            var terms: [Expression] = []
            while position < tokens.count && tokens[position] != "|" && tokens[position] != ">" { terms.append(parseUnary()) }
            if terms.isEmpty && !tokens.isEmpty { error = "Missing search expression" }
            return .and(terms)
        }
        mutating func parseUnary() -> Expression {
            guard position < tokens.count else { error = "Missing search term"; return .and([]) }
            let token = tokens[position]; position += 1
            if token == "!" { return .not(parseUnary()) }
            if token == "<" {
                let group = parseOr()
                if position < tokens.count && tokens[position] == ">" { position += 1 } else { error = "Unclosed search group" }
                return group
            }
            return compile(token)
        }
        mutating func compile(_ token: String) -> Expression {
            let options: String.CompareOptions = sensitive ? [] : [.caseInsensitive]
            let regexOptions: NSRegularExpression.Options = sensitive ? [] : [.caseInsensitive]
            func contains(_ haystack: String, _ needle: String) -> Bool { haystack.range(of: needle, options: options) != nil }
            let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.count == 2 ? String(parts[0]).lowercased() : ""
            let value = parts.count == 2 ? String(parts[1]) : token
            let literal = LiteralMatcher(value, sensitive: sensitive)
            switch key {
            case "file": return .term { !$0.isDirectory && literal.matches($0.name) }
            case "folder": return .term { $0.isDirectory && literal.matches($0.name) }
            case "path", "in": return .term { literal.matches($0.path) }
            case "parent":
                let parent = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
                return .term { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == parent }
            case "ext", "extension":
                let extensions = value.components(separatedBy: ";")
                return .term { f in !f.isDirectory && extensions.contains { URL(fileURLWithPath: f.path).pathExtension.compare($0, options: options) == .orderedSame } }
            case "size":
                guard let test = numberTest(value) else { error = "Invalid size filter: \(value)"; return .and([]) }
                return .term { !$0.isDirectory && test(Double($0.size)) }
            case "dm", "date-modified":
                guard let bounds = dateBounds(value) else { error = "Invalid date. Use today, yesterday, 7days, YYYY-MM-DD or a date range."; return .and([]) }
                return .term { $0.modified >= bounds.0 && $0.modified < bounds.1 }
            case "content":
                guard !value.isEmpty else { error = "Enter text after content:"; return .and([]) }
                return .term { f in
                    guard !f.isDirectory, f.size <= 16 * 1024 * 1024,
                          let data = try? Data(contentsOf: URL(fileURLWithPath: f.path), options: .mappedIfSafe),
                          let text = String(data: data, encoding: .utf8) else { return false }
                    return contains(text, value)
                }
            default: break
            }
            let usePath = path || token.contains("/")
            var pattern: String?
            if key == "regex" { pattern = value }
            else if token.contains("*") || token.contains("?") {
                pattern = "^" + NSRegularExpression.escapedPattern(for: token).replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
            } else if whole { pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: token) + "(?![\\p{L}\\p{N}_])" }
            if let pattern {
                do {
                    let compiled = try NSRegularExpression(pattern: pattern, options: regexOptions)
                    return .term { f in
                        let text = usePath ? f.path : f.name
                        return compiled.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                    }
                } catch { self.error = "Invalid regular expression"; return .and([]) }
            }
            let plain = LiteralMatcher(token, sensitive: sensitive)
            return .term { plain.matches(usePath ? $0.path : $0.name) }
        }
        func number(_ raw: String) -> Double? {
            var text = raw.lowercased(); var factor = 1.0
            for (unit, scale) in [("gb", 1_073_741_824.0), ("mb", 1_048_576.0), ("kb", 1024.0), ("b", 1.0)] where text.hasSuffix(unit) { text.removeLast(unit.count); factor = scale; break }
            guard let value = Double(text), value.isFinite, value >= 0 else { return nil }
            return value * factor
        }
        func numberTest(_ text: String) -> ((Double) -> Bool)? {
            if text.contains("..") {
                let ends = text.components(separatedBy: "..")
                guard ends.count == 2, let low = number(ends[0]), let high = number(ends[1]), low <= high else { return nil }
                return { $0 >= low && $0 <= high }
            }
            for op in [">=", "<=", ">", "<", "="] where text.hasPrefix(op) {
                guard let value = number(String(text.dropFirst(op.count))) else { return nil }
                switch op {
                case ">=": return { $0 >= value }; case "<=": return { $0 <= value }
                case ">": return { $0 > value }; case "<": return { $0 < value }
                default: return { $0 == value }
                }
            }
            guard let value = number(text) else { return nil }; return { $0 == value }
        }
        func dateBounds(_ text: String) -> (Date, Date)? {
            let cal = Calendar.current, today = cal.startOfDay(for: Date()), lower = text.lowercased()
            if lower == "today" { return (today, cal.date(byAdding: .day, value: 1, to: today)!) }
            if lower == "yesterday" { return (cal.date(byAdding: .day, value: -1, to: today)!, today) }
            if lower.hasSuffix("days"), let days = Int(lower.dropLast(4)), days > 0 && days < 100_000 { return (cal.date(byAdding: .day, value: -days, to: Date())!, .distantFuture) }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            let ends = text.components(separatedBy: "..")
            guard let start = formatter.date(from: ends[0]) else { return nil }
            if ends.count == 1 { return (start, cal.date(byAdding: .day, value: 1, to: start)!) }
            guard ends.count == 2, let end = formatter.date(from: ends[1]), end >= start else { return nil }
            return (start, cal.date(byAdding: .day, value: 1, to: end)!)
        }
    }
}

/// Avoid Foundation collation overhead for the common ASCII filename case.
/// Non-ASCII names/queries retain Foundation's Unicode matching semantics.
private struct LiteralMatcher {
    let text: String
    let sensitive: Bool
    let bytes: [UInt8]?
    init(_ text: String, sensitive: Bool) {
        self.text = text; self.sensitive = sensitive
        let raw = Array(text.utf8)
        bytes = raw.allSatisfy { $0 < 128 } ? raw.map { sensitive ? $0 : Self.fold($0) } : nil
    }
    private static func fold(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }
    func matches(_ value: String) -> Bool {
        if text.isEmpty { return true }
        if let needle = bytes,
           let fast = value.utf8.withContiguousStorageIfAvailable({ haystack -> Bool? in
               guard haystack.allSatisfy({ $0 < 128 }) else { return nil }
               guard haystack.count >= needle.count else { return false }
               for start in 0...(haystack.count - needle.count) {
                   var offset = 0
                   while offset < needle.count {
                       let byte = haystack[start + offset]
                       if (sensitive ? byte : Self.fold(byte)) != needle[offset] { break }
                       offset += 1
                   }
                   if offset == needle.count { return true }
               }
               return false
           }), let found = fast { return found }
        return value.range(of: text, options: sensitive ? [] : [.caseInsensitive]) != nil
    }
}
