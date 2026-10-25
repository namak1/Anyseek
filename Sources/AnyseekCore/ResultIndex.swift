import Foundation

public enum ResultColumn: String, CaseIterable { case name, path, size, modified }

/// Immutable table snapshot. Rows share metadata and store only integer references.
/// Changing direction is O(1), including for multi-million-row results.
public struct ResultRows: RandomAccessCollection {
    public typealias Index = Int
    public typealias Element = FileRecord
    private let base: [FileRecord]
    private let overlay: [FileRecord]
    private let rows: [Int]
    private let descending: Bool
    private let column: ResultColumn
    public static let empty = ResultRows(base: [], overlay: [], rows: [], descending: false, column: .name)
    fileprivate init(base: [FileRecord], overlay: [FileRecord], rows: [Int], descending: Bool, column: ResultColumn) {
        self.base = base; self.overlay = overlay; self.rows = rows; self.descending = descending; self.column = column
    }
    public var startIndex: Int { 0 }
    public var endIndex: Int { rows.count }
    public subscript(position: Int) -> FileRecord {
        let id = rows[descending ? rows.count - 1 - position : position]
        return id < base.count ? base[id] : overlay[id - base.count]
    }
    /// Locate an unchanged selected record in O(log n), in either direction.
    /// Callers may fall back to a path scan if live metadata has changed.
    public func position(of record: FileRecord) -> Int? {
        func precedes(_ a: FileRecord, _ b: FileRecord) -> Bool {
            switch column {
            case .size: return a.size == b.size ? a.path < b.path : a.size < b.size
            case .modified: return a.modified == b.modified ? a.path < b.path : a.modified < b.modified
            case .name: return a.name == b.name ? a.path < b.path : a.name < b.name
            case .path: return a.path < b.path
            }
        }
        var low = startIndex, high = endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if descending ? precedes(record, self[middle]) : precedes(self[middle], record) { low = middle + 1 }
            else { high = middle }
        }
        return low < endIndex && self[low].path == record.path ? low : nil
    }
    public func removing(where predicate: (FileRecord) -> Bool) -> ResultRows {
        let kept = rows.filter { id in !predicate(id < base.count ? base[id] : overlay[id - base.count]) }
        return ResultRows(base: base, overlay: overlay, rows: kept, descending: descending, column: column)
    }
}

public actor ResultIndex {
    private var basePathOrdered = false
    private var revision = -1
    private var liveToken = -1
    private var signature: String?
    private var base: [FileRecord] = []
    private var overlay: [FileRecord] = []
    private var orders: [ResultColumn: [Int]] = [:]
    private var visible: [Bool] = []
    private var membership: [Bool] = []
    private var overlayMatches: [Int] = []
    private var queryOrders: [ResultColumn: [Int]] = [:]
    public init() { }

    public func results(files: [FileRecord], revision: Int, signature: String, column: ResultColumn, descending: Bool, liveToken: Int = 0, removed: Set<String> = [], updated: [FileRecord] = [], matches: (FileRecord) -> Bool) throws -> ResultRows {
        try Task.checkCancellation()
        if self.revision != revision {
            base = files; orders.removeAll(); queryOrders.removeAll()
            basePathOrdered = true
            for i in base.indices.dropFirst() {
                if i & 4095 == 0 { try Task.checkCancellation() }
                if base[i].path < base[i - 1].path { basePathOrdered = false; break }
            }
            self.revision = revision; self.signature = nil; self.liveToken = -1
        }
        let queryChanged = self.signature != signature
        let liveChanged = self.liveToken != liveToken
        if queryChanged {
            self.signature = nil
            var next = [Bool](); next.reserveCapacity(base.count)
            for i in base.indices {
                if i & 4095 == 0 { try Task.checkCancellation() }
                next.append(matches(base[i]))
            }
            membership = next
        }
        if liveChanged {
            self.liveToken = -1
            let scopes = PathScope.compact(Array(removed)), scopeSet = Set(scopes)
            let changed = Set(updated.map(\.path))
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
            var next = [Bool](); next.reserveCapacity(base.count)
            for i in base.indices {
                if i & 4095 == 0 { try Task.checkCancellation() }
                next.append(!changed.contains(base[i].path) && !deleted(base[i].path))
            }
            visible = next; overlay = updated
        }
        if queryChanged || liveChanged {
            // Commit tokens only after cancellable work completes. A cancelled request
            // must never mark a partially built cache as usable by the next request.
            overlayMatches = overlay.indices.filter { matches(overlay[$0]) }
            self.signature = signature; self.liveToken = liveToken; queryOrders.removeAll()
        }
        if queryOrders[column] == nil {
            if orders[column] == nil { orders[column] = try order(base, column: column) }
            let order = orders[column]!
            var selected = [Int](); selected.reserveCapacity(min(base.count, 65536))
            for (offset, id) in order.enumerated() {
                if offset & 4095 == 0 { try Task.checkCancellation() }
                if membership[id] && visible[id] { selected.append(id) }
            }
            let incoming = overlayMatches.sorted { precedes(overlay[$0], overlay[$1], column) }
            if !incoming.isEmpty {
                var merged = [Int](); merged.reserveCapacity(selected.count + incoming.count)
                var i = 0, j = 0
                while i < selected.count && j < incoming.count {
                    if (i + j) & 4095 == 0 { try Task.checkCancellation() }
                    if precedes(base[selected[i]], overlay[incoming[j]], column) { merged.append(selected[i]); i += 1 }
                    else { merged.append(base.count + incoming[j]); j += 1 }
                }
                merged.append(contentsOf: selected[i...])
                merged.append(contentsOf: incoming[j...].map { base.count + $0 })
                selected = merged
            }
            try Task.checkCancellation()
            queryOrders[column] = selected
        }
        return ResultRows(base: base, overlay: overlay, rows: queryOrders[column]!, descending: descending, column: column)
    }

    /// Explicit preparation for benchmarks; the UI does not enqueue speculative
    /// work that could hold this actor ahead of an interactive search.
    public func warm() throws {
        for column in [ResultColumn.size, .modified] where orders[column] == nil {
            orders[column] = try order(base, column: column)
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
    private func order(_ files: [FileRecord], column: ResultColumn) throws -> [Int] {
        guard files.count > 1 else { return Array(files.indices) }
        if column == .size || column == .modified {
            // Eight stable byte passes replace O(n log n) numeric comparisons.
            let keys: [UInt64] = files.map {
                if column == .size { return UInt64(bitPattern: $0.size) ^ (1 << 63) }
                let value = $0.modified.timeIntervalSinceReferenceDate
                let bits = (value == 0 ? 0.0 : value).bitPattern
                return bits & (1 << 63) == 0 ? bits ^ (1 << 63) : ~bits
            }
            var ids = Array(files.indices), scratch = [Int](repeating: 0, count: files.count)
            for shift in stride(from: 0, to: 64, by: 8) {
                try Task.checkCancellation()
                var counts = [Int](repeating: 0, count: 256)
                for id in ids { counts[Int((keys[id] >> shift) & 255)] += 1 }
                var total = 0
                for i in counts.indices { let count = counts[i]; counts[i] = total; total += count }
                for id in ids { let bucket = Int((keys[id] >> shift) & 255); scratch[counts[bucket]] = id; counts[bucket] += 1 }
                swap(&ids, &scratch)
            }
            // SQLite snapshots already arrive in path order. Stable radix passes
            // preserve that tie order, including millions of zero-size folders.
            if basePathOrdered { return ids }
            // Stable deterministic path ordering for unordered partial snapshots.
            var start = 0
            while start < ids.count {
                try Task.checkCancellation()
                var end = start + 1
                while end < ids.count && keys[ids[end]] == keys[ids[start]] { end += 1 }
                if end - start > 1 {
                    let tied = try mergeSort(Array(ids[start..<end])) { files[$0].path < files[$1].path }
                    ids.replaceSubrange(start..<end, with: tied)
                }
                start = end
            }
            return ids
        }
        return try mergeSort(Array(files.indices)) { precedes(files[$0], files[$1], column) }
    }
    /// Bounded sort chunks and cancellable merges let newer searches take over.
    private func mergeSort(_ input: [Int], less: (Int, Int) -> Bool) throws -> [Int] {
        let chunk = 2048
        var source = input
        for start in stride(from: 0, to: source.count, by: chunk) {
            try Task.checkCancellation()
            let end = min(start + chunk, source.count)
            source[start..<end].sort(by: less)
        }
        var target = source, width = chunk
        while width < source.count {
            for start in stride(from: 0, to: source.count, by: width * 2) {
                let middle = min(start + width, source.count), end = min(start + width * 2, source.count)
                var i = start, j = middle
                for out in start..<end {
                    if out & 4095 == 0 { try Task.checkCancellation() }
                    if i < middle && (j == end || !less(source[j], source[i])) { target[out] = source[i]; i += 1 }
                    else { target[out] = source[j]; j += 1 }
                }
            }
            swap(&source, &target); width *= 2
        }
        return source
    }
}
