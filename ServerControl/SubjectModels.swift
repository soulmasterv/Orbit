import Foundation

struct SubjectDefinition: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let compulsory: Bool
    let selectable: Bool
    let reminderEligible: Bool
    enum CodingKeys: String, CodingKey {
        case id, name, compulsory, selectable
        case reminderEligible = "reminder_eligible"
    }
}

struct LegacySubjectDescription: Decodable {
    let id: String?
    let name: String?
}

struct SubjectCatalog: Decodable {
    static let supportedVersion = "subject-editor-v1"
    static let requiredIDs: Set<String> = ["english", "arabic", "religion"]
    static let optionalIDs: Set<String> = ["advanced_math", "statistics", "chemistry", "biology", "physics", "economics", "accounting", "computer_science_only", "computer_studies", "psychology"]
    let version: String
    let compulsorySubjects: [SubjectDefinition]
    let optionalSubjects: [SubjectDefinition]
    let choicePairs: [[String]]
    let legacySubjects: [LegacySubjectDescription]
    enum CodingKeys: String, CodingKey {
        case version
        case compulsorySubjects = "compulsory_subjects", optionalSubjects = "optional_subjects"
        case choicePairs = "choice_pairs", legacySubjects = "legacy_subjects"
    }
    // Quraan is intentionally not rendered as a compulsory subject. IDs outside
    // this display list remain server-owned; no compulsory IDs are sent in PUT.
    var includedSubjects: [SubjectDefinition] {
        compulsorySubjects.filter { Self.requiredIDs.contains($0.id) }
    }
    func validated() throws -> SubjectCatalog {
        guard version == Self.supportedVersion,
              optionalSubjects.count == 10, Set(optionalSubjects.map(\.id)) == Self.optionalIDs,
              optionalSubjects.allSatisfy({ !$0.compulsory && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              includedSubjects.count == 3, Set(includedSubjects.map(\.id)) == Self.requiredIDs,
              includedSubjects.allSatisfy({ $0.compulsory && !$0.selectable && !$0.name.isEmpty }),
              choicePairs.count == 5, choicePairs.allSatisfy({ $0.count == 2 }),
              Set(choicePairs.flatMap { $0 }) == Self.optionalIDs else {
            throw SubjectEditorError.incompatibleCatalog
        }
        return self
    }
    func label(for id: String) -> String {
        optionalSubjects.first { $0.id == id }?.name ?? legacySubjects.first { $0.id == id }?.name ?? id
    }
}

struct StudentSubjectSelection: Decodable, Equatable {
    let phone: String
    let revision: String
    let catalogVersion: String
    let editable: Bool
    let optionalSubjects: [String]
    let compulsorySubjects: [String]
    let legacySubjectIDs: [String]
    let unknownSubjectIDs: [String]
    let effectiveSubjects: [String]
    enum CodingKeys: String, CodingKey {
        case phone, revision, editable
        case catalogVersion = "catalog_version", optionalSubjects = "optional_subjects"
        case compulsorySubjects = "compulsory_subjects", legacySubjectIDs = "legacy_subject_ids"
        case unknownSubjectIDs = "unknown_subject_ids", effectiveSubjects = "effective_subjects"
    }
    func validated(phone: String, catalog: SubjectCatalog) throws -> StudentSubjectSelection {
        guard self.phone == phone, catalogVersion == catalog.version, revision.count == 64,
              Set(optionalSubjects).count == optionalSubjects.count,
              Set(optionalSubjects).isSubset(of: Set(catalog.optionalSubjects.map(\.id))),
              SubjectCatalog.requiredIDs.isSubset(of: Set(compulsorySubjects)) else {
            throw SubjectEditorError.incompatibleSelection
        }
        return self
    }
}

struct SubjectSavePayload: Encodable, Equatable {
    let optionalSubjects: [String]
    let expectedRevision: String
    let removeLegacySubjectIDs: [String]
    enum CodingKeys: String, CodingKey {
        case optionalSubjects = "optional_subjects", expectedRevision = "expected_revision"
        case removeLegacySubjectIDs = "remove_legacy_subject_ids"
    }
}

enum SubjectEditorError: Error {
    case incompatibleCatalog, incompatibleSelection, notConfigured, catalogUnavailable, studentRemoved, settingsChanged
    static func message(_ error: Error) -> String {
        switch error {
        case SubjectEditorError.incompatibleCatalog: return "The subject catalog is incompatible. Save is disabled until the server provides the complete subject-editor-v1 catalog."
        case SubjectEditorError.incompatibleSelection: return "The student's subject response is incompatible. Refresh before editing; no IDs were remapped."
        case SubjectEditorError.notConfigured: return "Configure the Students connection in Settings first."
        case SubjectEditorError.catalogUnavailable: return "The subject catalog endpoint is not available yet. Save is disabled."
        case SubjectEditorError.studentRemoved: return "Student not found or removed. Return to Students and refresh."
        case SubjectEditorError.settingsChanged: return "Students connection settings changed. Reopen this editor before saving."
        default:
            if let http = error as? HTTPFailure {
                switch http.status {
                case 401: return "Students authentication failed (401). Check the Students API key in Settings."
                case 404: return "Student not found or removed. Return to Students and refresh."
                case 409: return "The choices changed on the server. Review the latest choices before saving again."
                case 422: return "The server rejected these subject choices (422). Review your selections."
                case 403: return "Subject editing is not permitted for this student."
                case 300...399: return "Redirect refused. Check the Students HTTPS address in Settings."
                default: return "The server could not confirm the subject update. No save was retried."
                }
            }
            if error is DecodingError { return "The subject response could not be read. Save is disabled until a compatible response loads." }
            return "The connection was interrupted. Check the latest server choices before another save."
        }
    }
}
