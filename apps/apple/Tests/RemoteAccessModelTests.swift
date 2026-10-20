import XCTest
import AFKCore

@MainActor final class RemoteAccessModelTests: XCTestCase {
    func testUnavailableHistoryKeepsReceivingLiveFrames() throws {
        let model = RemoteModel()
        let id = "unavailable-history"
        var list = Message("sessions")
        list.sessions = [SessionInfo(id: id, name: "Shell", running: true, owner: "local", epoch: 1)]
        model.relay.onMessage?(list); model.attach(id)
        let attachment = model.viewportID
        var rendered = ""
        let observation = model.feed.observe { events, _ in
            rendered = events.compactMap(\.data).map { String(decoding: $0, as: UTF8.self) }.joined()
        }
        defer { model.feed.remove(observation) }
        for sequence in UInt64(100)...101 {
            var frame = try viewportMessage(model, session: id, count: 0)
            var view = try JSONDecoder().decode(TerminalViewport.self, from: XCTUnwrap(Data(base64Encoded: frame.data!)))
            view.historyUnavailable = true
            view.sequence = sequence
            view.rows[0].ansi = "live-\(sequence)"
            let bytes = try JSONEncoder().encode(view)
            frame.sequence = sequence; frame.data = bytes.base64EncodedString()
            frame.historyOffset = UInt64(bytes.count); frame.historyLength = UInt64(bytes.count)
            model.relay.onMessage?(frame)
            XCTAssertTrue(model.ready)
            XCTAssertEqual(model.viewportID, attachment)
            XCTAssertNotNil(model.sessionNotice)
            XCTAssertTrue(rendered.contains("live-\(sequence)"))
        }
        model.suspend()
    }

    func testReconnectWaitsForAuthorizedSessionListBeforeReattaching() throws {
        let model = RemoteModel()
        let session = SessionInfo(id: "reconnect", name: "Shell", running: true, owner: "local", epoch: 1)
        var list = Message("sessions"); list.sessions = [session]
        model.relay.onMessage?(list); model.attach(session.id)
        let stale = try viewportMessage(model, session: session.id)
        model.relay.onDisconnect?()
        model.relay.onMessage?(Message("hostOnline"))
        XCTAssertNil(model.viewportID, "Wait for the authorized session list")
        model.relay.onMessage?(list)
        XCTAssertNotNil(model.viewportID)
        XCTAssertNotEqual(model.viewportID, stale.viewportID)
        model.relay.onMessage?(stale)
        XCTAssertFalse(model.ready)
        model.relay.onMessage?(try viewportMessage(model, session: session.id))
        XCTAssertTrue(model.ready)
        model.suspend()
    }

    func testMalformedCurrentViewportShowsFailureInsteadOfRestoringForever() throws {
        let model = RemoteModel()
        var list = Message("sessions")
        list.sessions = [SessionInfo(id: "malformed", name: "Shell", running: true, owner: "local", epoch: 1)]
        model.relay.onMessage?(list); model.attach("malformed")
        var frame = try viewportMessage(model, session: "malformed")
        frame.historyOffset = 0
        model.relay.onMessage?(frame)
        XCTAssertFalse(model.ready)
        XCTAssertNil(model.viewportID)
        XCTAssertNotNil(model.sessionNotice)
        XCTAssertEqual(model.terminalStatus, L10n.text("No se pudo abrir la sesión"))
        model.relay.onMessage?(list)
        XCTAssertNil(model.viewportID, "A failed viewport must not create a retry loop")
        model.suspend()
    }

    func testHiddenSessionsAreLocalToHostAndNeverSelectAnotherSession() throws {
        let suite = "AFKTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteModel(preferences: defaults)
        model.loadHiddenSessions(hostID: "first-host")
        let first = SessionInfo(id: "first", name: "First", running: true, owner: "", epoch: 0)
        let second = SessionInfo(id: "second", name: "Second", running: true, owner: "", epoch: 0)
        var list = Message("sessions"); list.sessions = [first, second]
        model.relay.onMessage?(list); model.attach(first.id)
        model.hideSession(first.id)
        XCTAssertNil(model.selected)
        XCTAssertFalse(model.ready)
        XCTAssertEqual(model.visibleSessions.map(\.id), [second.id])
        XCTAssertEqual(model.hiddenSessions.map(\.id), [first.id])
        model.attach(first.id)
        XCTAssertNil(model.selected, "Hidden sessions must not attach through stale navigation")
        model.loadHiddenSessions(hostID: "second-host")
        XCTAssertTrue(model.hiddenSessions.isEmpty)
        model.loadHiddenSessions(hostID: "first-host")
        XCTAssertEqual(model.hiddenSessions.map(\.id), [first.id])
        list.sessions = [second]; model.relay.onMessage?(list)
        XCTAssertTrue(model.hiddenSessions.isEmpty, "Revoked sessions must not leak through hidden counts")
        list.sessions = [first, second]; model.relay.onMessage?(list)
        model.showSession(first.id)
        XCTAssertNil(model.selected, "Unhiding does not redirect input")
        XCTAssertTrue(model.hiddenSessions.isEmpty)
    }

    func testLegacyHostDoesNotOfferRemoveOrLeaveSessionClosing() {
        let model = RemoteModel()
        var session = SessionInfo(id: "legacy", name: "Legacy", running: true, owner: "", epoch: 0)
        session.canTerminate = true
        var list = Message("sessions"); list.sessions = [session]
        model.relay.onMessage?(list)
        XCTAssertTrue(model.canCloseSession(session))
        model.closeSession(session.id)
        XCTAssertNotEqual(model.sessions.first?.closing, true)
        session.running = false
        XCTAssertFalse(model.canCloseSession(session))
        session.canRemove = true
        XCTAssertTrue(model.canCloseSession(session))
    }

    func testClosingSessionCannotReceiveInput() throws {
        let model = RemoteModel()
        var session = SessionInfo(id: "closing", name: "Closing", running: true, owner: "", epoch: 0)
        session.canControl = true; session.canTerminate = true; session.closing = true
        var list = Message("sessions"); list.sessions = [session]
        model.relay.onMessage?(list); model.attach(session.id)
        model.relay.onMessage?(try viewportMessage(model, session: session.id, count: 0))
        XCTAssertTrue(model.ready)
        XCTAssertFalse(model.canClaim)
        XCTAssertFalse(model.canTerminate)
        XCTAssertFalse(model.canWrite)
    }

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
    func testApplicationScrollDoesNotRequestArchiveInReadOnlyMode() throws {
        let model = RemoteModel(), id = UUID().uuidString
        var list = Message("sessions")
        list.sessions = [SessionInfo(id: id, name: "Codex", running: true, owner: "local", epoch: 1)]
        model.relay.onMessage?(list); model.attach(id)
        var frame = try viewportMessage(model, session: id, count: 0)
        var viewport = try JSONDecoder().decode(TerminalViewport.self, from: XCTUnwrap(Data(base64Encoded: frame.data!)))
        viewport.scrollUp = Data("\u{1b}[<64;22;7M".utf8)
        viewport.scrollDown = Data("\u{1b}[<65;22;7M".utf8)
        let data = try JSONEncoder().encode(viewport)
        frame.data = data.base64EncodedString(); frame.historyOffset = UInt64(data.count); frame.historyLength = UInt64(data.count)
        model.relay.onMessage?(frame)
        XCTAssertFalse(model.canWrite)
        XCTAssertTrue(model.scrollApplication(0), "Recognize app-owned history without requesting archive pages")
        XCTAssertFalse(model.scrollApplication(3), "Stop queued movement when input permission is absent")
        XCTAssertFalse(model.loadingHistory)
        XCTAssertTrue(model.ready)
        model.suspend()
        XCTAssertFalse(model.scrollApplication(3))
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
        var cancelledScroll = false
        model.feed.onCancelApplicationScroll = { cancelledScroll = true }
        info.canControl = false; info.canTerminate = false; list.sessions = [info]
        model.relay.onMessage?(list)
        XCTAssertTrue(cancelledScroll)
        XCTAssertTrue(model.ready); XCTAssertFalse(model.canClaim); XCTAssertFalse(model.canTerminate)
        XCTAssertEqual(model.feed.snapshot?.count, 1)
        model.relay.onDisconnect?()
        XCTAssertFalse(model.ready); XCTAssertTrue(model.sessions.isEmpty); XCTAssertEqual(model.feed.snapshot, [])
        XCTAssertEqual(model.terminalStatus, L10n.text("Sin conexión. Reintenta para continuar."))
        XCTAssertNotEqual(model.terminalStatus, L10n.text("Sesión terminada"))
    }
}
