import XCTest
@testable import AnyseekCore
final class ResultIndexTests: XCTestCase {
    func testOrderCacheAndInvalidation() async throws {
        let files = [FileRecord(path: "/b", isDirectory: false, size: 2, modified: Date(timeIntervalSince1970: 1)), FileRecord(path: "/a", isDirectory: false, size: 1, modified: Date(timeIntervalSince1970: 2))]
        let index = ResultIndex()
        let first = try await index.results(files: files, revision: 1, signature: "all", column: .size, descending: false) { _ in true }
        XCTAssertEqual(first.map(\.name), ["a", "b"])
        try await index.warm()
        let reverse = try await index.results(files: files, revision: 1, signature: "all", column: .size, descending: true) { _ in XCTFail("Sort clicks must not refilter"); return false }
        XCTAssertEqual(reverse.map(\.name), ["b", "a"])
        let filtered = try await index.results(files: files, revision: 1, signature: "b", column: .modified, descending: false) { $0.name == "b" }
        XCTAssertEqual(filtered.map(\.name), ["b"])
        let updated = try await index.results(files: [], revision: 2, signature: "b", column: .size, descending: false) { _ in true }
        XCTAssertTrue(updated.isEmpty)
    }
    func testMillionRecordCachedSort() async throws {
        let files = (0..<1_000_000).map { i in FileRecord(path: "/files/\(i)", isDirectory: false, size: Int64((i &* 7919) % 1_000_003), modified: Date(timeIntervalSince1970: Double(i))) }
        let index = ResultIndex()
        let start = Date()
        let ordered = try await index.results(files: files, revision: 1, signature: "all", column: .size, descending: false) { _ in true }
        XCTAssertEqual(ordered.count, files.count)
        for i in 1..<ordered.count { if ordered[i - 1].size > ordered[i].size { XCTFail("Incorrect size ordering"); break } }
        let prepared = Date()
        let cached = try await index.results(files: files, revision: 1, signature: "all", column: .size, descending: false) { _ in XCTFail("Cached request refiltered"); return false }
        let reversed = try await index.results(files: files, revision: 1, signature: "all", column: .size, descending: true) { _ in false }
        XCTAssertEqual(cached.first, ordered.first); XCTAssertEqual(reversed.first, ordered.last)
        print("SORT BENCHMARK 1000000: initial=\(prepared.timeIntervalSince(start))s cached+reverse=\(Date().timeIntervalSince(prepared))s")
    }
}
extension ResultIndexTests {
    func testLiveDeletionAndUpdatesKeepSortedCaches() async throws {
        let a = FileRecord(path: "/folder/a", isDirectory: false, size: 1, modified: .distantPast)
        let b = FileRecord(path: "/folder/b", isDirectory: false, size: 2, modified: .distantPast)
        let engine = ResultIndex()
        _ = try await engine.results(files: [a,b], revision: 1, signature: "", column: .size, descending: false) { _ in true }
        try await engine.warm()
        let removed = try await engine.results(files: [a,b], revision: 1, signature: "", column: .size, descending: false, liveToken: 1, removed: [a.path]) { _ in true }
        XCTAssertEqual(removed.map(\.path), [b.path])
        let c = FileRecord(path: "/folder/c", isDirectory: false, size: 0, modified: .distantPast)
        let added = try await engine.results(files: [a,b], revision: 1, signature: "", column: .size, descending: false, liveToken: 2, removed: [a.path], updated: [c]) { _ in true }
        XCTAssertEqual(added.map(\.path), [c.path,b.path])
        // A stale full-scan snapshot must not resurrect a deleted subtree.
        let stale = try await engine.results(files: [a,b], revision: 2, signature: "", column: .size, descending: false, liveToken: 2, removed: ["/folder"], updated: []) { _ in true }
        XCTAssertTrue(stale.isEmpty)
    }
}

extension ResultIndexTests {
    func testAllOrdersMatchReferenceWithTiesAndUnicode() async throws {
        var files: [FileRecord] = []
        for i in 0..<6000 {
            let folder = i % 2 == 0 ? "پوشه" : "Folder"
            let name = String((i * 7919) % 6001) + ".txt"
            let size = Int64(i % 17 - 8)
            let date = Date(timeIntervalSinceReferenceDate: Double(i % 23 - 11) / 2)
            files.append(FileRecord(path: "/" + folder + "/" + name, isDirectory: i % 3 == 0, size: size, modified: date))
        }
        let engine = ResultIndex()
        for column in ResultColumn.allCases {
            let expected: [FileRecord] = files.sorted { (a: FileRecord, b: FileRecord) -> Bool in
                switch column {
                case .name: return a.name == b.name ? a.path < b.path : a.name < b.name
                case .path: return a.path < b.path
                case .size: return a.size == b.size ? a.path < b.path : a.size < b.size
                case .modified: return a.modified == b.modified ? a.path < b.path : a.modified < b.modified
                }
            }
            let all = try await engine.results(files: files, revision: 1, signature: "all", column: column, descending: false) { _ in true }
            XCTAssertEqual(Array(all), expected)
            for i in stride(from: 0, to: all.count, by: 37) { XCTAssertEqual(all.position(of: all[i]), i) }
            let subset = try await engine.results(files: files, revision: 1, signature: "folders", column: column, descending: true) { $0.isDirectory }
            XCTAssertEqual(Array(subset), Array(expected.filter(\.isDirectory).reversed()))
            for i in stride(from: 0, to: subset.count, by: 37) { XCTAssertEqual(subset.position(of: subset[i]), i) }
            // Old snapshots must remain valid after query and overlay changes.
            XCTAssertEqual(Array(all), expected)
        }
    }
    func testLiveReplacementRecreationAndSnapshotIsolation() async throws {
        let a = FileRecord(path: "/a", isDirectory: false, size: 1, modified: .distantPast)
        let b = FileRecord(path: "/b", isDirectory: false, size: 2, modified: .distantPast)
        let replacement = FileRecord(path: "/a", isDirectory: false, size: 3, modified: .distantFuture)
        let engine = ResultIndex()
        let before = try await engine.results(files: [a,b], revision: 1, signature: "all", column: .size, descending: false) { _ in true }
        let after = try await engine.results(files: [a,b], revision: 1, signature: "all", column: .size, descending: false, liveToken: 1, removed: ["/a"], updated: [replacement]) { _ in true }
        XCTAssertEqual(Array(before), [a,b]); XCTAssertEqual(Array(after), [b,replacement])
        let small = try await engine.results(files: [a,b], revision: 1, signature: "small", column: .size, descending: false, liveToken: 1, removed: ["/a"], updated: [replacement]) { $0.size < 3 }
        XCTAssertEqual(Array(small), [b])
    }
    func testCancellationDoesNotPoisonCachedQuery() async throws {
        let files = (0..<10000).map { FileRecord(path: "/\($0)", isDirectory: false, size: Int64($0), modified: .distantPast) }
        let engine = ResultIndex()
        _ = try await engine.results(files: files, revision: 1, signature: "all", column: .size, descending: false) { _ in true }
        let cancelled = Task {
            try await engine.results(files: files, revision: 1, signature: "none", column: .name, descending: false) { _ in
                withUnsafeCurrentTask { $0?.cancel() }; return false
            }
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let restored = try await engine.results(files: files, revision: 1, signature: "all", column: .size, descending: false) { _ in true }
        XCTAssertEqual(restored.count, files.count)
    }
    func testMillionRecordInteractiveWorkload() async throws {
        let files = (0..<1_000_000).map { i in FileRecord(path: "/files/Report-\(i).txt", isDirectory: false, size: Int64((i &* 7919) % 1_000_003), modified: Date(timeIntervalSince1970: Double(i))) }
        let engine = ResultIndex()
        func seconds(_ start: Date) -> Double { Date().timeIntervalSince(start) }
        var start = Date()
        _ = try await engine.results(files: files, revision: 1, signature: "all", column: .size, descending: false) { _ in true }
        let first = seconds(start); start = Date()
        for i in 0..<100 {
            let rows = try await engine.results(files: files, revision: 1, signature: "all", column: .size, descending: i % 2 == 0) { _ in XCTFail("Unexpected refilter"); return false }
            XCTAssertEqual(rows.count, files.count); _ = rows[500000]
        }
        let toggles = seconds(start); start = Date()
        let parser = SearchQuery("Report-123")
        let found = try await engine.results(files: files, revision: 1, signature: "Report-123", column: .size, descending: false) { parser.matches($0) }
        let search = seconds(start); start = Date()
        XCTAssertEqual(found.count, 1111)
        let updated = FileRecord(path: "/files/new.txt", isDirectory: false, size: 0, modified: .distantFuture)
        let live = try await engine.results(files: files, revision: 1, signature: "all", column: .size, descending: false, liveToken: 1, removed: [files[0].path], updated: [updated]) { _ in true }
        XCTAssertEqual(live.count, files.count); XCTAssertEqual(live.first?.path, updated.path)
        print("INTERACTIVE BENCHMARK 1000000: first-size=\(first)s 100-direction-toggles=\(toggles)s filename-query=\(search)s query+live-patch=\(seconds(start))s")
    }
}

extension ResultIndexTests {
    func testDenseEqualSizesFromPersistedPathOrder() async throws {
        let files = (0..<200000).map { FileRecord(path: "/Users/test/Library/Deep/" + String(format: "%08d", $0), isDirectory: true, size: 0, modified: .distantPast) }
        let engine = ResultIndex()
        let rows = try await engine.results(files: files, revision: 1, signature: "all", column: .size, descending: false) { _ in true }
        XCTAssertEqual(Array(rows), files)
    }
}

extension ResultIndexTests {
    func testRefinementBackspaceOptionsAndLiveReplacement() async throws {
        let files = ["/a/report.txt", "/b/reporting.txt", "/c/other.txt"].map {
            FileRecord(path: $0, isDirectory: false, size: 1, modified: .distantPast)
        }
        let engine = ResultIndex()
        var visits = 0
        _ = try await engine.results(files: files, revision: 1, signature: "rep", column: .name, descending: false, refinement: "name\0rep") {
            visits += 1; return $0.name.contains("rep")
        }
        XCTAssertEqual(visits, 3)
        visits = 0
        let replacement = FileRecord(path: "/c/other.txt", isDirectory: false, size: 9, modified: .distantPast)
        let refined = try await engine.results(files: files, revision: 1, signature: "reporting", column: .size, descending: false, liveToken: 1, updated: [replacement], refinement: "name\0reporting") {
            visits += 1; return $0.name.contains("reporting")
        }
        XCTAssertEqual(refined.map(\.path), ["/b/reporting.txt"])
        XCTAssertEqual(visits, 3, "Two previous base matches and one overlay record")
        visits = 0
        let broad = try await engine.results(files: files, revision: 1, signature: "r", column: .path, descending: false, liveToken: 1, updated: [replacement], refinement: "name\0r") {
            visits += 1; return $0.name.contains("r")
        }
        XCTAssertEqual(broad.count, 3)
        XCTAssertEqual(visits, 4, "Backspace must inspect the full base plus overlay")
        let changedOptions = try await engine.results(files: files, revision: 1, signature: "path", column: .path, descending: false, refinement: "path\0report") { $0.path.contains("/c/") }
        XCTAssertEqual(changedOptions.map(\.path), ["/c/other.txt"])
    }

    func testSortedLiveSubtreesAndSiblingBoundaries() async throws {
        let files = ["/a", "/a-keep", "/a/one", "/a/sub/two", "/ab/keep", "/کشتی/بار"].map {
            FileRecord(path: $0, isDirectory: false, size: 0, modified: .distantPast)
        }.sorted { $0.path < $1.path }
        let engine = ResultIndex()
        let before = try await engine.results(files: files, revision: 1, signature: "all", column: .path, descending: false) { _ in true }
        let after = try await engine.results(files: files, revision: 1, signature: "all", column: .path, descending: false, liveToken: 1, removed: ["/a"]) { _ in XCTFail("Live deletion must not refilter"); return true }
        XCTAssertEqual(after.map(\.path), ["/a-keep", "/ab/keep", "/کشتی/بار"])
        XCTAssertEqual(before.count, 6)
        let empty = try await engine.results(files: files, revision: 1, signature: "all", column: .path, descending: false, liveToken: 2, removed: ["/"]) { _ in true }
        XCTAssertTrue(empty.isEmpty)
    }

    func testColdSparseQueryAndRefinementBenchmark() async throws {
        let files = (0..<1_000_000).map {
            FileRecord(path: "/files/Report-\($0).txt", isDirectory: false, size: Int64($0), modified: .distantPast)
        }
        let engine = ResultIndex()
        var previous = Date()
        for (text, expected) in [("Report-123", 1111), ("Report-1234", 111), ("Report-12345", 11)] {
            let query = SearchQuery(text)
            let rows = try await engine.results(files: files, revision: 1, signature: text, column: .name, descending: false, refinement: query.refinementLiteral) { query.matches($0) }
            XCTAssertEqual(rows.count, expected)
            let elapsed = Date().timeIntervalSince(previous)
            print("COLD/REFINE BENCHMARK 1000000: \(text)=\(elapsed)s")
            #if !DEBUG
            // Regression guards, not a guarantee for arbitrary hardware/data.
            XCTAssertLessThan(elapsed, text == "Report-123" ? 0.5 : 0.1)
            #endif
            previous = Date()
        }
    }
}
