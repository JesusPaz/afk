import Foundation
import AFKCore
import AFKHost

// A headless host for integration tests; credentials stay in environment, never logs.
Task { @MainActor in
    let host = HostController()
    _ = host.create(name: "Shell")
    let env = ProcessInfo.processInfo.environment
    var credentials: HostSecret?
    if let id = env["AFK_HOST_ID"], let token = env["AFK_HOST_TOKEN"] { credentials = HostSecret(id: id, token: token) }
    await host.connect(server: env["AFK_SERVER"] ?? "http://127.0.0.1:8787", credentials: credentials)
    if let identity = host.host { print("AFK host ready: \(identity.code)") }
    else { fputs("AFK host connection failed\n", stderr) }
    // Retain the controller for the lifetime of this process.
    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000) }
    host.shutdown()
}
RunLoop.main.run()
