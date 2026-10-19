import Foundation
import Combine

@MainActor
final class StudentsStore: ObservableObject {
    @Published private(set) var snapshot: StudentsSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var mutationBusy = false
    @Published private(set) var actionError: String?
    @Published private(set) var actionNotice: String?
    @Published private(set) var requiresVerification = true
    @Published private(set) var backendUnsupported = false
    private let api: ServerAPI
    private let connectionProvider: () throws -> StudentsConnection?
    private let fetchSnapshot: (StudentsConnection) async throws -> StudentsSnapshot
    private var visibilityOwner: UUID?
    private var connection: StudentsConnection?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var mutationGeneration = 0

    init(api: ServerAPI, connectionProvider: @escaping () throws -> StudentsConnection? = {
        try KeychainManager.loadStudentsConnection()
    }, fetchSnapshot: ((StudentsConnection) async throws -> StudentsSnapshot)? = nil) {
        self.api = api
        self.connectionProvider = connectionProvider
        self.fetchSnapshot = fetchSnapshot ?? { try await api.fetchStudents(connection: $0) }
    }

    func refresh() async {
        guard api.accessAllowed && !Task.isCancelled && !mutationBusy else { return }
        if let refreshTask { await refreshTask.value; return }
        let configured: StudentsConnection
        do {
            guard let saved = try connectionProvider() else {
                snapshot = nil
                connection = nil
                requiresVerification = true
                error = "Set the Students base URL and API key in Settings → Students connection."
                return
            }
            configured = try saved.validated()
        } catch {
            snapshot = nil
            requiresVerification = true
            self.error = Self.message(for: error)
            return
        }
        if configured != connection { snapshot = nil; requiresVerification = true; backendUnsupported = false }
        connection = configured
        generation += 1
        let current = generation
        loading = true
        error = nil
        let task = Task { @MainActor in
            defer {
                if self.generation == current {
                    self.loading = false
                    self.refreshTask = nil
                }
            }
            do {
                let snapshot = try await self.fetchSnapshot(configured)
                guard !Task.isCancelled && self.generation == current && self.api.accessAllowed else { return }
                self.snapshot = snapshot
                self.error = nil
                self.requiresVerification = false
            } catch {
                guard self.generation == current && self.api.accessAllowed && !ServerAPI.isRefreshCancellation(error) else { return }
                if let http = error as? HTTPFailure, [401, 403].contains(http.status) {
                    self.snapshot = nil
                }
                self.error = Self.message(for: error)
                self.requiresVerification = true
            }
        }
        refreshTask = task
        await task.value
    }

    func claimVisibility(_ owner: UUID) {
        if visibilityOwner != owner { suspend(); visibilityOwner = owner }
    }

    func suspend(owner: UUID? = nil, clear: Bool = false) {
        if let owner, visibilityOwner != owner { return }
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        loading = false
        requiresVerification = true
        if clear { mutationGeneration += 1; snapshot = nil; connection = nil; error = nil }
    }

    func managementUnavailableReason(for student: Student) -> String? {
        if student.activityStatus == .unknown || backendUnsupported {
            return "Backend management support is not confirmed. Activity is not permission to send messages."
        }
        if mutationBusy || api.actionBusy { return "Another action is in progress." }
        if !api.accessAllowed { return "Unlock the app before managing students." }
        if requiresVerification || error != nil { return "Refresh Students to verify the current state before another action." }
        return nil
    }

    @discardableResult
    func manage(phone: String, action: StudentManagementAction) async -> Bool {
        guard !mutationBusy else { return false }
        guard let student = snapshot?.students.first(where: { $0.phone == phone }),
              managementUnavailableReason(for: student) == nil,
              action.isValid(for: student.activityStatus) else {
            actionError = "This control is not available in the verified Students state. Refresh the list before trying again."
            return false
        }
        let configured: StudentsConnection
        do {
            guard let saved = try connectionProvider(), try saved.validated() == connection else {
                throw APIError.message("Students settings changed. Refresh before sending a management request.")
            }
            configured = try saved.validated()
        } catch { requiresVerification = true; actionError = Self.message(for: error); return false }

        // Invalidate even a cancellation-insensitive older GET before authorizing.
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        loading = false
        let operation = mutationGeneration
        mutationBusy = true
        requiresVerification = true
        actionError = nil
        actionNotice = nil
        defer { mutationBusy = false }
        do {
            try await api.mutateStudent(connection: configured, phone: phone, action: action)
            guard api.accessAllowed && mutationGeneration == operation else { return false }
            if action == .remove { snapshot = snapshot?.removing(phone: phone) }
            actionNotice = action == .remove ? "Profile removed. Messaging the bot again starts onboarding." : "Update acknowledged. Check the refreshed activity status."
            mutationBusy = false
            await refresh()
            return true
        } catch {
            guard api.accessAllowed && mutationGeneration == operation else { return false }
            if let failure = error as? StudentMutationFailure {
                switch failure {
                case .notSent:
                    requiresVerification = false
                    actionNotice = "Cancelled or unavailable. No management request was sent."
                    return false
                case .authorizationFailed:
                    requiresVerification = false
                    actionError = "Device authorization failed. No management request was sent."
                    return false
                case .uncertain:
                    actionError = "The action may have succeeded. Check the refreshed status before trying again. No mutation was retried."
                }
            } else if let http = error as? HTTPFailure {
                if [404, 405, 501].contains(http.status) {
                    backendUnsupported = true
                    actionError = "The Students backend does not support this control yet. Management is disabled until the backend is updated."
                } else if [401, 403].contains(http.status) {
                    actionError = Self.message(for: error)
                    snapshot = nil
                } else {
                    actionError = "The server returned HTTP \(http.status). The action may have succeeded. Check the refreshed state before trying again."
                }
            } else { actionError = Self.message(for: error) }
            mutationBusy = false
            // Only a safe GET follows a failure; never replay PUT or DELETE.
            await refresh()
            return false
        }
    }

    static func message(for error: Error) -> String {
        if let http = error as? HTTPFailure {
            switch http.status {
            case 401: return "Students API key was rejected (401). Update it in Settings → Students connection."
            case 403: return "Students access was denied (403). Check the API key's permissions."
            case 300...399: return "The Students API redirected the request. Check its HTTPS base URL in Settings."
            default: return "Students server returned HTTP \(http.status). Pull to refresh to try again."
            }
        }
        if error is DecodingError { return "The Students server returned an unreadable response. Expected a JSON array of students." }
        if let network = error as? URLError {
            if network.code == .timedOut { return "The Students server took too long to respond. Check your connection and pull to refresh." }
            return "Cannot reach the Students server. Check your internet connection and the HTTPS base URL in Settings."
        }
        // Never display raw request headers, API responses or key material.
        return (error as? APIError)?.errorDescription ?? "The Students connection could not be loaded. Check Settings and try again."
    }
}

