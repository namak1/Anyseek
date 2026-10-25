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
