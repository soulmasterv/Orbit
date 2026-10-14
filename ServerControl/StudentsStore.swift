import Foundation
import Combine

@MainActor
final class StudentsStore: ObservableObject {
    @Published private(set) var snapshot: StudentsSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private let api: ServerAPI
    private let connectionProvider: () throws -> StudentsConnection?
    private var connection: StudentsConnection?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0

    init(api: ServerAPI, connectionProvider: @escaping () throws -> StudentsConnection? = {
        try KeychainManager.loadStudentsConnection()
    }) {
        self.api = api
        self.connectionProvider = connectionProvider
    }

    func refresh() async {
        guard api.accessAllowed && !Task.isCancelled else { return }
        if let refreshTask { await refreshTask.value; return }
        let configured: StudentsConnection
        do {
            guard let saved = try connectionProvider() else {
                snapshot = nil
                connection = nil
                error = "Set the Students base URL and API key in Settings → Students connection."
                return
            }
            configured = try saved.validated()
        } catch {
            snapshot = nil
            self.error = Self.message(for: error)
            return
        }
        if configured != connection { snapshot = nil }
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
                let snapshot = try await self.api.fetchStudents(connection: configured)
                guard !Task.isCancelled && self.generation == current && self.api.accessAllowed else { return }
                self.snapshot = snapshot
                self.error = nil
            } catch {
                guard self.generation == current && self.api.accessAllowed && !ServerAPI.isRefreshCancellation(error) else { return }
                if let http = error as? HTTPFailure, [401, 403].contains(http.status) {
                    self.snapshot = nil
                }
                self.error = Self.message(for: error)
            }
        }
        refreshTask = task
        await task.value
    }

    func suspend(clear: Bool = false) {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        loading = false
        if clear { snapshot = nil; connection = nil; error = nil }
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
