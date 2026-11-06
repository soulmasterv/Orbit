import SwiftUI

struct ClasseraExamBreakState: Decodable {
    struct ClassState: Decodable {
        let effective_paused: Bool
        let eligible_from: String?
    }

    let global_paused: Bool
    let classes: [String: ClassState]

    var canResumeAll: Bool { global_paused || classes.values.contains { $0.effective_paused } }
}

struct ClasseraExamBreakChange {
    enum Scope: String, CaseIterable {
        case all
        case classF = "12F"
        case classE = "12E"
    }

    let scope: Scope
    let paused: Bool

    var pathSuffix: String { "/\(scope.rawValue)/\(paused ? "pause" : "resume")" }
    var title: String {
        (paused ? "Pause " : "Resume ") + (scope == .all ? "All" : scope.rawValue)
    }
}

struct ClasseraExamBreakSection: View {
    @ObservedObject var api: ServerAPI
    var onForceSend: (ClasseraStatus) -> Void
    @Environment(\.scenePhase) private var phase
    @State private var state: ClasseraExamBreakState?
    @State private var pending: ClasseraExamBreakChange?
    @State private var activeRequest: UUID?
    @State private var failure: String?
    @State private var requiresRefresh = false

    private var visible: Bool { api.accessAllowed && phase == .active }
    private var canChange: Bool { visible && api.canControl && activeRequest == nil && !requiresRefresh }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Label("Exam Break Mode", systemImage: "pause.circle").font(.headline)
                Text("A global pause overrides both class controls. Scheduled delivery resumes from the displayed Cairo date.")
                    .font(.caption).foregroundStyle(.secondary)
                if visible {
                    if let state {
                        LabeledContent("Global pause", value: state.global_paused ? "On" : "Off")
                        HStack {
                            action(.init(scope: .all, paused: true), disabled: state.global_paused)
                            action(.init(scope: .all, paused: false), disabled: !state.canResumeAll)
                        }
                    }
                    classRow(scope: .classF, serviceID: "classera-1", title: "Classera 1 (F)")
                    classRow(scope: .classE, serviceID: "classera-2", title: "Classera 2 (E)")
                    if activeRequest != nil { ProgressView("Checking Exam Break status…").font(.caption) }
                    if let failure { Text(failure).font(.subheadline).foregroundStyle(.orange) }
                    Button("Refresh Exam Break status") { Task { await update() } }
                        .disabled(activeRequest != nil || api.actionBusy)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(api.latestReportsContext)|\(visible)") {
            activeRequest = nil
            pending = nil
            state = nil
            failure = nil
            requiresRefresh = false
            if visible { await update() }
        }
        .confirmationDialog(pending?.title ?? "Confirm Exam Break change", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { change in
            Button(change.title) {
                pending = nil
                Task { await update(change) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { change in
            if change.paused {
                Text("Pause scheduled report delivery for \(change.scope == .all ? "both classes" : change.scope.rawValue)?")
            } else {
                Text("Scheduled reports become eligible from the Cairo date returned by the server.")
            }
        }
    }

    private func classRow(scope: ClasseraExamBreakChange.Scope, serviceID: String, title: String) -> some View {
        let settings = state?.classes[scope.rawValue]
        let globalPaused = state?.global_paused == true
        let service = api.serviceSnapshot?.classera?.first { $0.id == serviceID }
        return VStack(alignment: .leading, spacing: 7) {
            Divider()
            LabeledContent(title, value: settings.map { classStatus($0, globalPaused: globalPaused) } ?? "Unavailable")
                .font(.subheadline.weight(.semibold))
            if let settings, let date = settings.eligible_from, !settings.effective_paused {
                Text("Scheduled delivery from \(date) Cairo")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let settings {
                    action(.init(scope: scope, paused: !settings.effective_paused), disabled: globalPaused)
                }
                if let service {
                    Button("Force Send", role: .destructive) { onForceSend(service) }
                        .buttonStyle(.bordered)
                        .disabled(service.canForceFire != true || !api.canControl)
                        .accessibilityLabel("Force Send \(scope.rawValue)")
                }
            }
        }
    }

    private func classStatus(_ settings: ClasseraExamBreakState.ClassState, globalPaused: Bool) -> String {
        if globalPaused { return "Paused globally" }
        if settings.effective_paused { return "Paused" }
        return settings.eligible_from == nil ? "Active" : "Scheduled"
    }

    private func action(_ change: ClasseraExamBreakChange, disabled: Bool) -> some View {
        Button(change.title) { pending = change }
            .buttonStyle(.bordered)
            .disabled(disabled || !canChange)
    }

    private func update(_ change: ClasseraExamBreakChange? = nil) async {
        guard visible, activeRequest == nil, change == nil || canChange else { return }
        let context = api.latestReportsContext
        let requestID = UUID()
        activeRequest = requestID
        failure = nil
        defer { if activeRequest == requestID { activeRequest = nil } }

        do {
            let result: ClasseraExamBreakState
            if let change { result = try await api.setClasseraExamBreak(change) }
            else { result = try await api.classeraExamBreak() }
            guard activeRequest == requestID, visible, context == api.latestReportsContext, !Task.isCancelled else { return }
            state = result
            requiresRefresh = false
        } catch {
            guard activeRequest == requestID, visible, context == api.latestReportsContext, !Task.isCancelled else { return }
            if (error as? HTTPFailure)?.status == 409 {
                failure = "A report or status update is in progress. Wait a moment, refresh, then retry."
            } else if change != nil {
                failure = "The change could not be confirmed. Refresh Exam Break status before trying again."
            } else {
                failure = "Exam Break status is unavailable. Try refreshing."
            }
            requiresRefresh = true
        }
    }
}
