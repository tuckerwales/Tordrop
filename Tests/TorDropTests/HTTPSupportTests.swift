import XCTest
@testable import TorDrop

final class HTTPSupportTests: XCTestCase {
    func testRequestHeadParsing() {
        let head = HTTPRequestHead("GET /abc/My%20File.txt?x=1#f HTTP/1.1\r\nHost: foo\r\nRange: bytes=0-")
        XCTAssertEqual(head?.method, "GET")
        XCTAssertEqual(head?.path, "/abc/My File.txt")
        XCTAssertEqual(head?.headers["range"], "bytes=0-")
        XCTAssertEqual(head?.headers["host"], "foo")

        XCTAssertNil(HTTPRequestHead("GET"))
        XCTAssertNil(HTTPRequestHead("GET http://example.com/ HTTP/1.1"))
    }

    func testByteRanges() {
        XCTAssertEqual(HTTPByteRange.evaluate(nil, size: 100), .full)
        XCTAssertEqual(HTTPByteRange.evaluate("bytes=0-", size: 100), .partial(start: 0, end: 99))
        XCTAssertEqual(HTTPByteRange.evaluate("bytes=10-19", size: 100), .partial(start: 10, end: 19))
        XCTAssertEqual(HTTPByteRange.evaluate("bytes=90-200", size: 100), .partial(start: 90, end: 99))
        XCTAssertEqual(HTTPByteRange.evaluate("bytes=-10", size: 100), .partial(start: 90, end: 99))
        XCTAssertEqual(HTTPByteRange.evaluate("bytes=-500", size: 100), .partial(start: 0, end: 99))
        XCTAssertEqual(HTTPByteRange.evaluate("bytes=100-", size: 100), .unsatisfiable)
        XCTAssertEqual(HTTPByteRange.evaluate("bytes=-0", size: 100), .unsatisfiable)
        XCTAssertEqual(HTTPByteRange.evaluate("bytes=0-", size: 0), .unsatisfiable)
        // Invalid or unsupported headers are ignored.
        XCTAssertEqual(HTTPByteRange.evaluate("bytes=5-3", size: 100), .full)
        XCTAssertEqual(HTTPByteRange.evaluate("bytes=0-1,5-6", size: 100), .full)
        XCTAssertEqual(HTTPByteRange.evaluate("bytes=+5-", size: 100), .full)
        XCTAssertEqual(HTTPByteRange.evaluate("items=0-1", size: 100), .full)
    }

    func testLinksAndHeadersAreEscaped() {
        XCTAssertEqual(HTTPText.relativeHref(for: "a:b c#?.txt"), "./a:b%20c%23%3F.txt")
        XCTAssertEqual(HTTPText.htmlEscape(#"<a href='x'>&""#), "&lt;a href=&#39;x&#39;&gt;&amp;&quot;")
        XCTAssertEqual(
            HTTPText.contentDisposition(filename: #"naïve "x".txt"#),
            #"attachment; filename="na_ve _x_.txt"; filename*=UTF-8''na%C3%AFve%20%22x%22.txt"#)
    }

    func testUniqueFilenames() {
        XCTAssertEqual(HTTPText.uniqueFilename("a/b.txt", existing: []), "a_b.txt")
        XCTAssertEqual(HTTPText.uniqueFilename("a.txt", existing: ["a.txt", "a (2).txt"]), "a (3).txt")
        XCTAssertEqual(HTTPText.uniqueFilename("README", existing: ["README"]), "README (2)")
        XCTAssertEqual(HTTPText.uniqueFilename("..", existing: []), "file")
        XCTAssertEqual(HTTPText.uniqueFilename("a\nb", existing: []), "a_b")
    }

    func testRandomSlug() {
        let slug = HTTPText.randomSlug(length: 20)
        XCTAssertEqual(slug.count, 20)
        XCTAssertTrue(slug.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
        XCTAssertNotEqual(slug, HTTPText.randomSlug(length: 20))
    }
}
