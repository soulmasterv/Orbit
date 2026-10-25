import SwiftUI

struct StudentsView: View {
    @ObservedObject var api: ServerAPI
    @StateObject private var store: StudentsStore
    @EnvironmentObject private var mobile: MobileStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var search = ""
    @State private var filter: StudentsFilter = .all
    @State private var activity: StudentActivityStatus?
    private let embedded: Bool
    @State private var selectedGrade = ""
    @State private var refreshOwner = UUID()

    init(api: ServerAPI, store: StudentsStore? = nil, embedded: Bool = false) {
        self.embedded = embedded
        self.api = api
        _store = StateObject(wrappedValue: store ?? StudentsStore(api: api))
    }

    private var refreshEnabled: Bool { visible && scenePhase == .active && api.accessAllowed }
    private var grades: [String] {
        StudentsDirectory.grades(in: store.snapshot?.students ?? [])
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                directoryHeader.padding(.horizontal, 16).padding(.bottom, 14)
                if let error = store.error {
                    Panel {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.subheadline).foregroundStyle(.orange)
                            if store.snapshot != nil { Text("Showing the last successful list.").font(.caption).foregroundStyle(.secondary) }
                            NavigationLink("Connection settings") { StudentsSettingsView(api: api) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let actionError = store.actionError {
                    Label(actionError, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                }
                if let notice = store.actionNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if store.loading && store.snapshot == nil {
                    ProgressView("Loading students…").frame(maxWidth: .infinity).padding(.vertical, 32)
                } else if let snapshot = store.snapshot {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        directory(snapshot, at: .now)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(StudentAppearance())
        .navigationTitle(embedded ? "Orbit" : "Students").navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                RefreshIndicator(loading: store.loading) { Task { if refreshEnabled { await store.refresh() } } }
            }
        }
        .onAppear { store.claimVisibility(refreshOwner); visible = true }
        .onChange(of: grades) { _, available in
            if !selectedGrade.isEmpty && !available.contains(selectedGrade) { selectedGrade = "" }
        }
        .onDisappear { visible = false; store.suspend(owner: refreshOwner) }
        .task(id: refreshEnabled) {
            guard refreshEnabled else { store.suspend(owner: refreshOwner, clear: !api.accessAllowed); return }
            await store.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard refreshEnabled && !Task.isCancelled else { return }
                await store.refresh()
            }
        }
        .refreshable { if refreshEnabled { await store.refresh() } }
    }

    private var directoryHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudentSearchField(text: $search)
            HStack {
                Text("School assistant").font(.caption).foregroundStyle(StudentPalette.secondary)
                Spacer()
                Menu {
                    Picker("Messaging window", selection: $filter) {
                        ForEach(StudentsFilter.allCases) { item in Text(item.rawValue).tag(item) }
                    }
                    if filter == .grade {
                        Picker("Grade", selection: $selectedGrade) {
                            Text("All grades").tag("")
                            ForEach(grades, id: \.self) { grade in Text("Grade \(grade)").tag(grade) }
                        }
                    }
                } label: {
                    Label(filter == .grade && !selectedGrade.isEmpty ? "Grade \(selectedGrade)" : filter.rawValue,
                          systemImage: "line.3.horizontal.decrease").font(.caption.weight(.medium))
                }
                Menu {
                    NavigationLink("Student tools and settings") { MobileHubView(api: api) }
                    NavigationLink("Feedback") { MobileFeedbackView(api: api, selectedID: nil) }
                    NavigationLink("Recent events") { MobileEventsView(api: api) }
                    if mobile.state?.outbox != nil {
                        NavigationLink("Review saved message") { MessageOutboxView() }
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 30, minHeight: 30) }
                    .accessibilityLabel("Student tools, feedback and events")
            }
            StudentAccessFilters(selection: $activity)
            if mobile.state?.outbox != nil {
                NavigationLink { MessageOutboxView() } label: { Label("Review saved message", systemImage: "tray") }
                    .font(.caption.weight(.medium))
            }
            SnapshotStamp(date: store.snapshot?.receivedAt, failed: store.error != nil)
        }.frame(maxWidth: .infinity, alignment: .leading)
         .accessibilityIdentifier("students.header")
    }

    private func directory(_ snapshot: StudentsSnapshot, at now: ContinuousClock.Instant) -> some View {
        let rows = StudentsDirectory.filtered(snapshot, search: search, filter: filter, grade: selectedGrade, at: now)
            .filter { activity == nil || $0.activityStatus == activity }
        let open = snapshot.students.filter { snapshot.isWindowOpen(for: $0, at: now) }.count
        return VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack { resultCount(rows.count, total: snapshot.students.count); Spacer(); Text("\(open) window open").font(.caption).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 4) { resultCount(rows.count, total: snapshot.students.count); Text("\(open) window open").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            if rows.isEmpty {
                ContentUnavailableView(snapshot.students.isEmpty ? "No students yet" : "No matching students",
                    systemImage: "person.3",
                    description: Text(snapshot.students.isEmpty ? "Profiles appear after students contact the bot." : "Try another search, window filter or grade."))
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, student in
                NavigationLink { StudentDetailView(api: api, store: store, phone: student.phone) } label: {
                    StudentDirectoryCard(snapshot: snapshot, student: student, now: now, alternate: !index.isMultiple(of: 2))
                }.buttonStyle(.plain)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultCount(_ count: Int, total: Int) -> some View {
        Text(count == total ? StudentsDirectory.countLabel(count) : "\(count) of \(StudentsDirectory.countLabel(total))")
            .font(.subheadline.weight(.semibold))
    }
}

struct StudentDirectoryCard: View {
    let snapshot: StudentsSnapshot
    let student: Student
    let now: ContinuousClock.Instant
    var alternate = false
    var body: some View {
        StudentCompactRow(name: student.displayName, phone: student.phone,
            chips: [student.state == "active" ? student.gradeLabel : student.stateLabel],
            status: student.activityStatus,
            note: snapshot.isWindowOpen(for: student, at: now) ? "Window open · \(snapshot.countdown(for: student, at: now))" : "Window closed",
            alternate: alternate)
    }
}

private struct StudentWindowStatus: View {
    let snapshot: StudentsSnapshot
    let student: Student
    let now: ContinuousClock.Instant
    private var open: Bool { snapshot.isWindowOpen(for: student, at: now) }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(open ? StudentPalette.accent : Color.gray).frame(width: 7, height: 7)
            Text(open ? "Window open · \(snapshot.countdown(for: student, at: now))" : "Window closed")
                .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(open ? "Window open, \(snapshot.countdown(for: student, at: now)) remaining" : "Window closed")
    }
}

struct StudentDetailView: View {
    @ObservedObject var api: ServerAPI
    @ObservedObject var store: StudentsStore
    let phone: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var refreshOwner = UUID()
    @State private var pending: StudentManagementAction?
    private var refreshEnabled: Bool { visible && scenePhase == .active && api.accessAllowed }

    var body: some View {
        Form {
            if let snapshot = store.snapshot, let student = snapshot.students.first(where: { $0.phone == phone }) {
                Section("Student") {
                    LabeledContent("Name", value: student.displayName)
                    LabeledContent("Phone", value: student.phone).textSelection(.enabled)
                    LabeledContent("Onboarding", value: student.stateLabel)
                    if student.state == "active" {
                        LabeledContent("Grade", value: student.displayGrade)
                    } else {
                        LabeledContent("State", value: student.stateLabel)
                    }
                }
                Section("Activity") {
                    LabeledContent("First seen", value: timestamp(student.firstSeenDate))
                    LabeledContent("Last message", value: timestamp(student.lastInboundDate))
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        HStack {
                            Text("Messaging window")
                            Spacer()
                            StudentWindowStatus(snapshot: snapshot, student: student, now: ContinuousClock.now)
                        }
                    }
                }
                Section("Bot reply activity") {
                    StudentActivityBadge(status: student.activityStatus)
                    Text("Separate from onboarding and the WhatsApp 24-hour messaging window. Server-side enforcement is required.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let reason = store.managementUnavailableReason(for: student) {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(actions(for: student.activityStatus)) { action in
                        Button(action.title, role: action == .remove || action == .block ? .destructive : nil) {
                            pending = action
                        }.disabled(store.managementUnavailableReason(for: student) != nil)
                    }
                }
                Section("Subjects") {
                    NavigationLink { SubjectEditorView(api: api, phone: phone) } label: {
                        Label("Edit optional subjects", systemImage: "checklist")
                    }.disabled(store.mutationBusy || !api.accessAllowed)
                    Text("Review required and optional subjects. Changes are saved together and do not send a message.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Manual message") {
                    NavigationLink("Compose plain text to this student") {
                        StudentMessageComposer(api: api, students: store, phone: phone)
                    }.disabled(!MobileRules.canSend(student, snapshot: snapshot) || store.requiresVerification || store.mutationBusy)
                    Text("Requires active onboarding, Allowed activity and an open 24-hour window. Server support is checked before sending.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Student details are unavailable. Return to Students and refresh.")
            }
            if store.actionError != nil || store.error != nil || store.actionNotice != nil || store.requiresVerification {
                Section("Management result") {
                    if let failure = store.actionError { Text(failure).foregroundStyle(.orange) }
                    if let failure = store.error { Text(failure).foregroundStyle(.orange) }
                    if let notice = store.actionNotice { Text(notice).foregroundStyle(.secondary) }
                    Button("Refresh Students") { Task { await store.refresh() } }
                        .disabled(store.mutationBusy || store.loading || !api.accessAllowed)
                }
            }
        }.scrollContentBackground(.hidden).modifier(StudentAppearance())
        .navigationTitle("Student Details").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(store.mutationBusy)
        .onAppear { store.claimVisibility(refreshOwner); visible = true }
        .onDisappear { visible = false; store.suspend(owner: refreshOwner) }
        .task(id: refreshEnabled) {
            guard refreshEnabled else { store.suspend(owner: refreshOwner, clear: !api.accessAllowed); return }
            await store.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard refreshEnabled && !Task.isCancelled else { return }
                await store.refresh()
            }
        }
        .refreshable { if refreshEnabled { await store.refresh() } }
        .confirmationDialog(pending.map { "\($0.title)?" } ?? "Confirm student action",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible, presenting: pending) { action in
                Button(action.title, role: action == .remove || action == .block ? .destructive : nil) {
                    Task {
                        let succeeded = await store.manage(phone: phone, action: action)
                        if succeeded && action == .remove { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { action in Text(action.explanation + " Authorize on your iPhone next.") }
    }

    private func timestamp(_ value: Date?) -> String {
        guard let value else { return "Unavailable" }
        return value.formatted(date: .abbreviated, time: .shortened)
    }
    private func actions(for status: StudentActivityStatus) -> [StudentManagementAction] {
        switch status {
        case .blocked: return [.unblock, .remove]
        case .suspended: return [.resume, .block, .remove]
        case .allowed, .unknown: return [.suspend, .block, .remove]
        }
    }
}

private struct StudentActivityBadge: View {
    let status: StudentActivityStatus
    var body: some View { StudentStatusPill(status: status) }
}





