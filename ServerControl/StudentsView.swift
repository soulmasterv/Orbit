import SwiftUI

struct StudentsView: View {
    @ObservedObject var api: ServerAPI
    @StateObject private var store: StudentsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var search = ""
    @State private var filter: StudentsFilter = .all
    @State private var selectedGrade = ""
    @State private var refreshOwner = UUID()

    init(api: ServerAPI) {
        self.api = api
        _store = StateObject(wrappedValue: StudentsStore(api: api))
    }

    private var refreshEnabled: Bool { visible && scenePhase == .active && api.accessAllowed }
    private var grades: [String] {
        Array(Set((store.snapshot?.students ?? []).filter { $0.state == "active" }.compactMap(\.grade).filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink("Events, feedback & notifications") { MobileHubView(api: api) }
                        Picker("Filter", selection: $filter) {
                            ForEach(StudentsFilter.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.menu)
                        if filter == .grade {
                            Picker("Grade", selection: $selectedGrade) {
                                Text("All grades").tag("")
                                ForEach(grades, id: \.self) { Text("Grade \($0)").tag($0) }
                            }.pickerStyle(.menu)
                        }
                        SnapshotStamp(date: store.snapshot?.receivedAt, failed: store.error != nil)
                    }
                }
                if let error = store.error {
                    Panel {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.orange)
                            if store.snapshot != nil {
                                Text("Showing the last successful list.").font(.caption).foregroundStyle(.secondary)
                            }
                            NavigationLink("Students connection settings") { StudentsSettingsView(api: api) }
                                .font(.subheadline)
                        }
                    }
                }
                if let actionError = store.actionError {
                    Label(actionError, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                }
                if let notice = store.actionNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if store.loading && store.snapshot == nil {
                    ProgressView("Loading students…").frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if let snapshot = store.snapshot {
                    // This only redraws the local clock; network refresh lives below.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        LazyVStack(alignment: .leading, spacing: 12) {
                            studentList(snapshot, at: ContinuousClock.now)
                        }
                    }
                }
            }.padding(16)
        }
        .background(Brand.background)
        .navigationTitle("Students").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search name or phone")
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

    @ViewBuilder private func studentList(_ snapshot: StudentsSnapshot, at now: ContinuousClock.Instant) -> some View {
        let rows = filtered(snapshot, at: now)
        if rows.isEmpty {
            ContentUnavailableView(snapshot.students.isEmpty ? "No students yet" : "No matching students",
                                   systemImage: "person.3",
                                   description: Text(snapshot.students.isEmpty ? "Students will appear when the server reports them." : "Try another search or filter."))
                .frame(maxWidth: .infinity).padding(.vertical, 20)
        } else {
            Text("\(rows.count) students").font(.caption).foregroundStyle(.secondary)
            ForEach(rows) { student in
                NavigationLink {
                    StudentDetailView(api: api, store: store, phone: student.phone)
                } label: {
                    Panel {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Text(student.displayName).font(.headline).foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                StudentWindowStatus(snapshot: snapshot, student: student, now: now)
                            }
                            HStack {
                                Text(student.state == "active" ? student.gradeLabel : student.stateLabel)
                                Spacer(minLength: 8)
                                Text(student.maskedPhone).monospacedDigit()
                            }.font(.caption).foregroundStyle(.secondary)
                            StudentActivityBadge(status: student.activityStatus)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.buttonStyle(.plain)
            }
        }
    }

    private func filtered(_ snapshot: StudentsSnapshot, at now: ContinuousClock.Instant) -> [Student] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // Filtering preserves the most-recent-first order returned by the API.
        return snapshot.students.filter { student in
            let matchesSearch = query.isEmpty || (student.name?.localizedCaseInsensitiveContains(query) ?? false) || student.phone.contains(query)
            guard matchesSearch else { return false }
            switch filter {
            case .all: return true
            case .open: return snapshot.isWindowOpen(for: student, at: now)
            case .closed: return !snapshot.isWindowOpen(for: student, at: now)
            case .grade: return student.state == "active" && (selectedGrade.isEmpty || student.grade == selectedGrade)
            }
        }
    }
}

private struct StudentWindowStatus: View {
    let snapshot: StudentsSnapshot
    let student: Student
    let now: ContinuousClock.Instant
    private var open: Bool { snapshot.isWindowOpen(for: student, at: now) }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(open ? Color.green : Color.gray).frame(width: 7, height: 7)
            Text(open ? snapshot.countdown(for: student, at: now) : "Closed")
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
        }.navigationTitle("Student Details").navigationBarTitleDisplayMode(.inline)
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
    private var color: Color {
        switch status {
        case .allowed: return .green
        case .suspended: return .orange
        case .blocked: return .red
        case .unknown: return .gray
        }
    }
    var body: some View {
        Text("Activity: \(status.title)").font(.caption.weight(.medium))
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel("Bot reply activity: \(status.title)")
    }
}


