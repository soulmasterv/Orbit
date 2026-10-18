import Foundation
import Combine

@MainActor
final class SubjectEditorStore: ObservableObject {
    let phone: String
    @Published private(set) var catalog: SubjectCatalog?
    @Published private(set) var selection: StudentSubjectSelection?
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var removeCombined = false
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var verified = false
    @Published private(set) var needsReview = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private let api: ServerAPI
    private let connectionProvider: () throws -> StudentsConnection?
    private let fetchCatalog: (StudentsConnection) async throws -> SubjectCatalog
    private let fetchSelection: (StudentsConnection, String) async throws -> StudentSubjectSelection
    private let submit: (StudentsConnection, String, SubjectSavePayload) async throws -> StudentSubjectSelection
    private var connection: StudentsConnection?
    private var generation = 0

    init(api: ServerAPI, phone: String,
         connectionProvider: @escaping () throws -> StudentsConnection? = KeychainManager.loadStudentsConnection,
         fetchCatalog: ((StudentsConnection) async throws -> SubjectCatalog)? = nil,
         fetchSelection: ((StudentsConnection, String) async throws -> StudentSubjectSelection)? = nil,
         submit: ((StudentsConnection, String, SubjectSavePayload) async throws -> StudentSubjectSelection)? = nil) {
        self.api = api; self.phone = phone; self.connectionProvider = connectionProvider
        self.fetchCatalog = fetchCatalog ?? { try await api.fetchSubjectCatalog(connection: $0) }
        self.fetchSelection = fetchSelection ?? { try await api.fetchStudentSubjects(connection: $0, phone: $1) }
        self.submit = submit ?? { try await api.saveStudentSubjects(connection: $0, phone: $1, payload: $2) }
    }

    var hasChanges: Bool {
        guard let selection else { return false }
        return selectedIDs != Set(selection.optionalSubjects) || removeCombined
    }
    var canEdit: Bool {
        verified && catalog != nil && selection?.editable == true && !loading && !saving && !needsReview && api.accessAllowed
    }
    var canSave: Bool { canEdit && hasChanges && !api.actionBusy }
    var orderedSelectedIDs: [String] { catalog?.optionalSubjects.map(\.id).filter { selectedIDs.contains($0) } ?? [] }

    func toggle(_ id: String) {
        guard canEdit, catalog?.optionalSubjects.contains(where: { $0.id == id && $0.selectable }) == true else { return }
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }
    func setRemoveCombined(_ remove: Bool) {
        guard canEdit, selection?.legacySubjectIDs.contains("computer_science") == true else { return }
        removeCombined = remove
    }
    func invalidate() { generation += 1; verified = false; loading = false }

    private func configured() throws -> StudentsConnection {
        guard let value = try connectionProvider() else { throw SubjectEditorError.notConfigured }
        return try value.validated()
    }
    private func isCurrent(_ epoch: Int, connection: StudentsConnection) -> Bool {
        guard generation == epoch && api.accessAllowed else { return false }
        return (try? configured()) == connection
    }
    private func apply(_ value: StudentSubjectSelection) {
        selection = value; selectedIDs = Set(value.optionalSubjects)
        removeCombined = false; needsReview = false; verified = true
    }

    func load() async {
        guard api.accessAllowed && !saving && !Task.isCancelled else { return }
        generation += 1; let epoch = generation
        loading = true; verified = false; error = nil
        defer { if generation == epoch { loading = false } }
        do {
            guard MobileRules.validPhone(phone) else { throw SubjectEditorError.incompatibleSelection }
            let configured = try configured()
            guard connection == nil || connection == configured else { throw SubjectEditorError.settingsChanged }
            // Verify the real catalog first. No fallback catalog or guessed IDs.
            let catalog = try await fetchCatalog(configured).validated()
            guard isCurrent(epoch, connection: configured) && !Task.isCancelled else { return }
            self.catalog = catalog
            let value = try await fetchSelection(configured, phone).validated(phone: phone, catalog: catalog)
            guard isCurrent(epoch, connection: configured) && !Task.isCancelled else { return }
            let hadEdits = hasChanges
            let previousRevision = selection?.revision
            connection = configured
            if hadEdits && previousRevision != value.revision && !matchesDraft(value) {
                selection = value; verified = true; needsReview = true
                notice = "The server choices changed. Review the latest choices before editing or saving again. Your unsaved choices remain below."
            } else if hadEdits && previousRevision == value.revision {
                selection = value; verified = true // Preserve unsaved checkboxes on a safe refresh.
            } else { apply(value) }
        } catch {
            guard generation == epoch && api.accessAllowed && !ServerAPI.isRefreshCancellation(error) else { return }
            verified = false; self.error = SubjectEditorError.message(error)
            if (error as? HTTPFailure)?.status == 404 { selection = nil }
        }
    }

    func useLatestChoices() {
        guard verified && !saving && !loading, let selection else { return }
        apply(selection); error = nil; notice = "Latest server choices loaded. Make any changes, then Save once."
    }
    private func matchesDraft(_ value: StudentSubjectSelection) -> Bool {
        Set(value.optionalSubjects) == selectedIDs && (!removeCombined || !value.legacySubjectIDs.contains("computer_science"))
    }

    func save() async {
        guard canSave, let catalog, let before = selection, let connection else { return }
        guard (try? configured()) == connection else { verified = false; error = SubjectEditorError.message(SubjectEditorError.settingsChanged); return }
        generation += 1; let epoch = generation
        saving = true; error = nil; notice = nil
        defer { saving = false }
        let payload = SubjectSavePayload(optionalSubjects: orderedSelectedIDs, expectedRevision: before.revision,
            removeLegacySubjectIDs: removeCombined ? ["computer_science"] : [])
        do {
            let value = try await submit(connection, phone, payload).validated(phone: phone, catalog: catalog)
            guard isCurrent(epoch, connection: connection) else { return }
            apply(value)
            notice = "Subjects saved. No WhatsApp message was sent. Older subject-picker buttons are no longer valid."
        } catch {
            guard isCurrent(epoch, connection: connection) else { return }
            if let failure = error as? StudentMutationFailure {
                switch failure {
                case .notSent: self.error = "Save cancelled. No subject update was sent."; return
                case .authorizationFailed: self.error = "Device authorization failed. No subject update was sent."; return
                case .uncertain: break
                }
            }
            self.error = SubjectEditorError.message(error)
            if let http = error as? HTTPFailure {
                if [401, 403, 404].contains(http.status) {
                    verified = false
                    if http.status == 404 { selection = nil }
                    return
                }
                if http.status == 422 { return }
            }
            // A lost response can follow a successful PUT. Never submit again.
            verified = false
            let conflict = (error as? HTTPFailure)?.status == 409
            if conflict { needsReview = true }
            do {
                let current = try await fetchSelection(connection, phone).validated(phone: phone, catalog: catalog)
                guard isCurrent(epoch, connection: connection) else { return }
                if !conflict && matchesDraft(current) {
                    apply(current); self.error = nil
                    notice = "The server now reports the requested choices. No save was retried."
                } else {
                    selection = current; verified = true; needsReview = true
                    notice = "Latest server choices loaded. Review them before another save. Your unsaved choices are retained."
                }
            } catch {
                guard isCurrent(epoch, connection: connection) else { return }
                self.error = "The save outcome is unconfirmed. " + SubjectEditorError.message(error) + " Refresh to inspect current choices; no update will be resent automatically."
            }
        }
    }
}
