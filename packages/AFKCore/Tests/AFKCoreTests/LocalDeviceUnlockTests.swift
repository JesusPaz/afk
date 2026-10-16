import XCTest
@testable import AFKCore

@MainActor final class LocalDeviceUnlockTests: XCTestCase {
    func testSuccessfulUnlockIsNotCached() async throws {
        var requests = 0
        let unlock = LocalDeviceUnlock(evaluate: { _ in requests += 1; return true })
        try await unlock.require(); try await unlock.require()
        XCTAssertEqual(requests, 2)
    }
    func testDeniedUnlockFailsClosed() async {
        let unlock = LocalDeviceUnlock(evaluate: { _ in false })
        do { try await unlock.require(); XCTFail("Denied local authentication succeeded") } catch {}
        XCTAssertFalse(unlock.isBusy)
    }
    func testBackgroundInvalidatesPendingUnlock() async {
        var continuation: CheckedContinuation<Bool, Never>?
        let unlock = LocalDeviceUnlock(evaluate: { _ in await withCheckedContinuation { continuation = $0 } })
        let attempt = Task { try await unlock.require() }
        while continuation == nil { await Task.yield() }
        unlock.invalidate(); continuation?.resume(returning: true)
        do { try await attempt.value; XCTFail("Stale authentication succeeded after backgrounding") } catch {}
        XCTAssertFalse(unlock.isBusy)
    }
}
