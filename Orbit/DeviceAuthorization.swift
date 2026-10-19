import Foundation
import LocalAuthentication

@MainActor
enum DeviceAuthorization {
    private static var activeContext: LAContext?
    static func authorize(reason: String) async throws {
        guard activeContext == nil else { throw APIError.message("Finish the current authentication prompt first.") }
        let context = LAContext()
        activeContext = context
        defer { if activeContext === context { activeContext = nil } }
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw APIError.message("Set a device passcode in iPhone Settings to unlock Orbit. Face ID or Touch ID is optional.")
        }
        let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        guard success else { throw APIError.message("Device authentication failed. No command was sent.") }
    }
    static func cancelCurrentAuthentication() {
        activeContext?.invalidate()
        activeContext = nil
    }
    static func isCancellation(_ error: Error) -> Bool {
        guard let la = error as? LAError else { return false }
        return [.userCancel, .appCancel, .systemCancel].contains(la.code)
    }
}
