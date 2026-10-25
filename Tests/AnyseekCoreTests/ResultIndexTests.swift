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
