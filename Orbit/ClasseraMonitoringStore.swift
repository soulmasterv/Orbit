import SwiftUI
import Security

struct ClasseraPendingOperation: Codable {
    let endpoint: String
    let payload: ClasseraReadyPayload
}
enum ClasseraOperationVault {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Orbit",
         kSecAttrAccount as String: "class-ready-operation.v1"]
    }
    static func load() throws -> ClasseraPendingOperation? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw APIError.message("Unlock iPhone to review the saved notification operation.")
        }
        return try JSONDecoder().decode(ClasseraPendingOperation.self, from: data)
    }
    static func save(_ operation: ClasseraPendingOperation?) throws {
        guard let operation else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw APIError.message("Could not clear the saved operation.") }
            return
        }
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(operation),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw APIError.message("Could not save the request identity securely. No notification was submitted.") }
    }
}

@MainActor
final class ClasseraMonitoringStore: ObservableObject {
    @Published var waiting: ClasseraWaitingResponse?
    @Published var history: ClasseraHistoryResponse?
    @Published var statistics: ClasseraStatisticsResponse?
    @Published var preview: ClasseraReadyPreview?
    @Published var operation: ClasseraReadyOperation?
    @Published var pending: ClasseraPendingOperation?
    @Published var error: String?
    @Published var loading = false
    @Published var mutationBusy = false
    @Published private(set) var vaultReady = false
    private var generation = 0
    private let loadPending: () throws -> ClasseraPendingOperation?
    private let savePending: (ClasseraPendingOperation?) throws -> Void
    init(loadPending: @escaping () throws -> ClasseraPendingOperation? = ClasseraOperationVault.load,
         savePending: @escaping (ClasseraPendingOperation?) throws -> Void = ClasseraOperationVault.save) {
        self.loadPending = loadPending; self.savePending = savePending
    }
    func restore() {
        vaultReady = false
        do { pending = try loadPending(); vaultReady = true }
        catch { self.error = "Unlock iPhone to read the saved operation. Sending remains unavailable." }
    }
    func clear() {
        generation += 1; loading = false; preview = nil; vaultReady = false
        waiting = nil; history = nil; statistics = nil; operation = nil
    }
    func load(api: ServerAPI, tab: Int, query: [String: String] = [:]) async {
        generation += 1; let epoch = generation; loading = true
        defer { if epoch == generation { loading = false } }
        do {
            switch tab {
            case 0:
                let value = try await api.classeraWaitingList()
                guard epoch == generation && api.accessAllowed && !Task.isCancelled else { return }
                waiting = value
            case 1:
                let value = try await api.classeraDeliveryHistory(query)
                guard epoch == generation && api.accessAllowed && !Task.isCancelled else { return }
                history = value
            default:
                let value = try await api.classeraDailyStatistics(query)
                guard epoch == generation && api.accessAllowed && !Task.isCancelled else { return }
                statistics = value
            }
            error = nil
        } catch {
            if epoch == generation && !ServerAPI.isRefreshCancellation(error) { self.error = safe(error) }
        }
    }
    func loadPreview(api: ServerAPI, classID: String) async {
        generation += 1; let epoch = generation; loading = true; preview = nil
        defer { if epoch == generation { loading = false } }
        do {
            let value = try await api.classeraReadyPreview(classID)
            guard epoch == generation && api.accessAllowed && !Task.isCancelled else { return }
            preview = value; error = nil
        } catch {
            if epoch == generation && !ServerAPI.isRefreshCancellation(error) { self.error = safe(error) }
        }
    }
    func submit(api: ServerAPI, confirmed: ClasseraReadyPreview) async {
        guard vaultReady, !mutationBusy, pending == nil, let preview, preview.can_execute,
              preview.class_id == confirmed.class_id, preview.revision == confirmed.revision,
              preview.eligible_count == confirmed.eligible_count else { return }
        let payload: ClasseraReadyPayload
        do { payload = try ClasseraReadyPayload(preview: preview) }
        catch { self.error = safe(error); return }
        generation += 1; let epoch = generation; mutationBusy = true
        defer { mutationBusy = false }
        do {
            let result = try await api.sendClasseraReady(payload) {
                let value = ClasseraPendingOperation(endpoint: api.baseURL, payload: payload)
                try self.savePending(value)
                self.pending = value
            }
            guard epoch == generation && api.accessAllowed else { return }
            operation = result; self.preview = nil; error = nil
        } catch {
            guard epoch == generation && api.accessAllowed else { return }
            self.error = safe(error)
            if let failure = error as? ClasseraMonitoringFailure, case .http(_, "sending_disabled") = failure {
                do { try savePending(nil); pending = nil } catch { }
            }
            // An uncertain mutation is never retried; the saved UUID supports GET-only recovery.
        }
    }
    func checkOperation(api: ServerAPI) async {
        guard !mutationBusy, let pending else { return }
        guard pending.endpoint == api.baseURL else {
            error = "This saved operation belongs to another configured server. Restore that connection to review it."; return
        }
        generation += 1; let epoch = generation; loading = true
        defer { if epoch == generation { loading = false } }
        do {
            let value = try await api.classeraReadyOperation(pending.payload.request_id)
            guard epoch == generation && api.accessAllowed && !Task.isCancelled else { return }
            guard value.class_id == pending.payload.class_id else { throw ClasseraMonitoringFailure.invalidResponse }
            operation = value; error = nil
        } catch {
            if epoch == generation && !ServerAPI.isRefreshCancellation(error) { self.error = safe(error) }
        }
    }
    func reviewed() {
        guard operation?.status == "complete" else { return }
        do { try savePending(nil); pending = nil; operation = nil; preview = nil }
        catch { self.error = "Could not clear the saved operation. No new send is enabled." }
    }
    private func safe(_ error: Error) -> String {
        if let error = error as? ClasseraMonitoringFailure { return error.localizedDescription }
        if let error = error as? APIError { return error.errorDescription ?? "Operation unavailable." }
        return "Classera could not be reached. Refresh read-only data; submitted notifications must be checked using their saved operation."
    }
}
