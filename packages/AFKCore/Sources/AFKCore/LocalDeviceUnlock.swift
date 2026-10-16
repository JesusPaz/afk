import Foundation
import LocalAuthentication

@MainActor public final class LocalDeviceUnlock {
    private var context: LAContext?
    private var generation = UUID()
    private let evaluate: (LAContext) async throws -> Bool
    public var isBusy: Bool { context != nil }
    public convenience init() {
        self.init(evaluate: { context in
            try await context.evaluatePolicy(.deviceOwnerAuthentication,
                localizedReason: L10n.text("Confirma tu identidad para autorizar el acceso a la terminal del Mac."))
        })
    }
    init(evaluate: @escaping (LAContext) async throws -> Bool) { self.evaluate = evaluate }
    public func require() async throws {
        guard !isBusy else { throw SecureError.unauthorized }
        let current = UUID(); generation = current
        let context = LAContext(); self.context = context
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { if generation == current { self.context = nil }; context.invalidate() }
        guard try await evaluate(context), generation == current else { throw SecureError.unauthorized }
    }
    public func invalidate() { generation = UUID(); context?.invalidate(); context = nil }
}
