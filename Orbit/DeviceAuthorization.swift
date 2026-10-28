import Foundation
import LocalAuthentication
import UIKit

@MainActor
enum DeviceAuthorization {
    @TaskLocal static var confirmationProvided = false
    private static var activeContext: LAContext?
    private static var pendingConfirmation: CheckedContinuation<Void, Error>?
    private static weak var confirmationAlert: UIAlertController?
    static func requiresDeviceAuthentication(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "appLock.v4") as? Bool ?? true
    }
    enum Requirement: Equatable { case deviceAuthentication, confirmation, alreadyConfirmed }
    static func requirement(defaults: UserDefaults = .standard, confirmed: Bool) -> Requirement {
        requiresDeviceAuthentication(defaults: defaults) ? .deviceAuthentication : confirmed ? .alreadyConfirmed : .confirmation
    }
    static func authorize(reason: String, defaults: UserDefaults = .standard) async throws {
        if requirement(defaults: defaults, confirmed: confirmationProvided) != .deviceAuthentication {
            if !confirmationProvided { try await confirm(reason: reason) }
            return
        }
        guard pendingConfirmation == nil && activeContext == nil else { throw APIError.message("Finish the current authentication prompt first.") }
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
    private static func confirm(reason: String) async throws {
        guard activeContext == nil && pendingConfirmation == nil else {
            throw APIError.message("Finish the current confirmation first.")
        }
        // Let an existing sheet/dialog transition finish before presenting.
        try await Task.sleep(for: .milliseconds(300))
        guard UIApplication.shared.applicationState == .active, !Task.isCancelled else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard pendingConfirmation == nil else {
                continuation.resume(throwing: APIError.message("Finish the current confirmation first.")); return
            }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard var presenter = scenes.first(where: { $0.activationState == .foregroundActive })?
                .windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                continuation.resume(throwing: APIError.message("Could not show the confirmation. Nothing was changed.")); return
            }
            while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
            guard !(presenter is UIAlertController), !presenter.isBeingDismissed else {
                continuation.resume(throwing: APIError.message("Close the current dialog before this action.")); return
            }
            pendingConfirmation = continuation
            let alert = UIAlertController(title: "Confirm action", message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in finishConfirmation(false) })
            alert.addAction(UIAlertAction(title: "Confirm", style: .default) { _ in finishConfirmation(true) })
            confirmationAlert = alert
            presenter.present(alert, animated: true)
        }
    }
    private static func finishConfirmation(_ approved: Bool) {
        let continuation = pendingConfirmation; pendingConfirmation = nil
        confirmationAlert = nil
        if approved { continuation?.resume() } else { continuation?.resume(throwing: CancellationError()) }
    }
    static func cancelCurrentAuthentication() {
        let alert = confirmationAlert
        finishConfirmation(false)
        alert?.dismiss(animated: false)
        activeContext?.invalidate()
        activeContext = nil
    }
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let la = error as? LAError else { return false }
        return [.userCancel, .appCancel, .systemCancel].contains(la.code)
    }
}
