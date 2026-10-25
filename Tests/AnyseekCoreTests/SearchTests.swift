import XCTest
@testable import AnyseekCore
final class SearchTests: XCTestCase {
    let pdf = FileRecord(path: "/Users/sam/Invoices/Flora invoice.pdf", isDirectory: false, size: 2_097_152, modified: Date())
    func testCombinedFilters() {
        XCTAssertTrue(SearchQuery("flora ext:pdf size:>1mb !draft").matches(pdf))
        XCTAssertFalse(SearchQuery("flora ext:mp4").matches(pdf))
        XCTAssertFalse(SearchQuery("size:>3mb").matches(pdf))
    }
    func testQuotesAndOr() {
        XCTAssertTrue(SearchQuery("\"Flora invoice\" | missing").matches(pdf))
        XCTAssertFalse(SearchQuery("\"invoice Flora\"").matches(pdf))
    }
    func testWildcardsAndRegex() {
        XCTAssertTrue(SearchQuery("*.pdf").matches(pdf))
        XCTAssertTrue(SearchQuery("regex:^Flora").matches(pdf))
        XCTAssertFalse(SearchQuery("regex:[").matches(pdf))
    }
    func testPathAndCase() {
        XCTAssertFalse(SearchQuery("Invoices").matches(pdf))
        XCTAssertTrue(SearchQuery("path:Invoices").matches(pdf))
        XCTAssertFalse(SearchQuery("flora", caseSensitive: true).matches(pdf))
    }
    func testFolderAndInvalidSize() {
        let folder = FileRecord(path: "/Users/sam/Invoices", isDirectory: true, size: 0, modified: Date())
        XCTAssertTrue(SearchQuery("folder:invoice").matches(folder))
        XCTAssertFalse(SearchQuery("file:").matches(folder))
        XCTAssertFalse(SearchQuery("size:banana").matches(pdf))
    }
}
extension SearchTests {
    func testGroupedBooleanSearch() {
        XCTAssertTrue(SearchQuery("<ext:pdf | ext:docx> flora !draft").matches(pdf))
        XCTAssertFalse(SearchQuery("!<ext:pdf | ext:docx>").matches(pdf))
        XCTAssertFalse(SearchQuery("<flora").matches(pdf))
        XCTAssertNotNil(SearchQuery("flora |").error)
    }
    func testRangesAndWholeWords() {
        XCTAssertTrue(SearchQuery("size:1mb..3mb dm:today").matches(pdf))
        XCTAssertTrue(SearchQuery("size:>=2mb").matches(pdf))
        XCTAssertTrue(SearchQuery("size:<=2mb").matches(pdf))
        XCTAssertFalse(SearchQuery("size:2mb..1mb").matches(pdf))
        XCTAssertTrue(SearchQuery("Flora", wholeWord: true).matches(pdf))
        XCTAssertFalse(SearchQuery("Flor", wholeWord: true).matches(pdf))
        XCTAssertTrue(SearchQuery("^Flora.*pdf$", regex: true).matches(pdf))
    }
    func testTextContent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "Shipping notice for Flora".write(to: url, atomically: true, encoding: .utf8)
        let file = FileRecord(path: url.path, isDirectory: false, size: 25, modified: Date())
        XCTAssertTrue(SearchQuery("content:\"shipping notice\"").matches(file))
        XCTAssertFalse(SearchQuery("content:missing").matches(file))
        XCTAssertNotNil(SearchQuery("\"unclosed").error)
    }
    func testPersianAndQuotedOperators() {
        let file = FileRecord(path: "/Users/sam/صورت حساب.pdf", isDirectory: false, size: 10, modified: Date())
        XCTAssertTrue(SearchQuery("\"صورت حساب\" ext:pdf").matches(file))
        XCTAssertFalse(SearchQuery("ext:pdfx").matches(file))
    }
}

extension SearchTests {
    func testLiteralFastPathPreservesUnicodeSemantics() {
        for name in ["Report-123.txt", "REPORT.txt", "گزارش.txt", "café.txt", "cafe\u{301}.txt", "Kelvin.txt", "Straße.txt"] {
            let file = FileRecord(path: "/Folder/" + name, isDirectory: false, size: 0, modified: .distantPast)
            for term in ["report", "REPORT", "txt", "گزارش", "café", "kelvin", "strasse", "missing"] {
                for sensitive in [false, true] {
                    let expected = name.range(of: term, options: sensitive ? [] : [.caseInsensitive]) != nil
                    XCTAssertEqual(SearchQuery(term, caseSensitive: sensitive).matches(file), expected, "\(name) / \(term)")
                }
            }
        }
    }
}
