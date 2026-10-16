#if os(macOS)
import XCTest
import AFKHost

final class StartupTests: XCTestCase {
    @MainActor func testStartupAttemptsConnectionOnlyOnce() async {
        let suite = "afk-tests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = HostController(preferences: preferences)
        defer { host.shutdown() }
        // Invalid addresses fail before touching the Keychain or the network.
        await host.restoreConnection(server: "invalid")
        XCTAssertNotNil(host.error)
        XCTAssertFalse(host.connecting)
        host.error = nil
        await host.restoreConnection(server: "invalid")
        XCTAssertNil(host.error)
    }
    @MainActor func testExplicitPauseSurvivesNewController() async {
        let suite = "afk-tests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let previous = HostController(preferences: preferences)
        previous.pause(); previous.shutdown()
        let host = HostController(preferences: preferences)
        defer { host.shutdown() }
        await host.restoreConnection(server: "invalid")
        XCTAssertTrue(host.remoteAccessPaused)
        XCTAssertNil(host.error)
        XCTAssertFalse(host.connecting)
    }
}
#endif
