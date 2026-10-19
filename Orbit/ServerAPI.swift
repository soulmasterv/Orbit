import Foundation
import Combine
import UIKit

enum ConnectionState: Equatable {
    case notConfigured, connecting, connected, unreachable, unauthorized, incompatible
    var title: String {
        switch self {
        case .notConfigured: return "Setup needed"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .unreachable: return "Connection lost"
        case .unauthorized: return "Authentication needed"
        case .incompatible: return "Response unavailable"
        }
    }
}

enum ServerAction: String, CaseIterable {
    case start, restart, stop
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .start: return "play.fill"
        case .restart: return "arrow.clockwise"
        case .stop: return "stop.fill"
        }
    }
}

// Never forward bearer credentials through an HTTP redirect.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class ServerAPI: ObservableObject {
    static let defaultBaseURL = "https://control.admin-ai.site"
    static let fallbackBaseURL = "https://ubuntu-lts.tail341977.ts.net/server-control"
    @Published private(set) var dashboard: DashboardResponse?
    @Published private(set) var loading = false
    @Published private(set) var connection: ConnectionState = .notConfigured
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var actionBusy = false
    @Published private(set) var actionProgress = ""
    @Published var actionError: String?
    @Published var actionNotice: String?
    @Published private(set) var hasSavedToken = false
    @Published private(set) var accessAllowed: Bool
    @Published private(set) var lastNetworkSeconds: Double?
    @Published private(set) var lastDecodeSeconds: Double?
    @Published private(set) var serviceSnapshot: ServiceSnapshot?
    @Published private(set) var servicesLoading = false
    @Published private(set) var servicesError: String?
    @Published private(set) var servicesUpdatedAt: Date?

    private let session: URLSession
    private let tokenProvider: () -> String
    private let authorize: (String) async throws -> Void
    let library: HomelabStore
    private let defaults: UserDefaults
    private var previewMode = false
    private var dashboardRefresh: Task<Void, Never>?
    private var servicesRefresh: Task<Void, Never>?
    private var refreshGeneration = 0
    private var servicesGeneration = 0
    private let snapshotStore: DashboardSnapshotStore?
    private var fallbackUntil: Date?
    private var needsVerification = false
    private var noticeTask: Task<Void, Never>?
    private var logRequests: [LogTarget: Task<LogSnapshot, Error>] = [:]
    private var logSnapshots: [LogTarget: LogSnapshot] = [:]
    private var logGeneration = 0
    private var classeraRecipients: [String: [String]] = [:]
    private var studentsAccessGeneration = 0

    init(session: URLSession? = nil, defaults: UserDefaults = .standard,
         accessAllowed: Bool = true, snapshotStore: DashboardSnapshotStore? = nil,
         tokenProvider: @escaping () -> String = { KeychainManager.load() },
         authorize: @escaping (String) async throws -> Void = { reason in
             try await DeviceAuthorization.authorize(reason: reason)
         }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        self.session = session ?? URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        self.defaults = defaults
        self.library = HomelabStore(defaults: defaults)
        self.tokenProvider = tokenProvider
        self.authorize = authorize
        self.accessAllowed = accessAllowed
        self.snapshotStore = snapshotStore
        hasSavedToken = !tokenProvider().isEmpty
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
            previewMode = true
            dashboard = PreviewFixtures.dashboard
            connection = .connected
            hasSavedToken = true
            lastUpdated = Date()
        }
        #endif
    }

    var baseURL: String {
        let saved = defaults.string(forKey: "serverURL")
        return saved == Self.fallbackBaseURL ? Self.defaultBaseURL : (saved ?? Self.defaultBaseURL)
    }
    var activeBaseURL: String { fallbackUntil.map { $0 > Date() } == true ? Self.fallbackBaseURL : baseURL }
    var canControl: Bool { accessAllowed && !needsVerification && connection == .connected && !loading && !actionBusy && hasSavedToken }
    var hasNotice: Bool { errorMessage != nil || actionNotice != nil }

    func setAccessAllowed(_ allowed: Bool) {
        guard accessAllowed != allowed else { return }
        accessAllowed = allowed
        if !allowed {
            studentsAccessGeneration += 1
            needsVerification = true
            classeraRecipients.removeAll()
            refreshGeneration += 1
            servicesGeneration += 1
            logGeneration += 1
            dashboardRefresh?.cancel()
            servicesRefresh?.cancel()
            logRequests.values.forEach { $0.cancel() }
            logRequests.removeAll()
            dashboardRefresh = nil
            servicesRefresh = nil
            loading = false
            servicesLoading = false
            if dashboard == nil && connection == .connecting { connection = .notConfigured }
        } else if dashboard == nil && !tokenProvider().isEmpty, let saved = snapshotStore?.read(baseURL: baseURL) {
            dashboard = saved.dashboard
            lastUpdated = saved.updatedAt
            // A disk snapshot is useful immediately, but must be verified before controls unlock.
            connection = .connecting
        }
    }

    static func validatedBaseURL(_ value: String) throws -> URL {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: clean), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil, let url = components.url,
              components.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw APIError.message("Use an HTTPS server URL without credentials, query parameters or fragments.")
        }
        return url
    }

    func saveConnection(url: String, replacementToken: String) throws {
        guard !loading && !actionBusy else { throw APIError.message("Wait for the current request to finish.") }
        let valid = try Self.validatedBaseURL(url)
        let cleanToken = replacementToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanToken.isEmpty { try KeychainManager.save(token: cleanToken) }
        defaults.set(valid.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: "serverURL")
        resetSecondaryRequests()
        hasSavedToken = !tokenProvider().isEmpty
        dashboard = nil
        lastUpdated = nil
        errorMessage = nil
        actionNotice = nil
        connection = .notConfigured
        fallbackUntil = nil
        snapshotStore?.clear()
        serviceSnapshot = nil
        logSnapshots.removeAll()
        servicesUpdatedAt = nil
        servicesError = nil
    }

    func removeToken() throws {
        guard !loading && !actionBusy else { throw APIError.message("Wait for the current request to finish.") }
        try KeychainManager.delete()
        resetSecondaryRequests()
        hasSavedToken = false
        dashboard = nil
        lastUpdated = nil
        errorMessage = nil
        actionNotice = nil
        connection = .notConfigured
        snapshotStore?.clear()
        serviceSnapshot = nil
        logSnapshots.removeAll()
        servicesUpdatedAt = nil
        servicesError = nil
    }

    // Preserve the original API routes and camelCase models.
    func request(path: String, method: String = "GET", authenticated: Bool = true, endpoint: String? = nil) throws -> URLRequest {
        guard accessAllowed else { throw CancellationError() }
        let base = try Self.validatedBaseURL(endpoint ?? activeBaseURL)
        let clean = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.hasPrefix("/api/"), let url = URL(string: clean + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = method == "GET" ? 6 : 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            let token = tokenProvider()
            guard !token.isEmpty else { throw APIError.message("Add your server token in Settings to connect.") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func isConnectivityFailure(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                .networkConnectionLost, .notConnectedToInternet].contains(error.code)
    }

    // Only safe GETs can fail over. A POST is never repeated: it may already have executed.
    private func get(path: String, authenticated: Bool = true) async throws -> (Data, URLResponse) {
        let endpoint = activeBaseURL
        do {
            return try await session.data(for: request(path: path, authenticated: authenticated, endpoint: endpoint))
        } catch {
            guard accessAllowed && !Task.isCancelled && Self.isConnectivityFailure(error), endpoint == Self.defaultBaseURL else { throw error }
            let result = try await session.data(for: request(path: path, authenticated: authenticated, endpoint: Self.fallbackBaseURL))
            // Pin a reachable fallback for five minutes instead of flapping between hosts.
            if let http = result.1 as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                fallbackUntil = Date().addingTimeInterval(300)
            }
            return result
        }
    }

    func loadDashboard() async {
        guard !previewMode && accessAllowed else { return }
        if let refresh = dashboardRefresh {
            await refresh.value
            return
        }
        guard !Task.isCancelled else { return }
        hasSavedToken = !tokenProvider().isEmpty
        guard hasSavedToken else {
            connection = .notConfigured
            errorMessage = "Add your server token in Settings."
            return
        }
        loading = true
        refreshGeneration += 1
        let generation = refreshGeneration
        // ServerAPI owns this unstructured task. Leaving a tab or cancelling a
        // refreshable waiter must not cancel the shared URLSession request.
        let refresh = Task { @MainActor in
            await self.refreshDashboard(generation: generation)
            if generation == self.refreshGeneration {
                self.loading = false
                self.dashboardRefresh = nil
            }
        }
        dashboardRefresh = refresh
        await refresh.value
    }

    private func refreshDashboard(generation: Int) async {
        let previousConnection = connection
        let previousError = errorMessage
        if dashboard == nil { connection = .connecting }
        do {
            let start = Date()
            let (data, response) = try await get(path: "/api/dashboard")
            guard accessAllowed && generation == refreshGeneration else { return }
            let received = Date()
            try validate(response)
            let snapshot = try JSONDecoder().decode(DashboardResponse.self, from: data)
            dashboard = snapshot
            lastUpdated = Date()
            lastNetworkSeconds = received.timeIntervalSince(start)
            lastDecodeSeconds = Date().timeIntervalSince(received)
            connection = .connected
            needsVerification = false
            errorMessage = nil
            snapshotStore?.save(SavedDashboard(baseURL: baseURL, dashboard: snapshot, updatedAt: lastUpdated!))
        } catch {
            guard accessAllowed && generation == refreshGeneration else { return }
            if Self.isRefreshCancellation(error) {
                connection = previousConnection
                errorMessage = previousError
                return
            }
            if let httpError = error as? HTTPFailure, [401, 403].contains(httpError.status) {
                connection = .unauthorized
            } else if error is DecodingError {
                connection = .incompatible
            } else {
                connection = .unreachable
            }
            errorMessage = friendly(error)
        }
    }

    func refreshAll() async {
        async let dashboard: Void = loadDashboard()
        async let services: Void = loadServices()
        _ = await (dashboard, services)
    }
    func ensureServicesFresh() async {
        guard servicesUpdatedAt.map({ Date().timeIntervalSince($0) < 30 }) != true else { return }
        await loadServices()
    }
    func loadServices() async {
        guard !previewMode && accessAllowed && !tokenProvider().isEmpty else { return }
        if let refresh = servicesRefresh { await refresh.value; return }
        guard !Task.isCancelled else { return }
        servicesGeneration += 1
        let generation = servicesGeneration
        servicesLoading = true
        let refresh = Task { @MainActor in
            defer {
                if generation == self.servicesGeneration {
                    self.servicesLoading = false
                    self.servicesRefresh = nil
                }
            }
            do {
                let (data, response) = try await self.get(path: "/api/services")
                guard self.accessAllowed && generation == self.servicesGeneration else { return }
                try self.validate(response)
                self.serviceSnapshot = try JSONDecoder().decode(ServiceSnapshot.self, from: data)
                self.servicesUpdatedAt = Date()
                self.servicesError = nil
            } catch {
                guard self.accessAllowed && generation == self.servicesGeneration && !Self.isRefreshCancellation(error) else { return }
                if let http = error as? HTTPFailure, http.status == 404 || http.status == 501 {
                    self.servicesError = "Service integrations are not connected yet. A compatible Orbit backend update is needed."
                } else { self.servicesError = self.friendly(error) }
            }
        }
        servicesRefresh = refresh
        await refresh.value
    }

    func cachedLogs(_ target: LogTarget) -> LogSnapshot? { logSnapshots[target] }
    private func resetSecondaryRequests() {
        classeraRecipients.removeAll()
        servicesGeneration += 1
        logGeneration += 1
        servicesRefresh?.cancel()
        servicesRefresh = nil
        servicesLoading = false
        logRequests.values.forEach { $0.cancel() }
        logRequests.removeAll()
    }
    func loadLogs(_ target: LogTarget) async throws -> LogSnapshot {
        guard accessAllowed && !Task.isCancelled else { throw CancellationError() }
        if let task = logRequests[target] { return try await task.value }
        let generation = logGeneration
        let task = Task { @MainActor in
            let (data, response) = try await self.get(path: target.path)
            guard self.accessAllowed && generation == self.logGeneration else { throw CancellationError() }
            try self.validate(response)
            guard data.count <= 1_048_576 else { throw APIError.message("Log response is too large.") }
            let decoded = try JSONDecoder().decode(LogSnapshot.self, from: data)
            var ids = Set<String>()
            let lines = decoded.lines.suffix(500).filter { ["stdout", "stderr"].contains($0.stream) && ids.insert($0.id).inserted }.map {
                LogLine(id: $0.id, stream: $0.stream, text: LogPrivacy.redact($0.text), timestamp: $0.timestamp)
            }
            return LogSnapshot(lines: lines, truncated: decoded.truncated == true || decoded.lines.count > 500, fetchedAt: decoded.fetchedAt)
        }
        logRequests[target] = task
        defer { if generation == logGeneration { logRequests[target] = nil } }
        let result = try await task.value
        guard accessAllowed && generation == logGeneration else { throw CancellationError() }
        if logSnapshots.count >= 8 && logSnapshots[target] == nil { logSnapshots.removeAll() }
        logSnapshots[target] = result
        return result
    }

    func serviceAction(_ action: ServiceCommand) async {
        guard !actionBusy else { return }

        let permitted: Bool

        switch action.kind {
        case .testGeminiKey:
            permitted =
                (1...10).map { "key-\($0)" }.contains(action.id)
                && serviceSnapshot?.gemini?.contains {
                    $0.id == action.id && $0.canTest == true
                } == true

        case .fireClasseraReport:
            permitted =
                (1...3).map { "classera-\($0)" }.contains(action.id)
                && serviceSnapshot?.classera?.contains {
                    $0.id == action.id && $0.canFire == true
                } == true

        case .forceFireClasseraReport, .forceOneClasseraReport:
            permitted =
                (1...3).map { "classera-\($0)" }.contains(action.id)
                && serviceSnapshot?.classera?.contains {
                    $0.id == action.id && $0.canForceFire == true
                } == true
        }

        guard permitted && servicesError == nil && !servicesLoading else {
            actionError = "This control is not available from your server."
            return
        }

        var body: Data?
        if action.kind == .forceOneClasseraReport {
            do {
                let recipient = try ClasseraRecipientValidation.number(action.recipient ?? "")
                guard classeraRecipients[action.id]?.contains(recipient) == true else {
                    throw APIError.message("Select a configured recipient. Reopen the picker to check the current list.")
                }
                body = try JSONEncoder().encode(ClasseraForceOnePayload(recipient: recipient))
            } catch { actionError = friendly(error); return }
        }

        let id: String

        do {
            id = try Self.encodedContainerName(action.id)
        } catch {
            actionError = friendly(error)
            return
        }

        let path: String
        let authorizationReason: String
        let activityTitle: String

        switch action.kind {
        case .testGeminiKey:
            path = "/api/services/gemini/\(id)/test"
            authorizationReason = "Test \(action.name) through your server."
            activityTitle = "Key test for \(action.name)"

        case .fireClasseraReport:
            path = "/api/services/classera/\(id)/fire"
            authorizationReason = "Send the current Classera WhatsApp report for \(action.name)."
            activityTitle = "Report request for \(action.name)"

        case .forceFireClasseraReport:
            path = "/api/services/classera/\(id)/force-fire"
            authorizationReason = "Force-send the Classera WhatsApp report for \(action.name), bypassing the delivery guard for this run."
            activityTitle = "Forced report request for \(action.name)"
        case .forceOneClasseraReport:
            path = "/api/services/classera/\(id)/force-one"
            authorizationReason = "Force-send the \(action.name) report to ONE PERSON ONLY: \(action.recipient ?? "")."
            activityTitle = "One-person report request for \(action.name)"
        }

        await performAction(
            path: path,
            name: action.name,
            action: .start,
            authorizationReason: authorizationReason,
            refreshServices: true,
            activityTitle: activityTitle,
            body: body
        )
    }

    private func classeraPath(_ id: String) throws -> String {
        guard (1...3).map({ "classera-\($0)" }).contains(id),
              serviceSnapshot?.classera?.contains(where: { $0.id == id }) == true else {
            throw APIError.message("This Classera instance is not in the verified service snapshot.")
        }
        return "/api/services/classera/\(id)"
    }

    func loadClasseraRecipients(id: String) async throws -> [String] {
        let path = try classeraPath(id)
        let generation = refreshGeneration
        classeraRecipients[id] = nil
        let (data, response) = try await get(path: path + "/recipients")
        guard accessAllowed && generation == refreshGeneration && !Task.isCancelled else { throw CancellationError() }
        try validate(response)
        let result = try JSONDecoder().decode(ClasseraRecipientsResponse.self, from: data)
        guard result.ok && result.classera == id else { throw APIError.message("The recipient response did not match this Classera instance.") }
        let numbers = result.recipients.isEmpty ? [] : try ClasseraRecipientValidation.list(result.recipients)
        classeraRecipients[id] = numbers
        return numbers
    }

    func saveClasseraRecipients(id: String, recipients: [String]) async throws {
        let path = try classeraPath(id)
        let numbers = try ClasseraRecipientValidation.list(recipients)
        guard !previewMode && canControl && servicesError == nil && !servicesLoading else {
            throw APIError.message("Refresh and reconnect before saving recipients.")
        }
        actionBusy = true
        actionProgress = "Saving recipients…"
        defer { actionBusy = false; actionProgress = "" }
        let generation = refreshGeneration
        try await authorize("Change the WhatsApp recipients for \(id).")
        guard accessAllowed && generation == refreshGeneration && !Task.isCancelled else { throw CancellationError() }
        var command = try request(path: path + "/recipients", method: "PUT")
        command.setValue("application/json", forHTTPHeaderField: "Content-Type")
        command.httpBody = try JSONEncoder().encode(ClasseraRecipientsPayload(recipients: numbers))
        // Mutations go directly to URLSession once, without GET failover or retries.
        let (data, response) = try await session.data(for: command)
        guard accessAllowed && generation == refreshGeneration else { throw CancellationError() }
        try validate(response)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["ok"] as? Bool == false {
            throw APIError.message("The server declined the recipient changes.")
        }
        classeraRecipients[id] = numbers
        await loadServices()
    }

    static func isRefreshCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let underlying = error as NSError
        return underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorCancelled
    }

    func healthCheck() async throws -> HealthResponse {
        let (data, response) = try await get(path: "/api/health", authenticated: false)
        try validate(response)
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    // Reuse the app's URLSession, HTTPS validation and redirect protection.
    // Students uses its own Keychain connection and never sends the bearer token.
    // Mobile routes use only the Students credential and the same redirect-refusing
    // URLSession. Each invocation performs exactly one request, including mutations.
    func mobileData(connection: StudentsConnection, path: String, method: String = "GET", body: Data? = nil,
                    requestID: UUID? = nil) async throws -> Data {
        let connection = try connection.validated()
        guard accessAllowed && !previewMode && !Task.isCancelled else { throw CancellationError() }
        let epoch = studentsAccessGeneration
        var command = try request(path: path, method: method, authenticated: false, endpoint: connection.baseURL)
        command.setValue(connection.apiKey, forHTTPHeaderField: "X-API-Key")
        if let body { command.httpBody = body; command.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let requestID { command.setValue(requestID.uuidString, forHTTPHeaderField: "Idempotency-Key") }
        let (data, response) = try await session.data(for: command)
        guard accessAllowed && epoch == studentsAccessGeneration && !Task.isCancelled else { throw CancellationError() }
        try validate(response)
        return data
    }

    func authorizeMobileSend(reason: String = "Send this confirmed plain-text message to one student.", progress: String = "Authorize one plain-text message…") async throws {
        guard accessAllowed && !actionBusy && !previewMode else { throw StudentMutationFailure.notSent }
        let epoch = studentsAccessGeneration
        actionBusy = true
        actionProgress = progress
        defer { actionBusy = false; actionProgress = "" }
        try await authorize(reason)
        guard accessAllowed && epoch == studentsAccessGeneration else { throw StudentMutationFailure.notSent }
    }

    func fetchFeedback(connection: StudentsConnection) async throws -> [FeedbackRecord] {
        let data = try await mobileData(connection: connection, path: "/api/feedback?unresolved=false")
        return try FeedbackRecord.decode(data)
    }
    func resolveFeedback(connection: StudentsConnection, id: Int, resolved: Bool) async throws {
        guard id > 0 else { throw APIError.message("Invalid feedback identifier.") }
        let epoch = studentsAccessGeneration
        try await authorizeMobileSend(reason: resolved ? "Mark this school feedback report resolved." : "Reopen this school feedback report.")
        guard epoch == studentsAccessGeneration && accessAllowed else { throw CancellationError() }
        actionBusy = true
        defer { actionBusy = false }
        let data = try await mobileData(connection: connection, path: "/api/feedback/\(id)", method: "PUT", body: JSONEncoder().encode(["resolved": resolved]))
        guard try JSONDecoder().decode(StudentMutationAcknowledgement.self, from: data).ok else { throw APIError.message("Feedback update was not acknowledged. Refresh before another action.") }
    }

    func invalidateStudentsConnection() { studentsAccessGeneration += 1 }

    func fetchSubjectCatalog(connection: StudentsConnection) async throws -> SubjectCatalog {
        do {
            let data = try await mobileData(connection: connection, path: "/api/subjects/catalog")
            return try JSONDecoder().decode(SubjectCatalog.self, from: data).validated()
        } catch let http as HTTPFailure where http.status == 404 { throw SubjectEditorError.catalogUnavailable }
    }

    func fetchStudentSubjects(connection: StudentsConnection, phone: String) async throws -> StudentSubjectSelection {
        guard MobileRules.validPhone(phone) else { throw SubjectEditorError.incompatibleSelection }
        let data = try await mobileData(connection: connection, path: "/api/students/\(phone)/subjects")
        return try JSONDecoder().decode(StudentSubjectSelection.self, from: data)
    }

    func saveStudentSubjects(connection: StudentsConnection, phone: String, payload: SubjectSavePayload) async throws -> StudentSubjectSelection {
        guard MobileRules.validPhone(phone), payload.expectedRevision.count == 64,
              Set(payload.optionalSubjects).count == payload.optionalSubjects.count,
              Set(payload.optionalSubjects).isSubset(of: SubjectCatalog.optionalIDs),
              payload.removeLegacySubjectIDs.isEmpty || payload.removeLegacySubjectIDs == ["computer_science"] else {
            throw SubjectEditorError.incompatibleSelection
        }
        let epoch = studentsAccessGeneration
        do { try await authorizeMobileSend(reason: "Save this student's optional subjects. This does not send a WhatsApp message.", progress: "Authorize subject changes…") }
        catch {
            if DeviceAuthorization.isCancellation(error) || Self.isRefreshCancellation(error) { throw StudentMutationFailure.notSent }
            throw StudentMutationFailure.authorizationFailed
        }
        guard epoch == studentsAccessGeneration && accessAllowed && !Task.isCancelled else { throw StudentMutationFailure.notSent }
        actionBusy = true
        actionProgress = "Saving optional subjects…"
        defer { actionBusy = false; actionProgress = "" }
        // Exactly one PUT. Recovery is performed only with authenticated GET.
        let data = try await mobileData(connection: connection, path: "/api/students/\(phone)/subjects", method: "PUT", body: JSONEncoder().encode(payload))
        return try JSONDecoder().decode(StudentSubjectSelection.self, from: data)
    }

    func fetchStudents(connection: StudentsConnection) async throws -> StudentsSnapshot {
        let connection = try connection.validated()
        guard accessAllowed && !Task.isCancelled && !previewMode else { throw CancellationError() }
        var command = try request(path: "/api/students", authenticated: false, endpoint: connection.baseURL)
        command.setValue(connection.apiKey, forHTTPHeaderField: "X-API-Key")
        command.timeoutInterval = 10
        let epoch = studentsAccessGeneration
        let (data, response) = try await session.data(for: command)
        guard accessAllowed && epoch == studentsAccessGeneration && !Task.isCancelled else { throw CancellationError() }
        try validate(response)
        let receivedAt = Date()
        let students = try JSONDecoder().decode([Student].self, from: data)
        guard Set(students.map(\.phone)).count == students.count else {
            throw APIError.message("The Students response contains duplicate phone numbers.")
        }
        return StudentsSnapshot(students: students, receivedAt: receivedAt)
    }

    func mutateStudent(connection: StudentsConnection, phone: String, action: StudentManagementAction) async throws {
        let connection = try connection.validated()
        guard !phone.isEmpty, phone.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw APIError.message("The student identifier is invalid. Refresh the Students list.")
        }
        guard accessAllowed && !previewMode && !actionBusy && !Task.isCancelled else { throw StudentMutationFailure.notSent }
        actionBusy = true
        actionProgress = "Authorize student management…"
        defer { actionBusy = false; actionProgress = "" }
        let epoch = studentsAccessGeneration
        do {
            try await authorize("\(action.title) in the Students directory. \(action.explanation)")
        } catch {
            if DeviceAuthorization.isCancellation(error) || Self.isRefreshCancellation(error) { throw StudentMutationFailure.notSent }
            throw StudentMutationFailure.authorizationFailed
        }
        guard accessAllowed && epoch == studentsAccessGeneration && !Task.isCancelled else { throw StudentMutationFailure.notSent }
        let path = "/api/students/\(phone)" + (action == .remove ? "" : "/activity")
        var command = try request(path: path, method: action == .remove ? "DELETE" : "PUT", authenticated: false, endpoint: connection.baseURL)
        command.setValue(connection.apiKey, forHTTPHeaderField: "X-API-Key")
        if let status = action.activityStatus {
            command.setValue("application/json", forHTTPHeaderField: "Content-Type")
            command.httpBody = try JSONEncoder().encode(StudentActivityPayload(activityStatus: status.rawValue))
        }
        actionProgress = "Updating student…"
        // Exactly one mutation request. Never use GET failover or retry it.
        do {
            let (data, response) = try await session.data(for: command)
            guard accessAllowed && epoch == studentsAccessGeneration && !Task.isCancelled else { throw StudentMutationFailure.uncertain }
            try validate(response)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let acknowledgement = try? JSONDecoder().decode(StudentMutationAcknowledgement.self, from: data),
                  acknowledgement.ok else { throw StudentMutationFailure.uncertain }
        } catch let failure as HTTPFailure {
            throw failure
        } catch {
            throw StudentMutationFailure.uncertain
        }
    }

    static func encodedContainerName(_ name: String) throws -> String {
        guard !name.isEmpty, let encoded = name.addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) else {
            throw APIError.message("The container name is invalid.")
        }
        return encoded
    }

    func processAction(id: Int, name: String, action: ServerAction) async {
        guard dashboard?.processes.contains(where: { $0.id == id }) == true else { actionError = "Process is not in the verified snapshot."; return }
        await performAction(path: "/api/process/\(id)/\(action.rawValue)", name: name, action: action)
    }

    func dockerAction(name: String, action: ServerAction) async {
        guard dashboard?.containers.contains(where: { $0.name == name }) == true else { actionError = "Container is not in the verified snapshot."; return }
        do {
            let encoded = try Self.encodedContainerName(name)
            await performAction(path: "/api/docker/\(encoded)/\(action.rawValue)", name: name, action: action)
        } catch { actionError = friendly(error) }
    }

    private func performAction(path: String, name: String, action: ServerAction,
                               authorizationReason: String? = nil, refreshServices: Bool = false, activityTitle: String? = nil,
                               body: Data? = nil) async {
        guard !actionBusy else { return }
        guard !previewMode else { actionError = "Preview mode cannot send server commands."; return }
        guard canControl else { actionError = "Refresh the dashboard and reconnect before sending a command."; return }
        actionBusy = true
        actionProgress = "Authorize \(activityTitle ?? action.title)…"
        actionNotice = nil
        defer { actionBusy = false; actionProgress = "" }
        let eventTitle = activityTitle ?? "\(action.title) \(name)"
        var eventResult = ActivityEvent.Result.uncertain
        defer { library.record(title: eventTitle, result: eventResult) }
        var commandStarted = false
        let generation = refreshGeneration
        do {
            try await authorize(authorizationReason ?? "\(action.title) \(name) on your server.")
            guard accessAllowed && generation == refreshGeneration else { throw CancellationError() }
            var command = try request(path: path, method: "POST")
            if let body {
                command.httpBody = body
                command.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            actionProgress = "Sending request for \(name)…"
            commandStarted = true
            let (data, response) = try await session.data(for: command)
            guard accessAllowed && generation == refreshGeneration else { return }
            try validate(response)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["ok"] as? Bool == false || object["success"] as? Bool == false {
                throw APIError.message("The server declined the command.")
            }
            actionNotice = refreshServices ? "Request accepted for \(name). Check its last result below." : "\(action.title) requested for \(name)."
            eventResult = .accepted
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            clearNoticeSoon()
            if refreshServices { await loadServices() } else { await loadDashboard() }
        } catch {
            guard accessAllowed && generation == refreshGeneration else {
                if !commandStarted { eventResult = .cancelled }
                return
            }
            eventResult = commandStarted && error is URLError ? .uncertain : .failed
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if DeviceAuthorization.isCancellation(error) {
                eventResult = .cancelled
                actionNotice = "Cancelled. No command was sent."
                clearNoticeSoon()
            } else if !commandStarted && Self.isRefreshCancellation(error) {
                eventResult = .cancelled
                actionNotice = "Cancelled. No command was sent."
                clearNoticeSoon()
            } else if commandStarted && error is URLError {
                actionError = "The connection was interrupted. The command may have reached the server. Refresh to check before trying again."
                if Self.isRefreshCancellation(error) {
                    needsVerification = true
                } else {
                    connection = .unreachable
                    errorMessage = "Refresh to verify the server state."
                }
            } else {
                actionError = friendly(error)
                if let http = error as? HTTPFailure, [401, 403].contains(http.status) {
                    connection = .unauthorized
                    errorMessage = actionError
                }
            }
        }
    }

    private func clearNoticeSoon() {
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self.actionNotice = nil
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else { throw HTTPFailure(status: http.statusCode) }
    }

    func friendly(_ error: Error) -> String {
        if let http = error as? HTTPFailure {
            switch http.status {
            case 401, 403: return "Authentication failed. Check your server token in Settings."
            case 300...399: return "The server redirected this request. Check the HTTPS URL in Settings."
            default: return "The server returned HTTP \(http.status). Try refreshing shortly."
            }
        }
        if Self.isRefreshCancellation(error) { return "Refresh cancelled. Your last snapshot is available." }
        if error is DecodingError { return "The server response could not be read. Your last snapshot is still available." }
        if let url = error as? URLError {
            if url.code == .timedOut { return "The server took too long to respond. Pull down to retry." }
            return "Cannot reach the server. Check your internet connection and try again."
        }
        return error.localizedDescription
    }
}

struct HTTPFailure: Error { let status: Int }
enum APIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}






// Staged only. No UI, scene lifecycle or web view calls this until live verification.
extension ServerAPI {
    func makeVerifiedJarvisBroker() throws -> JarvisAppSessionBroker {
        guard JarvisAppSessionRollout.enabled else { throw JarvisBootstrapError.notVerified }
        let originalURL = try Self.validatedBaseURL(baseURL)
        guard originalURL.absoluteString == "https://control.admin-ai.site" || originalURL.absoluteString == "https://control.admin-ai.site/" else {
            throw JarvisBootstrapError.invalidResponse
        }
        guard accessAllowed else { throw JarvisBootstrapError.locked }
        let originalToken = tokenProvider()
        guard !originalToken.isEmpty else { throw JarvisBootstrapError.locked }
        return JarvisAppSessionBroker(requestBuilder: { [weak self] path, body in
            guard let self, self.accessAllowed else { throw JarvisBootstrapError.locked }
            var command = try self.request(path: path, method: "POST", endpoint: originalURL.absoluteString)
            command.httpBody = body
            return command
        }, isAllowed: { [weak self] in
            guard let self else { return false }
            return self.accessAllowed && self.baseURL == originalURL.absoluteString && self.tokenProvider() == originalToken
        })
    }
}

