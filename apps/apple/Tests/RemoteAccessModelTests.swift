import XCTest
import AFKCore

@MainActor final class RemoteAccessModelTests: XCTestCase {
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
