import XCTest
import AFKCore

@MainActor final class RemoteAccessModelTests: XCTestCase {
    func testChunkedHistoryBeyondCapKeepsEveryByteAndHandsOffToLiveOutput() throws {
        let model = RemoteModel(), id = UUID().uuidString
        var list = Message("sessions")
        list.sessions = [SessionInfo(id: id, name: "Long", running: true, owner: "local", epoch: 1)]
        model.relay.onMessage?(list); model.attach(id)
        let transfer = try XCTUnwrap(model.historyID)
        let bytes = Data(repeating: 65, count: 32 * 1024)
        let size = TerminalSize(columns: 100, rows: 30)
        for page in 1...40 {
            var chunk = Message("historyChunk", sessionID: id)
            chunk.historyID = transfer; chunk.events = [TerminalEvent(data: bytes)]
            if page == 20 { chunk.events?.append(TerminalEvent(size: size)) }
            chunk.historyOffset = UInt64(page); chunk.historyLength = 40
            chunk.historyComplete = page == 40; chunk.sequence = 100; chunk.inputAcknowledgements = true
            model.relay.onMessage?(chunk)
            XCTAssertEqual(model.ready, page == 40)
            if page < 40 { XCTAssertFalse(model.canWrite) }
        }
        XCTAssertNil(model.feed.snapshot)
        XCTAssertEqual(model.feed.size, size)
        var live = Message("output", sessionID: id); live.sequence = 101; live.data = Data("tail".utf8).base64EncodedString()
        model.relay.onMessage?(live); model.relay.onMessage?(live)
        let reader = try TerminalHistory.Reader(XCTUnwrap(model.feed.history).entry)
        var output = Data(), sizes: [TerminalSize] = []
        while reader.offset < reader.length {
            for event in try reader.next() {
                if let data = event.data { output.append(data) }
                if let size = event.size { sizes.append(size) }
            }
        }
        XCTAssertEqual(output, Data(repeating: 65, count: 40 * bytes.count) + Data("tail".utf8))
        XCTAssertEqual(sizes, [size]); XCTAssertEqual(model.feed.sequence, 101)
        let directory = try XCTUnwrap(model.feed.history).entry.directory
        model.suspend()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testReattachAndRevocationRejectStaleHistoryChunks() throws {
        let model = RemoteModel(), id = UUID().uuidString
        var list = Message("sessions")
        list.sessions = [SessionInfo(id: id, name: "Long", running: true, owner: "local", epoch: 1)]
        model.relay.onMessage?(list); model.attach(id)
        var chunk = Message("historyChunk", sessionID: id)
        chunk.historyID = try XCTUnwrap(model.historyID)
        chunk.events = [TerminalEvent(data: Data("stale".utf8))]
        chunk.historyOffset = 1; chunk.historyLength = 1; chunk.historyComplete = true
        model.attach(id); model.relay.onMessage?(chunk)
        let currentTransfer = model.historyID
        var staleSnapshot = Message("snapshot", sessionID: UUID().uuidString); staleSnapshot.events = []
        model.relay.onMessage?(staleSnapshot)
        XCTAssertEqual(model.historyID, currentTransfer)
        XCTAssertFalse(model.ready); XCTAssertEqual(model.feed.snapshot, [])
        chunk.historyID = model.historyID
        list.sessions = []; model.relay.onMessage?(list); model.relay.onMessage?(chunk)
        XCTAssertFalse(model.ready); XCTAssertNil(model.feed.history); XCTAssertEqual(model.feed.snapshot, [])
    }

    func testOldHostRequiresUpdateForConfirmedInput() {
        let model = RemoteModel(), id = UUID().uuidString
        var info = SessionInfo(id: id, name: "Shared", running: true, owner: "", epoch: 1)
        info.canControl = true
        var list = Message("sessions"); list.sessions = [info]
        model.relay.onMessage?(list); model.attach(id)
        var snapshot = Message("snapshot", sessionID: id); snapshot.events = []
        model.relay.onMessage?(snapshot)
        XCTAssertTrue(model.ready)
        XCTAssertFalse(model.canClaim)
        XCTAssertEqual(model.sessionNotice, L10n.text("Actualiza AFK en el Mac para escribir con confirmación de entrega."))
    }

    func testExplicitExitIsDifferentFromConnectionLoss() {
        let model = RemoteModel(), id = UUID().uuidString
        var list = Message("sessions")
        list.sessions = [SessionInfo(id: id, name: "Shared", running: true, owner: "", epoch: 1)]
        model.relay.onMessage?(list); model.attach(id)
        model.relay.onMessage?(Message("exit", sessionID: id))
        XCTAssertEqual(model.terminalStatus, L10n.text("Sesión terminada"))
        model.relay.onDisconnect?()
        XCTAssertEqual(model.terminalStatus, L10n.text("Sin conexión. Reintenta para continuar."))
    }

    func testRemovedReadAccessClearsDisplayAndRejectsLateFrames() {
        let model = RemoteModel(), id = UUID().uuidString
        var info = SessionInfo(id: id, name: "Shared", running: true, owner: "", epoch: 1)
        info.canControl = true
        var list = Message("sessions"); list.sessions = [info]; list.canCreate = true
        model.relay.onMessage?(list); model.attach(id)
        var snapshot = Message("snapshot", sessionID: id); snapshot.inputAcknowledgements = true; snapshot.sequence = 1
        snapshot.events = [TerminalEvent(data: Data("private output".utf8))]
        model.relay.onMessage?(snapshot)
        XCTAssertTrue(model.ready); XCTAssertTrue(model.canClaim); XCTAssertTrue(model.canCreate)
        var removed = Message("sessions"); removed.sessions = []; removed.canCreate = false
        model.relay.onMessage?(removed)
        XCTAssertFalse(model.ready); XCTAssertFalse(model.canClaim); XCTAssertFalse(model.canCreate)
        XCTAssertNil(model.selected); XCTAssertEqual(model.feed.snapshot, [])
        model.relay.onMessage?(snapshot)
        var late = Message("output", sessionID: id); late.sequence = 2; late.data = Data("late".utf8).base64EncodedString()
        model.relay.onMessage?(late)
        XCTAssertEqual(model.feed.snapshot, [])
    }
    func testControlDowngradePreservesReadingAndDisconnectClearsContent() {
        let model = RemoteModel(), id = UUID().uuidString
        var info = SessionInfo(id: id, name: "Shared", running: true, owner: "", epoch: 1)
        info.canControl = true; info.canTerminate = true
        var list = Message("sessions"); list.sessions = [info]
        model.relay.onMessage?(list); model.attach(id)
        var snapshot = Message("snapshot", sessionID: id); snapshot.inputAcknowledgements = true; snapshot.events = [TerminalEvent(data: Data("output".utf8))]
        model.relay.onMessage?(snapshot)
        XCTAssertTrue(model.canClaim); XCTAssertTrue(model.canTerminate)
        info.canControl = false; info.canTerminate = false; list.sessions = [info]
        model.relay.onMessage?(list)
        XCTAssertTrue(model.ready); XCTAssertFalse(model.canClaim); XCTAssertFalse(model.canTerminate)
        XCTAssertEqual(model.feed.snapshot?.count, 1)
        model.relay.onDisconnect?()
        XCTAssertFalse(model.ready); XCTAssertTrue(model.sessions.isEmpty); XCTAssertEqual(model.feed.snapshot, [])
        XCTAssertEqual(model.terminalStatus, L10n.text("Sin conexión. Reintenta para continuar."))
        XCTAssertNotEqual(model.terminalStatus, L10n.text("Sesión terminada"))
    }
}
