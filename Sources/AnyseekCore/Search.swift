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

/// Everything-style AND, OR, exclusion, quoted phrases and common property filters.
public struct SearchQuery {
    private let groups: [[String]]
    public let caseSensitive: Bool
    public let matchPath: Bool
    public init(_ text: String, caseSensitive: Bool = false, matchPath: Bool = false) {
        self.caseSensitive = caseSensitive; self.matchPath = matchPath
        var groups: [[String]] = [[]]; var token = ""; var quoted = false
        func flush() { if !token.isEmpty { groups[groups.count - 1].append(token); token = "" } }
        for c in text {
            if c == "\"" { quoted.toggle() }
            else if !quoted && c == "|" { flush(); groups.append([]) }
            else if !quoted && c.isWhitespace { flush() }
            else { token.append(c) }
        }
        flush(); self.groups = groups
    }
    public func matches(_ file: FileRecord) -> Bool {
        groups.contains { group in group.allSatisfy { raw in
            let negated = raw.hasPrefix("!")
            let token = negated ? String(raw.dropFirst()) : raw
            let result = match(token, file)
            return negated ? !result : result
        } }
    }
    private func contains(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: caseSensitive ? [] : [.caseInsensitive]) != nil
    }
    private func match(_ token: String, _ f: FileRecord) -> Bool {
        let lower = token.lowercased()
        if lower.hasPrefix("file:") { return !f.isDirectory && contains(f.name, String(token.dropFirst(5))) }
        if lower.hasPrefix("folder:") { return f.isDirectory && contains(f.name, String(token.dropFirst(7))) }
        if lower.hasPrefix("path:") { return contains(f.path, String(token.dropFirst(5))) }
        if lower.hasPrefix("ext:") {
            return !f.isDirectory && token.dropFirst(4).split(separator: ";").contains { containsExact(URL(fileURLWithPath: f.path).pathExtension, String($0)) }
        }
        if lower.hasPrefix("size:") {
            guard !f.isDirectory else { return false }
            var value = String(lower.dropFirst(5)); let op = value.first
            if op == ">" || op == "<" || op == "=" { value.removeFirst() }
            let units: [(String, Double)] = [("gb", 1_073_741_824), ("mb", 1_048_576), ("kb", 1024), ("b", 1)]
            var multiplier = 1.0
            for (suffix, factor) in units where value.hasSuffix(suffix) { value.removeLast(suffix.count); multiplier = factor; break }
            guard let amount = Double(value), amount >= 0 else { return false }
            let threshold = amount * multiplier
            if op == ">" { return Double(f.size) > threshold }
            if op == "<" { return Double(f.size) < threshold }
            return Double(f.size) == threshold
        }
        if lower == "dm:today" { return Calendar.current.isDateInToday(f.modified) }
        if lower.hasPrefix("regex:") {
            guard let regex = try? NSRegularExpression(pattern: String(token.dropFirst(6)), options: caseSensitive ? [] : [.caseInsensitive]) else { return false }
            let text = matchPath ? f.path : f.name
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        let text = matchPath || token.contains("/") ? f.path : f.name
        if token.contains("*") || token.contains("?") {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: token).replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        return contains(text, token)
    }
    private func containsExact(_ a: String, _ b: String) -> Bool { caseSensitive ? a == b : a.lowercased() == b.lowercased() }
}
