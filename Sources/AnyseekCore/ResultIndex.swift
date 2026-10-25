import Foundation

public enum ResultColumn: String { case name, path, size, modified }
public actor ResultIndex {
    private var revision = -1
    private var signature = ""
    private var filtered: [FileRecord] = []
    private var sorted: [ResultColumn: [FileRecord]] = [:]
    public init() { }
    public func results(files: [FileRecord], revision: Int, signature: String, column: ResultColumn, descending: Bool, matches: (FileRecord) -> Bool) throws -> [FileRecord] {
        try Task.checkCancellation()
        if self.revision != revision || self.signature != signature {
            var next: [FileRecord] = []; next.reserveCapacity(files.count)
            for (i, file) in files.enumerated() {
                if i % 1024 == 0 { try Task.checkCancellation() }
                if matches(file) { next.append(file) }
            }
            self.revision = revision; self.signature = signature; filtered = next; sorted.removeAll(keepingCapacity: true)
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
    private func order(_ files: [FileRecord], by column: ResultColumn) -> [FileRecord] {
        switch column {
        case .size: return files.sorted { $0.size == $1.size ? $0.path < $1.path : $0.size < $1.size }
        case .modified: return files.sorted { $0.modified == $1.modified ? $0.path < $1.path : $0.modified < $1.modified }
        case .name: return files.sorted { $0.name == $1.name ? $0.path < $1.path : $0.name < $1.name }
        case .path: return files.sorted { $0.path < $1.path }
        }
    }
}
