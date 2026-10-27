import SwiftUI

struct StudentDatabasesView: View {
    @ObservedObject var api: ServerAPI
    var onWorkspace: (() -> Void)? = nil
    @State private var classeraSelected = true
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                Text("Students").font(.largeTitle.bold()).foregroundStyle(.white)
                HStack(spacing: 0) {
                    databaseTab("School assistant", selected: !classeraSelected) { classeraSelected = false }
                    databaseTab("Classera", selected: classeraSelected) { classeraSelected = true }
                }.padding(3).background(StudentPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            }.padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 14)
            if classeraSelected { ClasseraStudentsView(api: api, embedded: true) }
            else { StudentsView(api: api, embedded: true) }
        }
        .modifier(StudentAppearance())
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Label("Students", systemImage: "person.2.fill")
                    .foregroundStyle(StudentPalette.accent).frame(maxWidth: .infinity)
                Button {
                    if let onWorkspace { onWorkspace() } else { dismiss() }
                } label: {
                    Label("Workspace", systemImage: "square.grid.2x2").frame(maxWidth: .infinity)
                }.foregroundStyle(StudentPalette.secondary)
            }.font(.caption.weight(.medium)).padding(.vertical, 14)
                .background(.black).overlay(alignment: .top) { Divider().overlay(StudentPalette.border) }
        }
    }
    private func databaseTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(selected ? StudentPalette.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ClasseraStudentsView: View {
    @ObservedObject var api: ServerAPI
    var embedded = false
    @Environment(\.scenePhase) private var phase
    @State private var students: [ClasseraStudent] = []
    @State private var search = ""
    @State private var activity: StudentActivityStatus?
    @State private var error: String?
    @State private var loading = false
    @State private var generation = 0
    @State private var add = false
    @State private var phone = ""
    @State private var newPhone: String?
    private var filtered: [ClasseraStudent] {
        students.filter { student in
            student.activityStatus.matches(activity) &&
            (search.isEmpty || student.displayName.localizedCaseInsensitiveContains(search) || student.phone.contains(search))
        }
    }
    private var classCount: Int { Set(students.flatMap(\.subscriptions).filter(\.editable).map(\.className)).count }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    StudentSearchField(text: $search)
                    HStack {
                        Text("\(students.count) subscribers")
                        Spacer()
                        Text("\(classCount) classes")
                    }.font(.caption).foregroundStyle(StudentPalette.secondary)
                    StudentAccessFilters(selection: $activity)
                    if loading { ProgressView("Refreshing…").font(.caption) }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                        Button("Retry") { Task { await refresh() } }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 14)
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, student in
                    NavigationLink { ClasseraStudentEditor(api: api, phone: student.phone) } label: {
                        StudentCompactRow(name: student.displayName, phone: student.phone,
                            chips: student.subscriptions.map { row in
                                let label = row.className == "12F" ? "1 (F)" : row.className == "12E" ? "2 (E)" : row.className
                                return row.status == "active" ? label : "\(label) · Waiting"
                            }, status: student.activityStatus,
                            note: student.signupSession == nil ? nil : "Sign up in progress",
                            noteColor: .yellow,
                            alternate: !index.isMultiple(of: 2))
                    }.buttonStyle(.plain)
                }
                if !loading && error == nil && filtered.isEmpty {
                    ContentUnavailableView(students.isEmpty ? "No Classera subscribers" : "No matching students",
                        systemImage: "person.2",
                        description: Text(students.isEmpty ? "New WhatsApp signups appear here." : "Try a different name, phone or activity filter."))
                }
            }.padding(.bottom, 12)
        }.modifier(StudentAppearance())
        .navigationTitle(embedded ? "Orbit" : "Classera subscribers").navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { ClasseraMonitoringView(api: api) } label: { Label("Monitoring", systemImage: "chart.bar.xaxis") }
            }
            ToolbarItem(placement: .topBarTrailing) {
            Button { phone = ""; add = true } label: {
                Label("Add", systemImage: "plus").font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 7)
                    .background(StudentPalette.accent, in: RoundedRectangle(cornerRadius: 8))
            }.accessibilityLabel("Add Classera subscriber")
        } }
        .alert("Add subscriber", isPresented: $add) {
            TextField("International phone, digits only", text: $phone).keyboardType(.phonePad)
            Button("Continue") {
                if ClasseraPhone.valid(phone) { newPhone = phone } else { error = "Use 8–15 international digits, without + or spaces." }
            }
            Button("Cancel", role: .cancel) {}
        }
        .navigationDestination(isPresented: Binding(get: { newPhone != nil }, set: { if !$0 { newPhone = nil } })) {
            if let newPhone { ClasseraStudentEditor(api: api, phone: newPhone) }
        }
        .task(id: phase == .active && api.accessAllowed) {
            guard phase == .active && api.accessAllowed else { generation += 1; students = []; loading = false; return }
            await refresh()
        }
        .onDisappear { generation += 1; loading = false }
        .refreshable { await refresh() }
    }
    private func refresh() async {
        guard api.accessAllowed && phase == .active && !loading else { return }
        generation += 1; let epoch = generation; loading = true
        do {
            let result = try await api.loadClasseraDirectory()
            guard epoch == generation && api.accessAllowed && !Task.isCancelled else { return }
            students = result; error = nil
        } catch { if epoch == generation && !ServerAPI.isRefreshCancellation(error) { self.error = error.localizedDescription } }
        if epoch == generation { loading = false }
    }
}

struct ClasseraStudentEditor: View {
    @ObservedObject var api: ServerAPI
    let phone: String
    @Environment(\.scenePhase) private var phase
    @State private var student: ClasseraStudent?
    @State private var rows: [ClasseraSubscription] = []
    @State private var busy = false
    @State private var loaded = false
    @State private var generation = 0
    @State private var message: String?
    @State private var confirmSave = false
    @State private var editName = false
    @State private var nameDraft = ""
    @State private var nameError: String?
    @State private var removeClass: String?
    @State private var pendingAction: StudentManagementAction?
    @State private var reportClass: String?
    @State private var expandedClasses: Set<String> = []
    @State private var windowInstant = ContinuousClock.now
    @Environment(\.dismiss) private var dismiss
    private var canSave: Bool { loaded && !busy && api.accessAllowed && student?.signupSession == nil }
    private var hasChanges: Bool { loaded && (student.map { rows != $0.subscriptions } ?? false) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                profileSection
                if busy { ProgressView("Please wait…").font(.caption) }
                if let message {
                    Text(message).font(.subheadline).foregroundStyle(StudentPalette.secondary)
                        .accessibilityIdentifier("classera.student.notice")
                }
                if student?.signupSession != nil {
                    Text("Sign up in progress. Finish on WhatsApp, then reload before editing.")
                        .font(.subheadline).foregroundStyle(.yellow)
                }
                subscriptionsSection
                messagingSection
                managementSection
                Button { Task { await reload() } } label: {
                    Label("Reload from server", systemImage: "arrow.clockwise")
                }.disabled(busy || !api.accessAllowed)
                Text("Classera subscriptions only. The school assistant database has separate data and controls.")
                    .font(.caption).foregroundStyle(StudentPalette.secondary)
            }.padding(16)
        }.modifier(StudentAppearance())
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Student details").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                Button { confirmSave = true } label: {
                    Text("Save changes").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .foregroundStyle(canSave && hasChanges ? .white : StudentPalette.secondary)
                        .background(canSave && hasChanges ? StudentPalette.accent : StudentPalette.surface,
                                    in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(!canSave || !hasChanges)
                    .accessibilityIdentifier("classera.student.save")
                if hasChanges {
                    Text("Unsaved changes · Saving does not send a message")
                        .font(.caption2).foregroundStyle(StudentPalette.secondary)
                }
            }.padding(.horizontal, 16).padding(.vertical, 10).background(.black)
                .overlay(alignment: .top) { Divider().overlay(StudentPalette.border) }
        }
        .sheet(isPresented: $editName) {
            NavigationStack {
                Form {
                    Section("Student name") {
                        TextField("Name", text: $nameDraft).textContentType(.name)
                            .accessibilityIdentifier("classera.editName")
                        if let nameError { Text(nameError).foregroundStyle(.yellow) }
                    }
                    Text("Applies to this student's Classera 1 (F) and Classera 2 (E) subscriptions. Legacy class names stay unchanged. Tap Save changes on the student page to authorize and save. No WhatsApp message is sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }.scrollContentBackground(.hidden).modifier(StudentAppearance())
                    .navigationTitle("Edit name").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editName = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Apply name") {
                                guard canSave else { editName = false; return }
                                do {
                                    rows = try ClasseraNameEdit.applying(nameDraft, to: rows)
                                    message = "Name updated in your draft. Tap Save changes to save it securely."
                                    editName = false
                                } catch { nameError = error.localizedDescription }
                            }.disabled(!canSave)
                        }
                    }
            }
        }
        .task(id: phase == .active && api.accessAllowed) {
            guard phase == .active && api.accessAllowed else {
                if phase == .background || !api.accessAllowed { generation += 1; loaded = false; busy = false; student = nil; rows = []; editName = false; nameDraft = "" }
                return
            }
            // Face ID can briefly make the scene inactive. Keep drafts and the
            // pending operation; only backgrounding/locking invalidates them.
            if !loaded && !busy { await reload() }
        }
        .onDisappear { generation += 1; loaded = false }
        .confirmationDialog("Save Classera subscriptions?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save") { Task { await save() } }; Button("Cancel", role: .cancel) {}
        } message: { Text("This includes any class removals. Authorize on your iPhone next. No message is sent now.") }
        .confirmationDialog("Remove this subscription?", isPresented: Binding(get: { removeClass != nil }, set: { if !$0 { removeClass = nil } }), titleVisibility: .visible) {
            Button("Remove class", role: .destructive) { rows.removeAll { $0.className == removeClass }; removeClass = nil }
            Button("Cancel", role: .cancel) { removeClass = nil }
        } message: { Text("The change takes effect only after Save. Other classes and the other student database remain unchanged.") }
        .confirmationDialog(pendingAction.map { "\($0.title)?" } ?? "Confirm action", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible, presenting: pendingAction) { action in
            Button(action.title, role: action == .block || action == .remove ? .destructive : nil) { Task { await manage(action) } }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action == .remove ? "Delete all Classera subscriptions and signup progress for this phone. Messaging Classera again starts onboarding. The other student database is untouched." : "Update Classera replies and daily-report eligibility. Authorize on your iPhone next.")
        }
        .confirmationDialog("Force-send to ONE PERSON ONLY?", isPresented: Binding(get: { reportClass != nil }, set: { if !$0 { reportClass = nil } }), titleVisibility: .visible, presenting: reportClass) { klass in
            Button("Force-send report", role: .destructive) { Task { await sendReport(klass) } }
            Button("Cancel", role: .cancel) {}
        } message: { klass in Text("Send \(ClasseraClass.title(klass)) to \(phone) only. This can resend an already delivered daily report.") }
    }
    private var profileSection: some View {
        detailGroup("Profile") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(rows.first?.name ?? student?.displayName ?? "Student")
                        .font(.title3.bold()).foregroundStyle(.white)
                    Text(phone).font(.subheadline).monospacedDigit().textSelection(.enabled)
                        .foregroundStyle(StudentPalette.secondary)
                        .accessibilityIdentifier("classera.student.fullPhone")
                }
                Spacer(minLength: 8)
                Button("Edit name") {
                    nameDraft = rows.first(where: \.editable)?.name ?? ""
                    nameError = nil; editName = true
                }.font(.subheadline).disabled(!canSave || !rows.contains(where: \.editable))
            }
            Divider()
            HStack {
                Text("Activity").foregroundStyle(StudentPalette.secondary)
                Spacer()
                StudentStatusPill(status: student?.activityStatus ?? .unknown)
            }
            Divider()
            LabeledContent("Source", value: "Classera")
            Divider()
            windowStatus
        }
    }
    private var windowStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WhatsApp 24-hour window").font(.subheadline.weight(.medium))
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                if let windows = student?.whatsappWindows, !windows.isEmpty {
                    ForEach(windows) { window in
                        let remaining = window.remainingSeconds(since: windowInstant)
                        HStack(alignment: .top) {
                            Text(ClasseraClass.title(window.className)).foregroundStyle(StudentPalette.secondary)
                            Spacer()
                            HStack(spacing: 6) {
                                Circle().fill(remaining == nil ? Color.gray : remaining! > 0 ? Color.green : Color.gray)
                                    .frame(width: 6, height: 6)
                                Text(window.label(since: windowInstant)).monospacedDigit()
                            }
                        }.font(.caption)
                    }
                } else {
                    Label("Unavailable — not reported by Classera", systemImage: "clock")
                        .font(.caption).foregroundStyle(StudentPalette.secondary)
                }
            }
            Text("The window follows the student's last message to that WhatsApp number. It is separate from activity and subscription status.")
                .font(.caption2).foregroundStyle(StudentPalette.secondary)
        }.accessibilityIdentifier("classera.student.whatsappWindow")
    }
    private var subscriptionsSection: some View {
        detailGroup("Subscriptions") {
            if rows.isEmpty {
                Text("No subscriptions").foregroundStyle(StudentPalette.secondary)
            }
            ForEach($rows) { $row in
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedClasses.contains(row.className) },
                    set: { if $0 { expandedClasses.insert(row.className) } else { expandedClasses.remove(row.className) } }
                )) {
                    VStack(alignment: .leading, spacing: 12) {
                        if row.editable {
                            TextField("Student name", text: $row.name).textContentType(.name)
                                .textFieldStyle(.plain).padding(10)
                                .background(StudentPalette.alternate, in: RoundedRectangle(cornerRadius: 8))
                            Picker("AI preference", selection: $row.aiEnabled) {
                                Text("Not set").tag(nil as Int?)
                                Text("Enabled").tag(1 as Int?)
                                Text("Disabled").tag(0 as Int?)
                            }.disabled(row.status == "waiting_for_class")
                            Picker("Subscription", selection: $row.status) {
                                Text("Active").tag("active")
                                Text("Waiting for class").tag("waiting_for_class")
                            }.onChange(of: row.status) { _, status in
                                if status == "waiting_for_class" { row.aiEnabled = nil }
                            }
                            Button("Remove this class", role: .destructive) { removeClass = row.className }
                        } else {
                            Text("Legacy subscription preserved. This class cannot be edited here.")
                                .font(.caption).foregroundStyle(StudentPalette.secondary)
                        }
                    }.padding(.top, 10).disabled(!canSave)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(ClasseraClass.title(row.className)).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        HStack(spacing: 8) {
                            Text(row.status == "active" ? "Active" : "Waiting for class")
                                .foregroundStyle(row.status == "active" ? StudentPalette.secondary : .yellow)
                            Text("·")
                            Text("AI: " + ClasseraSubscriptionSummary.aiLabel(row))
                        }.font(.caption).foregroundStyle(StudentPalette.secondary)
                    }.padding(.vertical, 3)
                }
                Divider()
            }
            ForEach(["12F", "12E"].filter { klass in !rows.contains { $0.className == klass } }, id: \.self) { klass in
                Button {
                    rows.append(ClasseraSubscription(className: klass, name: rows.first?.name ?? student?.signupSession?.name ?? "",
                                                     aiEnabled: nil, status: "active"))
                    expandedClasses.insert(klass)
                } label: { Label("Add " + ClasseraClass.title(klass), systemImage: "plus.circle") }
                    .disabled(!canSave)
            }
            if student?.hasPendingClass == true {
                NavigationLink { ClasseraMonitoringView(api: api) } label: {
                    Label("Waiting list and invitation preview", systemImage: "person.badge.clock")
                }
                Text("Class-wide sending remains disabled until the approved template is verified.")
                    .font(.caption2).foregroundStyle(StudentPalette.secondary)
            }
        }
    }
    private var messagingSection: some View {
        detailGroup("Messaging") {
            NavigationLink { ClasseraMonitoringView(api: api, initialTab: 1, initialSearch: phone) } label: {
                detailAction("Delivery history", icon: "doc.text")
            }.disabled(!loaded || busy)
            Divider()
            Menu {
                ForEach(rows.filter { $0.editable && $0.status == "active" }) { row in
                    Button("Force-send " + ClasseraClass.title(row.className)) { reportClass = row.className }
                }
            } label: { detailAction("Send daily report to this person", icon: "paperplane") }
                .disabled(!loaded || busy || student?.activityStatus != .allowed || !api.canControl ||
                          !rows.contains { $0.editable && $0.status == "active" })
                .accessibilityIdentifier("classera.student.sendReport")
            Text("One person only. Can resend a delivered report. Confirmation and device authorization are required.")
                .font(.caption2).foregroundStyle(StudentPalette.secondary)
            Button("Refresh report availability") { Task { await api.refreshAll() } }
                .font(.caption).disabled(busy || api.loading || api.servicesLoading)
        }
    }
    private var managementSection: some View {
        detailGroup("Management") {
            if let student {
                ForEach(managementActions(student.activityStatus)) { action in
                    Button(role: action == .remove ? .destructive : nil) { pendingAction = action } label: {
                        HStack {
                            Image(systemName: action == .remove ? "trash" : action == .resume ? "play.circle" : "pause.circle")
                                .frame(width: 20)
                            Text(action == .suspend ? "Suspend replies & reports" : action.title)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.padding(.vertical, 5)
                    }.disabled(!loaded || busy || !api.accessAllowed || student.activityStatus == .unknown)
                    if action != .remove { Divider() }
                }
                Text("Suspend pauses replies and daily reports until Resume. Subscriptions stay saved. Messages already sent to WhatsApp cannot be recalled.")
                    .font(.caption2).foregroundStyle(StudentPalette.secondary)
            } else {
                Text("Load student details to manage access.").foregroundStyle(StudentPalette.secondary)
            }
        }
    }
    private func detailAction(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(StudentPalette.accent).frame(width: 20)
            Text(title).foregroundStyle(.white)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(StudentPalette.secondary)
        }.padding(.vertical, 6)
    }
    private func detailGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.medium)).foregroundStyle(StudentPalette.secondary)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 12, content: content)
                .font(.subheadline).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(StudentPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private func reload() async {
        guard !busy && api.accessAllowed else { return }
        generation += 1; let epoch = generation; busy = true; loaded = false
        defer { if epoch == generation { busy = false } }
        do {
            let result = try await api.loadClasseraStudent(phone: phone)
            guard epoch == generation && api.accessAllowed && !Task.isCancelled else { return }
            student = result; rows = result.subscriptions; windowInstant = .now; loaded = true; message = nil
        } catch { if epoch == generation && !ServerAPI.isRefreshCancellation(error) { message = error.localizedDescription } }
    }
    private func save() async {
        guard canSave, let student else { return }
        let payload: ClasseraStudentEdit
        do { payload = try ClasseraStudentEdit(student: student, rows: rows) }
        catch { message = error.localizedDescription; return }
        generation += 1; let epoch = generation; busy = true
        do {
            let result = try await api.saveClasseraStudent(phone: phone, payload: payload)
            guard epoch == generation && api.accessAllowed else { return }
            self.student = result; rows = result.subscriptions; windowInstant = .now; message = "Saved. No WhatsApp message was sent."
        } catch {
            guard epoch == generation else { return }
            busy = false; loaded = false
            // One read verifies an uncertain write; never retry the PUT.
            if error is ClasseraDirectoryFailure {
                await reload()
                message = error as? ClasseraDirectoryFailure == .conflict
                    ? "The database changed or signup is in progress. Review the latest values before saving again."
                    : "The save may have succeeded. Latest values were requested; review them before another attempt."
            } else { message = error.localizedDescription }
        }
        if epoch == generation { busy = false }
    }
    private func managementActions(_ status: StudentActivityStatus) -> [StudentManagementAction] {
        StudentManagementAction.available(for: status)
    }
    private func manage(_ action: StudentManagementAction) async {
        guard loaded, !busy, let student, action.isValid(for: student.activityStatus) else { return }
        generation += 1; let epoch = generation; busy = true
        do {
            let result = try await api.manageClasseraStudent(student: student, action: action)
            guard epoch == generation && api.accessAllowed else { return }
            if action == .remove { dismiss() }
            else if let result { self.student = result; rows = result.subscriptions; message = "Updated. No message was sent." }
        } catch {
            guard epoch == generation else { return }
            busy = false; loaded = false
            if error is ClasseraDirectoryFailure {
                await reload(); message = "The action may have completed or the database changed. Review the refreshed state before trying again."
            } else { message = error.localizedDescription }
        }
        if epoch == generation { busy = false }
    }
    private func sendReport(_ klass: String) async {
        guard !busy, loaded, student?.activityStatus == .allowed else { return }
        busy = true
        defer { busy = false }
        let id = klass == "12F" ? "classera-1" : "classera-2"
        do {
            let recipients = try await api.loadClasseraRecipients(id: id)
            guard recipients.contains(phone), api.accessAllowed, phase == .active, !Task.isCancelled else {
                message = "This phone is no longer an active, allowed recipient for this class. Reload before sending."; return
            }
            await api.serviceAction(ServiceCommand(kind: .forceOneClasseraReport, id: id, name: ClasseraClass.title(klass), recipient: phone))
            message = api.actionError ?? api.actionNotice
        } catch { message = "Could not verify the current recipient. No report was requested." }
    }
}

enum ClasseraPhone {
    static func valid(_ value: String) -> Bool {
        (8...15).contains(value.count) && value.first != "0" && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}



