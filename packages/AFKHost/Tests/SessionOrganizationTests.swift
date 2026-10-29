#if os(macOS)
import XCTest
import AFKCore
@testable import AFKHost

final class SessionOrganizationTests: XCTestCase {
    @MainActor func testCustomProfilesPersistAndDropsOnlyMoveKnownSessionsWithinProfile() throws {
        let suite = "afk-drag-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = HostController(preferences: preferences)
        defer { host.shutdown() }
        let profile = try XCTUnwrap(host.createProfile(name: " Clientes "))
        XCTAssertNil(host.createProfile(name: "clientes"))
        XCTAssertNil(host.createProfile(name: " \n"))
        let first = try XCTUnwrap(host.createGroup(name: "One", profile: profile))
        let second = try XCTUnwrap(host.createGroup(name: "Two", profile: profile))
        let session = try XCTUnwrap(host.create(profile: profile))
        session.claim("phone")
        let epoch = session.lease.epoch
        XCTAssertTrue(host.dropSessions([session.id], groupID: first.id, profile: profile))
        XCTAssertTrue(host.dropSessions([session.id], groupID: second.id, profile: profile))
        XCTAssertEqual(session.groupID, second.id)
        XCTAssertFalse(host.dropSessions([session.id, "missing"], groupID: nil, profile: profile))
        XCTAssertEqual(session.groupID, second.id, "Invalid multi-item drops are atomic")
        XCTAssertFalse(host.dropSessions([session.id], groupID: nil, profile: .personal))
        XCTAssertTrue(host.dropSessions([session.id], groupID: nil, profile: profile))
        XCTAssertNil(session.groupID)
        XCTAssertEqual(session.profile, profile)
        XCTAssertTrue(session.running)
        XCTAssertEqual(session.lease.owner, "phone")
        XCTAssertEqual(session.lease.epoch, epoch)
        let restored = HostController(preferences: preferences)
        defer { restored.shutdown() }
        XCTAssertTrue(restored.profiles.contains(profile))
        XCTAssertEqual(restored.profileName(profile), "Clientes")
        XCTAssertEqual(restored.profile(forGroup: first.id), profile)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceProfile.self, from: Data("\"work\"".utf8)), .work)
    }

    @MainActor func testProfilesMoveGroupsAndSessionsWithoutChangingControl() throws {
        let suite = "afk-profiles-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = HostController(preferences: preferences)
        defer { host.shutdown() }
        let group = try XCTUnwrap(host.createGroup(name: "AFK"))
        let session = try XCTUnwrap(host.create())
        host.moveSession(id: session.id, groupID: group.id)
        session.claim("phone")
        let epoch = session.lease.epoch
        host.moveGroup(id: group.id, profile: .work)
        XCTAssertEqual(host.profile(forGroup: group.id), .work)
        XCTAssertEqual(session.profile, .work)
        XCTAssertEqual(session.groupID, group.id)
        XCTAssertTrue(session.running)
        XCTAssertEqual(session.lease.owner, "phone")
        XCTAssertEqual(session.lease.epoch, epoch)
        host.moveSession(id: session.id, profile: .personal)
        XCTAssertNil(session.groupID, "Moving one session must not move its former group")
        XCTAssertEqual(host.profile(forGroup: group.id), .work)
        host.moveSession(id: session.id, groupID: group.id)
        XCTAssertEqual(session.profile, .work)
        host.deleteGroup(id: group.id)
        XCTAssertEqual(session.profile, .work)
        host.restoreGroup(group, sessionIDs: [session.id], profile: .work)
        XCTAssertEqual(session.groupID, group.id)
        let restored = HostController(preferences: preferences)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.profile(forGroup: group.id), .work)
        XCTAssertTrue(restored.sessions.isEmpty, "Profiles must not restart shells")
    }

    @MainActor func testLegacyOrganizationDefaultsToPersonalAndOrderingStaysInsideProfile() throws {
        let suite = "afk-profile-migration-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let old = SessionGroup(name: "Existing")
        let groups = try JSONSerialization.jsonObject(with: JSONEncoder().encode([old]))
        preferences.set(try JSONSerialization.data(withJSONObject: [
            "version": 1, "groups": groups, "sessions": [:]
        ]), forKey: "sessionOrganization")
        let host = HostController(preferences: preferences)
        defer { host.shutdown() }
        XCTAssertEqual(host.groups, [old])
        XCTAssertEqual(host.profile(forGroup: old.id), .personal)
        let work = try XCTUnwrap(host.createGroup(name: "Work", profile: .work))
        let personal = try XCTUnwrap(host.createGroup(name: "Personal"))
        host.reorderGroup(id: personal.id, offset: -1)
        XCTAssertEqual(host.groups.map(\.id), [personal.id, work.id, old.id])
        host.reorderGroup(id: work.id, offset: -1)
        XCTAssertEqual(host.groups.map(\.id), [personal.id, work.id, old.id])
        let session = try XCTUnwrap(host.create(profile: .work))
        XCTAssertEqual(session.profile, .work)
    }

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
        session.screen?.append(Data("\u{1b}]0;Investiga | warden\u{7}".utf8))
        XCTAssertEqual(session.name, "Investiga")
        session.screen?.append(Data("\u{1b}]0;Investiga | \(home.lastPathComponent)\u{7}".utf8))
        XCTAssertEqual(session.name, "Investiga")
        session.screen?.append(Data("\u{1b}]0;A | B\u{7}".utf8))
        XCTAssertEqual(session.name, "A | B")
        for spinner in ["✳", "✶", "·", "◐", "⠋"] {
            session.screen?.append(Data("\u{1b}]0;\(spinner) Claude Code\u{7}".utf8))
            XCTAssertEqual(session.name, spinner + " Claude Code")
            XCTAssertEqual(session.windowTitle, "Claude Code")
        }
        session.screen?.append(Data("\u{1b}]0;~ notes\u{7}".utf8))
        XCTAssertEqual(session.windowTitle, "~ notes")
        XCTAssertEqual(SessionMetadata.clean("\u{202e}name\n\u{7}"), "name")
        XCTAssertEqual(SessionMetadata.clean(String(repeating: "x", count: 9000))?.count, 120)
    }
    @MainActor func testGroupPersistenceAndNoRestoredShells() throws {
        let suite = "afk-organization-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = HostController(preferences: preferences)
        defer { host.shutdown() }
        let first = try XCTUnwrap(host.createGroup(name: "Load testing", symbol: "terminal", color: "teal", emoji: "🛠️"))
        XCTAssertEqual(first.symbol, "terminal")
        XCTAssertEqual(first.emoji, "🛠️")
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
        XCTAssertEqual(host.groups, [group])
        host.shutdown()
        let restored = HostController(preferences: UserDefaults(suiteName: suite)!)
        defer { restored.shutdown() }
        XCTAssertEqual(restored.groups, [group])
        XCTAssertTrue(restored.sessions.isEmpty)
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
        XCTAssertEqual(host.sessionLimit, 24)
        preferences.set(8, forKey: HostController.sessionLimitKey)
        XCTAssertEqual(host.sessionLimit, 8)
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
    @MainActor func testGroupStartsTerminalsInItsFolderWithItsCommand() async throws {
        let suite = "afk-start-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("afk-start-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = HostController(preferences: preferences)
        defer { host.shutdown() }
        let start = GroupStart(directory: folder.path, command: "  printf AFK_; printf START; pwd  ")
        XCTAssertEqual(start.command, "printf AFK_; printf START; pwd")
        let group = try XCTUnwrap(host.createGroup(name: "Work", profile: .work, start: start))
        XCTAssertEqual(host.lastGroupStart, start, "the next new group starts from the last choice")
        let session = try XCTUnwrap(host.create(profile: .personal, groupID: group.id))
        XCTAssertEqual(session.groupID, group.id)
        XCTAssertEqual(session.profile, .work, "a group's terminal follows the group's profile")
        var output = ""
        _ = session.feed.observe { events, _ in
            for event in events { if let data = event.data { output += String(decoding: data, as: UTF8.self) } }
        }
        for _ in 0..<100 where !output.contains("AFK_START" + folder.lastPathComponent) && !output.contains("AFK_START/") { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(output.contains("AFK_START"), "the command runs on its own")
        XCTAssertTrue(output.contains(folder.lastPathComponent), "the shell starts in the group's folder")
        XCTAssertTrue(session.running, "leaving the command keeps the shell")

        // Restarting keeps the group's settings; a missing folder falls back to home and says so.
        let reopened = HostController(preferences: preferences)
        defer { reopened.shutdown() }
        XCTAssertEqual(reopened.groupStarts[group.id], start)
        reopened.setGroupStart(id: group.id, start: GroupStart(directory: folder.appendingPathComponent("missing").path))
        XCTAssertNotNil(reopened.create(groupID: group.id))
        XCTAssertNotNil(reopened.error)
        reopened.setGroupStart(id: group.id, start: GroupStart(directory: " ", command: ""))
        XCTAssertNil(reopened.groupStarts[group.id], "an empty start is the default")
        let plain = try XCTUnwrap(reopened.create(groupID: "missing"))
        XCTAssertNil(plain.groupID)
    }
    @MainActor func testClosedSessionLeavesAtOnceAndResistantJobIsForced() async throws {
        let suite = "afk-close-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(1, forKey: HostController.sessionLimitKey)
        let host = HostController(preferences: preferences)
        defer { host.shutdown() }
        host.closeGracePeriod = .seconds(2)
        let session = try XCTUnwrap(host.create())
        var ready = false
        _ = session.feed.observe { events, _ in
            if events.contains(where: { $0.data.map { String(decoding: $0, as: UTF8.self).contains("AFK_READY") } ?? false }) { ready = true }
        }
        session.localInput(Data("stty -echo; /bin/sh -c 'trap \"\" HUP TERM; printf AFK_; printf READY; while :; do sleep 1; done'\n".utf8))
        for _ in 0..<100 where !ready { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(ready)
        host.closeAndRemove(id: session.id)
        XCTAssertTrue(host.removalRequested.contains(session.id))
        XCTAssertTrue(host.visibleSessions(for: "phone").isEmpty)
        // The closing session no longer counts towards the live limit.
        let next = try XCTUnwrap(host.create())
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(session.running, "the job ignores SIGHUP until the grace period ends")
        for _ in 0..<100 where host.sessions.contains(where: { $0.id == session.id }) { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(host.sessions.map(\.id), [next.id])
    }

}
#endif
