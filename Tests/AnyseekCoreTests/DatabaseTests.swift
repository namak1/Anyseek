import XCTest
@testable import AnyseekCore
final class DatabaseTests: XCTestCase {
    func testAtomicSubtreeReplacementAndLiteralNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try IndexDatabase(url: folder.appendingPathComponent("index.sqlite"))
        let paths = ["/data/a/one", "/data/ab/two", "/data/100%/three", "/data/100x/four"]
        try db.replace(scopes: [], records: paths.map { FileRecord(path: $0, isDirectory: false, size: 1, modified: .distantPast) })
        try db.replace(scopes: ["/data/a", "/data/100%"], records: [])
        XCTAssertEqual(try db.load().map(\.path), ["/data/100x/four", "/data/ab/two"])
        try db.replace(scopes: ["/"], records: [])
        XCTAssertTrue(try db.load().isEmpty)
    }
    func testPersistenceAndMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("index.sqlite")
        let file = FileRecord(path: "/فارسی/کشتی.pdf", isDirectory: false, size: 900, modified: Date(timeIntervalSince1970: 123456))
        do { let db = try IndexDatabase(url: url); try db.replace(scopes: [], records: [file]) }
        let reopened = try IndexDatabase(url: url)
        XCTAssertEqual(try reopened.load(), [file])
    }
    func testScopes() {
        XCTAssertTrue(PathScope.contains("/", "/Users/a"))
        XCTAssertFalse(PathScope.contains("/a", "/ab/file"))
        XCTAssertEqual(PathScope.compact(["/a", "/a/b", "/ab", "/a"]), ["/a", "/ab"])
    }
}
