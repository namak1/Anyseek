import Foundation

public enum ResultColumn: String { case name, path, size, modified }
public actor ResultIndex {
    private var liveToken = -1
    private var revision = -1
    private var signature = ""
    private var filtered: [FileRecord] = []
    private var sorted: [ResultColumn: [FileRecord]] = [:]
    public init() { }
    public func results(files: [FileRecord], revision: Int, signature: String, column: ResultColumn, descending: Bool, liveToken: Int = 0, removed: Set<String> = [], updated: [FileRecord] = [], matches: (FileRecord) -> Bool) throws -> [FileRecord] {
        try Task.checkCancellation()
        if self.revision != revision || self.signature != signature {
            var next: [FileRecord] = []; next.reserveCapacity(files.count)
            for (i, file) in files.enumerated() {
                if i % 1024 == 0 { try Task.checkCancellation() }
                if matches(file) { next.append(file) }
            }
            self.revision = revision; self.signature = signature; filtered = next; self.liveToken = -1; sorted.removeAll(keepingCapacity: true)
        }
        if self.liveToken != liveToken {
            self.liveToken = liveToken
            let scopes = PathScope.compact(Array(removed))
            let changed = Set(updated.map(\.path))
            let scopeSet = Set(scopes)
            func deleted(_ path: String) -> Bool {
                if scopes.count <= 8 { return scopes.contains { PathScope.contains($0, path) } }
                var candidate = path[...]
                while !candidate.isEmpty {
                    if scopeSet.contains(String(candidate)) { return true }
                    guard let slash = candidate.lastIndex(of: "/") else { break }
                    candidate = candidate[..<slash]
                }
                return scopeSet.contains("/")
            }
            func keep(_ file: FileRecord) -> Bool { !changed.contains(file.path) && !deleted(file.path) }
            let additions = updated.filter(matches)
            filtered = filtered.filter(keep) + additions
            for key in Array(sorted.keys) {
                var values = sorted[key]!.filter(keep)
                let incoming = order(additions, by: key)
                if !incoming.isEmpty {
                    var merged: [FileRecord] = []; merged.reserveCapacity(values.count + incoming.count)
                    var i = 0, j = 0
                    while i < values.count && j < incoming.count {
                        if precedes(values[i], incoming[j], key) { merged.append(values[i]); i += 1 }
                        else { merged.append(incoming[j]); j += 1 }
                    }
                    merged.append(contentsOf: values[i...]); merged.append(contentsOf: incoming[j...]); values = merged
                }
                sorted[key] = values
            }
        }
        if sorted[column] == nil { sorted[column] = order(filtered, by: column) }
        try Task.checkCancellation()
        let result = sorted[column]!
        return descending ? Array(result.reversed()) : result
    }
    /// Prepare the expensive orders once per result set, off the main thread.
    public func warm() throws {
        for column in [ResultColumn.size, .modified] where sorted[column] == nil {
            try Task.checkCancellation(); sorted[column] = order(filtered, by: column)
        }
    }
    private func precedes(_ a: FileRecord, _ b: FileRecord, _ column: ResultColumn) -> Bool {
        switch column {
        case .size: return a.size == b.size ? a.path < b.path : a.size < b.size
        case .modified: return a.modified == b.modified ? a.path < b.path : a.modified < b.modified
        case .name: return a.name == b.name ? a.path < b.path : a.name < b.name
        case .path: return a.path < b.path
        }
    }
    private func order(_ files: [FileRecord], by column: ResultColumn) -> [FileRecord] {
        switch column {
        case .size: return files.sorted { $0.size == $1.size ? $0.path < $1.path : $0.size < $1.size }
        case .modified: return files.sorted { $0.modified == $1.modified ? $0.path < $1.path : $0.modified < $1.modified }
        case .name: return files.sorted { $0.name == $1.name ? $0.path < $1.path : $0.name < $1.name }
        case .path: return files.sorted { $0.path < $1.path }
        }
    }
}
