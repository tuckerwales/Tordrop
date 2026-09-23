import XCTest
@testable import TorDrop

final class TorControlProtocolTests: XCTestCase {
    func testParsesRepliesSplitAcrossReads() {
        var parser = TorControlReplyParser()
        parser.append(Data("250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=45 TAG=loading\r\n250 O".utf8))
        XCTAssertNil(parser.nextReply(), "a reply is not complete until its final line ends")

        parser.append(Data("K\r\n".utf8))
        let reply = parser.nextReply()
        XCTAssertEqual(reply?.code, 250)
        XCTAssertEqual(reply?.lines, ["status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=45 TAG=loading", "OK"])
        XCTAssertNil(parser.nextReply())
    }

    func testSeparatesAsyncEventsAndDataBlocks() {
        var parser = TorControlReplyParser()
        parser.append(Data("650 HS_DESC UPLOADED abc UNKNOWN $hsdir\r\n250+data=\r\nline1\r\n..dot\r\n.\r\n250 OK\r\n".utf8))

        let event = parser.nextReply()!
        XCTAssertTrue(event.isAsyncEvent)
        let desc = TorControlParsing.hiddenServiceDescriptorEvent(in: event)
        XCTAssertEqual(desc?.action, "UPLOADED")
        XCTAssertEqual(desc?.address, "abc")

        let data = parser.nextReply()!
        XCTAssertTrue(data.isSuccess)
        XCTAssertEqual(data.lines, ["data=\nline1\n.dot", "OK"])
    }

    func testErrorAndMalformedReplies() {
        var parser = TorControlReplyParser()
        parser.append(Data("552 Unrecognized key\r\ngarbage\r\n".utf8))
        let error = parser.nextReply()!
        XCTAssertEqual(error.code, 552)
        XCTAssertFalse(error.isSuccess)
        XCTAssertEqual(parser.nextReply()?.code, 0)
    }

    func testServiceIDAndControlPort() {
        var parser = TorControlReplyParser()
        parser.append(Data("250-ServiceID=abcdef\r\n250 OK\r\n".utf8))
        XCTAssertEqual(TorControlParsing.serviceID(in: parser.nextReply()!), "abcdef")

        XCTAssertEqual(TorControlParsing.controlPort(inPortFile: "PORT=127.0.0.1:58739\n"), 58739)
        XCTAssertNil(TorControlParsing.controlPort(inPortFile: "PORT="))
        XCTAssertNil(TorControlParsing.controlPort(inPortFile: ""))
    }

    func testBootstrapStatus() {
        let status = TorBootstrapStatus(
            line: #"status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=45 TAG=loading SUMMARY="Loading \"relay\" descs""#)
        XCTAssertEqual(status, TorBootstrapStatus(progress: 45, tag: "loading", summary: #"Loading "relay" descs"#))
        XCTAssertFalse(status!.isDone)

        XCTAssertTrue(TorBootstrapStatus(line: #"NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY="Done""#)!.isDone)
        XCTAssertNil(TorBootstrapStatus(line: "no progress here"))
    }
}
