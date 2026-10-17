import XCTest
@testable import AFKCore

@MainActor final class TerminalInputBufferTests: XCTestCase {
    func testDictationReplacementIsOneOrderedPacket() async throws {
        var sent: [Data] = []
        let delivered = expectation(description: "live correction")
        let buffer = TerminalInputBuffer(send: { data, _ in sent.append(data); delivered.fulfill(); return UInt64(sent.count) }, failed: { XCTFail("Unexpected delivery failure") })
        // SwiftTerm replace(_:withText:) emits one delegate call per backspace.
        for _ in 0..<500 { XCTAssertTrue(buffer.append(Data([0x7f]))) }
        let replacement = Data("Hola, cómo estás 👋🏽".utf8)
        XCTAssertTrue(buffer.append(replacement))
        XCTAssertTrue(sent.isEmpty)
        await fulfillment(of: [delivered], timeout: 1)
        buffer.cancel()
        XCTAssertEqual(sent, [Data(repeating: 0x7f, count: 500) + replacement])
    }

    func testContinuousInputStreamsBeforeTypingStops() async throws {
        var sent = Data()
        let buffer = TerminalInputBuffer(send: { data, _ in sent.append(data); return UInt64(sent.count) }, failed: { XCTFail("Unexpected delivery failure") })
        defer { buffer.cancel() }
        for _ in 0..<100 {
            XCTAssertTrue(buffer.append(Data([0x61])))
            try await Task.sleep(for: .milliseconds(2))
            for sequence in 1...max(1, sent.count) { buffer.acknowledge(UInt64(sequence)) }
        }
        XCTAssertGreaterThan(sent.count, 0, "Continuous input must not reset the flush deadline")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sent, Data(repeating: 0x61, count: 100))
    }

    func testBoundedChunksPreserveBytesIncludingSplitUTF8() async throws {
        var sent: [Data] = []
        let delivered = expectation(description: "chunks"); delivered.expectedFulfillmentCount = 8
        let buffer = TerminalInputBuffer(send: { data, _ in sent.append(data); delivered.fulfill(); return UInt64(sent.count) }, failed: { XCTFail("Unexpected delivery failure") })
        var input = Data(repeating: 0x61, count: 8191)
        input.append(Data("é👋".utf8))
        input.append(Data(repeating: 0x7f, count: 64 * 1024 - input.count))
        XCTAssertTrue(buffer.append(input))
        XCTAssertFalse(buffer.append(Data([0x62])))
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(10))
            for sequence in 1...max(1, sent.count) { buffer.acknowledge(UInt64(sequence)) }
        }
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertTrue(sent.allSatisfy { $0.count <= 8192 })
        XCTAssertEqual(sent.reduce(Data(), +), input)
    }

    func testCancelDiscardsOldInputEvenWhenNewSessionQueuesImmediately() async throws {
        var sent: [Data] = []
        let delivered = expectation(description: "new session")
        let buffer = TerminalInputBuffer(send: { data, _ in sent.append(data); delivered.fulfill(); return UInt64(sent.count) }, failed: { XCTFail("Unexpected delivery failure") })
        buffer.append(Data("old session".utf8))
        buffer.cancel()
        buffer.append(Data("new session".utf8))
        await fulfillment(of: [delivered], timeout: 1)
        try await Task.sleep(for: .milliseconds(30))
        buffer.cancel()
        XCTAssertEqual(sent, [Data("new session".utf8)])
    }
    func testMissingAcknowledgementRetriesSameBytesAndSequence() async throws {
        var attempts: [(Data, UInt64?)] = []
        let retried = expectation(description: "retry")
        let buffer = TerminalInputBuffer(send: { data, retry in
            attempts.append((data, retry))
            if retry != nil { retried.fulfill() }
            return retry ?? 42
        }, failed: { XCTFail("Unexpected delivery failure") })
        buffer.append(Data("hello\n".utf8))
        await fulfillment(of: [retried], timeout: 2)
        buffer.acknowledge(42)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(attempts.count, 2)
        XCTAssertNil(attempts[0].1)
        XCTAssertEqual(attempts[1].1, 42)
        XCTAssertEqual(attempts[0].0, attempts[1].0)
        buffer.cancel()
    }

    func testNoAcknowledgementsBoundsWindowAndStopsRetries() async throws {
        var attempts = 0
        let failed = expectation(description: "delivery stopped")
        let buffer = TerminalInputBuffer(send: { _, retry in
            attempts += 1
            return retry ?? UInt64(attempts)
        }, failed: { failed.fulfill() })
        buffer.append(Data(repeating: 0x61, count: 64 * 1024))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(attempts, 4)
        XCTAssertFalse(buffer.append(Data([0x62])), "In-flight bytes still count against the bound")
        buffer.acknowledge(999) // Unsolicited ACK cannot free space.
        XCTAssertFalse(buffer.append(Data([0x62])))
        await fulfillment(of: [failed], timeout: 4)
        XCTAssertEqual(attempts, 6) // Four initial packets, two retries of the oldest.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(attempts, 6)
    }

    func testLaterAcknowledgementDoesNotDiscardEarlierUnconfirmedInput() async throws {
        var next: UInt64 = 0
        var retries: [UInt64] = []
        let retried = expectation(description: "earlier packet retried")
        let buffer = TerminalInputBuffer(send: { _, retry in
            if let retry { retries.append(retry); retried.fulfill(); return retry }
            next += 1; return next
        }, failed: { XCTFail("Unexpected delivery failure") })
        buffer.append(Data(repeating: 0x61, count: 16384))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(next, 2)
        buffer.acknowledge(2)
        XCTAssertTrue(buffer.hasPendingInput)
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertEqual(retries, [1])
        buffer.acknowledge(1)
        XCTAssertFalse(buffer.hasPendingInput)
        buffer.cancel()
    }

    func testDisconnectCancelsInFlightRetries() async throws {
        var sends = 0
        let buffer = TerminalInputBuffer(send: { _, _ in sends += 1; return UInt64(sends) },
                                         failed: { XCTFail("Cancelled input must not time out") })
        buffer.append(Data("old session\n".utf8))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sends, 1)
        buffer.cancel()
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(sends, 1)
        XCTAssertFalse(buffer.hasPendingInput)
    }
}
