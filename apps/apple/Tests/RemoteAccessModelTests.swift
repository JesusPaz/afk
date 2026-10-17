import XCTest
import AFKCore

@MainActor final class RemoteAccessModelTests: XCTestCase {
    private func viewportMessage(_ model: RemoteModel, session: String, count: UInt64 = 1_000_000) throws -> Message {
        let view = TerminalViewport(size: .initial, rows: Array(repeating: TerminalRow(ansi: "current screen", columns: 80), count: 24),
            cursorX: 0, cursorY: 0, cursorVisible: true, applicationCursor: true, bracketedPaste: true,
            keyboardFlags: 0, historyCount: count, sequence: 100)
        let data = try JSONEncoder().encode(view)
        var message = Message("viewport", sessionID: session); message.viewportID = model.viewportID
        message.sequence = 100; message.data = data.base64EncodedString(); message.historyOffset = UInt64(data.count)
        message.historyLength = UInt64(data.count); message.historyComplete = true; message.inputAcknowledgements = true
        return message
    }
    func testMillionLineSessionOpensWithoutDownloadingHistory() throws {
        let model = RemoteModel(), id = UUID().uuidString
        var list = Message("sessions")
        list.sessions = [SessionInfo(id: id, name: "Long", running: true, owner: "local", epoch: 1)]
        model.relay.onMessage?(list); model.attach(id)
        let frame = try viewportMessage(model, session: id)
        XCTAssertLessThan(frame.data!.count, 4096)
        model.relay.onMessage?(frame)
        XCTAssertTrue(model.ready); XCTAssertFalse(model.loadingHistory)
        XCTAssertNil(model.feed.history); XCTAssertEqual(model.feed.presentationStart, 1_000_000)
        model.scrollHistory(older: true)
        XCTAssertTrue(model.loadingHistory)
        model.suspend()
        XCTAssertNil(model.feed.presentationStart); XCTAssertFalse(model.loadingHistory)
    }
    func testReattachAndRevocationRejectStaleViewportFrames() throws {
        let model = RemoteModel(), id = UUID().uuidString
        var list = Message("sessions")
        list.sessions = [SessionInfo(id: id, name: "Long", running: true, owner: "local", epoch: 1)]
        model.relay.onMessage?(list); model.attach(id)
        var frame = try viewportMessage(model, session: id)
        model.attach(id); model.relay.onMessage?(frame)
        XCTAssertFalse(model.ready); XCTAssertNil(model.feed.presentationStart)
        let current = model.viewportID
        var staleSnapshot = Message("snapshot", sessionID: UUID().uuidString); staleSnapshot.events = []
        model.relay.onMessage?(staleSnapshot)
        XCTAssertEqual(model.viewportID, current)
        frame.viewportID = current
        list.sessions = []; model.relay.onMessage?(list); model.relay.onMessage?(frame)
        XCTAssertFalse(model.ready); XCTAssertNil(model.feed.presentationStart)
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
