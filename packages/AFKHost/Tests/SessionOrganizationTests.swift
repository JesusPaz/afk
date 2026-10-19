#if os(macOS)
import XCTest
import AFKCore
@testable import AFKHost

final class SessionOrganizationTests: XCTestCase {
    @MainActor func testFragmentedTitlesAliasAndDirectory() throws {
        let session = HostSession(id: "ABCD-1234")
        XCTAssertEqual(session.name, "Terminal · ABCD")
        session.screen?.append(Data("\u{1b}]2;Fix ".utf8))
        XCTAssertNil(session.reportedTitle)
        session.screen?.append(Data("scroll\u{7}".utf8))
        XCTAssertEqual(session.name, "Fix scroll")
        session.rename("Pinned")
        session.screen?.append(Data("\u{1b}]0;Other\u{7}\u{1b}]7;file://localhost/Users/test/afk\u{7}".utf8))
        XCTAssertEqual(session.name, "Pinned")
        XCTAssertEqual(session.context, "afk")
        let home = FileManager.default.homeDirectoryForCurrentUser
        session.screen?.append(Data("\u{1b}]7;\(home.absoluteString)\u{7}".utf8))
        XCTAssertEqual(session.context, "~")
        let project = home.appendingPathComponent("warden")
        session.screen?.append(Data("\u{1b}]7;\(project.absoluteString)\u{7}".utf8))
        XCTAssertEqual(session.context, "warden")
        session.rename(nil)
        XCTAssertEqual(session.name, "Other")
        XCTAssertEqual(SessionMetadata.clean("\u{202e}name\n\u{7}"), "name")
        XCTAssertEqual(SessionMetadata.clean(String(repeating: "x", count: 9000))?.count, 120)
    }
    @MainActor func testGroupPersistenceAndNoRestoredShells() throws {
        let suite = "afk-organization-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = HostController(preferences: preferences)
        defer { host.shutdown() }
        let first = try XCTUnwrap(host.createGroup(name: "Load testing", symbol: "diamond", color: "teal"))
        let second = try XCTUnwrap(host.createGroup(name: "AFK"))
        host.reorderGroup(id: second.id, offset: -1)
        XCTAssertEqual(host.groups.map(\.id), [second.id, first.id])
        let restored = HostController(preferences: preferences)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.groups, host.groups)
        XCTAssertTrue(restored.sessions.isEmpty)
        XCTAssertNil(host.createGroup(name: " \n"))
    }
    @MainActor func testHideRenameAndRemovalPreserveHistoryAndAuthority() async throws {
        let suite = "afk-organization-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let host = HostController(preferences: preferences, historyDirectory: directory)
        defer { host.shutdown() }
        let session = try XCTUnwrap(host.create())
        let group = try XCTUnwrap(host.createGroup(name: "Load"))
        host.moveSession(id: session.id, groupID: group.id)
        host.renameSession(id: session.id, label: "Pinned task")
        host.setHidden(id: session.id, hidden: true)
        XCTAssertTrue(session.running)
        XCTAssertEqual(session.lease.owner, "local")
        host.access.set(client: "reader", session: session.id, level: .readOnly, duration: 60)
        XCTAssertEqual(host.visibleSessions(for: "reader").first?.group, group)
        XCTAssertEqual(host.visibleSessions(for: "reader").first?.name, "Pinned task")
        XCTAssertTrue(host.visibleSessions(for: "stranger").isEmpty)
        host.deleteGroup(id: group.id)
        XCTAssertNil(session.groupID)
        host.restoreGroup(group, sessionIDs: [session.id])
        XCTAssertEqual(session.groupID, group.id)
        host.closeAndRemove(id: session.id)
        XCTAssertTrue(session.closing)
        XCTAssertTrue(session.running)
        XCTAssertFalse(session.input(Data("echo unsafe\n".utf8), client: "local", epoch: session.lease.epoch, sequence: 1))
        for _ in 0..<100 where session.running { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(session.running)
        XCTAssertTrue(host.sessions.isEmpty)
        let recording = try XCTUnwrap(TerminalHistory.entries(root: directory).first)
        XCTAssertEqual(recording.name, "Pinned task")
        XCTAssertEqual(recording.group, group)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.directory.appendingPathComponent("output.afk").path))
    }
    @MainActor func testPTYCloseSignalsForegroundJobAndConfirmsExit() async throws {
        let process = PTYProcess()
        var output = "", exited = false
        process.onData = { output += String(decoding: $0, as: UTF8.self) }
        process.onExit = { _ in exited = true }
        XCTAssertTrue(process.start(shell: "/bin/zsh", environment: ["TERM=xterm-256color", "PATH=/usr/bin:/bin"]))
        defer { process.terminate(force: true) }
        XCTAssertTrue(process.send(Data("/bin/sh -c 'echo AFK_JOB_$$; exec sleep 60'\n".utf8)))
        for _ in 0..<100 where output.range(of: "AFK_JOB_[0-9]+", options: .regularExpression) == nil { try await Task.sleep(for: .milliseconds(30)) }
        let range = try XCTUnwrap(output.range(of: "AFK_JOB_[0-9]+", options: .regularExpression))
        let job = try XCTUnwrap(Int32(output[range].dropFirst(8)))
        process.terminate()
        for _ in 0..<100 where !exited { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(exited)
        XCTAssertEqual(kill(job, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
    @MainActor func testEndedRowsDoNotConsumeLiveLimitAndHiddenRowsDo() async throws {
        let suite = "afk-limit-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = HostController(preferences: preferences)
        defer { host.shutdown() }
        let ended = try XCTUnwrap(host.create())
        ended.localInput(Data("exit\n".utf8))
        for _ in 0..<100 where ended.running { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(ended.running)
        for _ in 0..<8 {
            let session = try XCTUnwrap(host.create())
            host.setHidden(id: session.id, hidden: true)
        }
        XCTAssertEqual(host.sessions.count, 9)
        XCTAssertNil(host.create())
        for session in host.sessions { host.closeAndRemove(id: session.id) }
        for _ in 0..<100 where !host.sessions.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(host.sessions.isEmpty)
    }
    @MainActor func testForceCloseWaitsForResistantForegroundGroup() async throws {
        let process = PTYProcess()
        var ready = false, exited = false
        process.onData = { if String(decoding: $0, as: UTF8.self).contains("AFK_READY") { ready = true } }
        process.onExit = { _ in exited = true }
        XCTAssertTrue(process.start(shell: "/bin/sh", environment: ["TERM=xterm-256color", "PATH=/usr/bin:/bin"]))
        defer { process.terminate(force: true) }
        XCTAssertTrue(process.send(Data("stty -echo; /bin/sh -c 'trap \"\" HUP TERM; printf AFK_; printf READY; while :; do sleep 1; done'\n".utf8)))
        for _ in 0..<100 where !ready { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(ready)
        process.terminate()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(exited)
        process.terminate(force: true)
        for _ in 0..<100 where !exited { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(exited)
    }

}
#endif
