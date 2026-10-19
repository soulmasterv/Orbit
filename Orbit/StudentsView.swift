import SwiftUI

struct StudentsView: View {
    @ObservedObject var api: ServerAPI
    @StateObject private var store: StudentsStore
    @EnvironmentObject private var mobile: MobileStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var search = ""
    @State private var filter: StudentsFilter = .all
    @State private var selectedGrade = ""
    @State private var refreshOwner = UUID()

    init(api: ServerAPI, store: StudentsStore? = nil) {
        self.api = api
        _store = StateObject(wrappedValue: store ?? StudentsStore(api: api))
    }

    private var refreshEnabled: Bool { visible && scenePhase == .active && api.accessAllowed }
    private var grades: [String] {
        StudentsDirectory.grades(in: store.snapshot?.students ?? [])
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                directoryHeader
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
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .background(Brand.background)
        .navigationTitle("Students").navigationBarTitleDisplayMode(.inline)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your students").font(.title2.bold())
                    Text("Profiles, reply access and messaging windows").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                NavigationLink { MobileHubView(api: api) } label: {
                    Image(systemName: "slider.horizontal.3").font(.headline)
                        .frame(width: 44, height: 44).background(Brand.accent.opacity(0.12), in: Circle())
                }.accessibilityLabel("Student tools and connection settings")
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name or phone", text: $search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("students.search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("Clear search")
                }
            }.padding(12).background(Brand.surface, in: RoundedRectangle(cornerRadius: 12))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StudentsFilter.allCases) { item in
                        Button { filter = item } label: {
                            Text(item == .open ? "Open" : item == .closed ? "Closed" : item.rawValue)
                                .font(.subheadline.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 10)
                                .foregroundStyle(filter == item ? Color.white : Color.primary)
                                .background(filter == item ? Brand.accent : Brand.surface, in: Capsule())
                        }.buttonStyle(.plain)
                         .accessibilityLabel(item.rawValue)
                         .accessibilityAddTraits(filter == item ? .isSelected : [])
                    }
                }
            }
            if filter == .grade {
                Menu {
                    Button("All grades") { selectedGrade = "" }
                    ForEach(grades, id: \.self) { grade in Button("Grade \(grade)") { selectedGrade = grade } }
                } label: {
                    HStack {
                        Label(selectedGrade.isEmpty ? "All grades" : "Grade \(selectedGrade)", systemImage: "graduationcap")
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }.font(.subheadline).padding(12).background(Brand.surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { feedbackLink; eventsLink }
                VStack(alignment: .leading, spacing: 10) { feedbackLink; eventsLink }
            }
            if mobile.state?.outbox != nil {
                NavigationLink { MessageOutboxView() } label: { Label("Review saved message", systemImage: "tray") }
                    .font(.subheadline.weight(.medium))
            }
            SnapshotStamp(date: store.snapshot?.receivedAt, failed: store.error != nil)
        }.frame(maxWidth: .infinity, alignment: .leading)
         .accessibilityIdentifier("students.header")
    }

    private var feedbackLink: some View {
        NavigationLink { MobileFeedbackView(api: api, selectedID: nil) } label: {
            Label("Feedback", systemImage: "bubble.left.and.text.bubble.right").font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity).padding(12).background(Brand.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private var eventsLink: some View {
        NavigationLink { MobileEventsView(api: api) } label: {
            Label("Recent events", systemImage: "clock").font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity).padding(12).background(Brand.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func directory(_ snapshot: StudentsSnapshot, at now: ContinuousClock.Instant) -> some View {
        let rows = StudentsDirectory.filtered(snapshot, search: search, filter: filter, grade: selectedGrade, at: now)
        let open = snapshot.students.filter { snapshot.isWindowOpen(for: $0, at: now) }.count
        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { resultCount(rows.count, total: snapshot.students.count); Spacer(); Text("\(open) window open").font(.caption).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 4) { resultCount(rows.count, total: snapshot.students.count); Text("\(open) window open").font(.caption).foregroundStyle(.secondary) }
            }
            if rows.isEmpty {
                ContentUnavailableView(snapshot.students.isEmpty ? "No students yet" : "No matching students",
                    systemImage: "person.3",
                    description: Text(snapshot.students.isEmpty ? "Profiles appear after students contact the bot." : "Try another search, window filter or grade."))
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            ForEach(rows) { student in
                NavigationLink { StudentDetailView(api: api, store: store, phone: student.phone) } label: {
                    StudentDirectoryCard(snapshot: snapshot, student: student, now: now)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.fill").font(.title3)
                    .foregroundStyle(Brand.accent).frame(width: 42, height: 42)
                    .background(Brand.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(student.displayName).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    Text(student.state == "active" ? student.gradeLabel : student.stateLabel).font(.subheadline).foregroundStyle(.secondary)
                    Text(student.maskedPhone).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 4)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { StudentActivityBadge(status: student.activityStatus); Spacer(minLength: 10); StudentWindowStatus(snapshot: snapshot, student: student, now: now) }
                VStack(alignment: .leading, spacing: 10) { StudentActivityBadge(status: student.activityStatus); StudentWindowStatus(snapshot: snapshot, student: student, now: now) }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
         .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18))
         .accessibilityElement(children: .combine)
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
        Text("Replies: \(status.title)").font(.caption.weight(.medium))
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel("Bot reply activity: \(status.title)")
    }
}




