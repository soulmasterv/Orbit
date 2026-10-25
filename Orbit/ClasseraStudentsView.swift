import SwiftUI

struct StudentDatabasesView: View {
    @ObservedObject var api: ServerAPI
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Student databases").font(.largeTitle.bold())
                Text("Two separate student systems. Changes stay with the selected bot.").foregroundStyle(.secondary)
                NavigationLink { StudentsView(api: api) } label: {
                    databaseCard("School assistant", "Onboarding, subjects and messaging windows", "person.text.rectangle")
                }
                NavigationLink { ClasseraStudentsView(api: api) } label: {
                    databaseCard("Classera subscribers", "Classera 1 (F) · Classera 2 (E)", "graduationcap")
                }
            }.padding(20)
        }.background(Brand.background).navigationTitle("Students").navigationBarTitleDisplayMode(.inline)
    }
    private func databaseCard(_ title: String, _ subtitle: String, _ symbol: String) -> some View {
        Panel {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(.vertical, 8)
        }
    }
}

struct ClasseraStudentsView: View {
    @ObservedObject var api: ServerAPI
    @Environment(\.scenePhase) private var phase
    @State private var students: [ClasseraStudent] = []
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false
    @State private var generation = 0
    @State private var add = false
    @State private var phone = ""
    @State private var newPhone: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("Subscriptions shared with WhatsApp signups. Saving here does not send a message.")
                    .font(.caption).foregroundStyle(.secondary)
                if loading { ProgressView("Loading subscribers…") }
                if let error { Text(error).foregroundStyle(.orange); Button("Retry") { Task { await refresh() } } }
                ForEach(students.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.phone.contains(search) }) { student in
                    NavigationLink { ClasseraStudentEditor(api: api, phone: student.phone) } label: {
                        Panel {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(student.displayName).font(.headline); Spacer(); Text(student.maskedPhone).font(.caption).monospacedDigit() }
                                ForEach(student.subscriptions) { row in
                                    Text("\(ClasseraClass.title(row.className)) · \(row.status == "active" ? "Active" : row.status.replacingOccurrences(of: "_", with: " ")) · AI \(row.aiEnabled.map { $0 == 1 ? "on" : "off" } ?? "not set")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if student.signupSession != nil { Text("WhatsApp signup in progress").font(.caption).foregroundStyle(.orange) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.buttonStyle(.plain)
                }
                if !loading && error == nil && students.isEmpty {
                    ContentUnavailableView("No Classera subscribers", systemImage: "person.2", description: Text("WhatsApp signups and subscriptions added here will appear together."))
                }
            }.padding(16)
        }.background(Brand.background).navigationTitle("Classera subscribers").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Name or phone")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Add", systemImage: "plus") { phone = ""; add = true } } }
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
    @State private var removeClass: String?
    private var canSave: Bool { loaded && !busy && api.accessAllowed && student?.signupSession == nil }
    var body: some View {
        Form {
            Section("Classera subscriber") {
                Text(phone).textSelection(.enabled)
                Text("This edits only Classera subscriptions. The school assistant database is separate.").font(.caption).foregroundStyle(.secondary)
            }
            if busy { ProgressView("Please wait…") }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
            if student?.signupSession != nil {
                Section { Text("WhatsApp signup is in progress. Finish it there, then reload before editing.").foregroundStyle(.orange) }
            }
            ForEach($rows) { $row in
                Section(ClasseraClass.title(row.className)) {
                    if row.editable {
                        TextField("Student name", text: $row.name)
                        Picker("AI preference", selection: $row.aiEnabled) {
                            Text("Not set").tag(nil as Int?); Text("Enabled").tag(1 as Int?); Text("Disabled").tag(0 as Int?)
                        }.disabled(row.status == "waiting_for_class")
                        Picker("Subscription", selection: $row.status) {
                            Text("Active").tag("active"); Text("Waiting for class").tag("waiting_for_class")
                        }.onChange(of: row.status) { _, status in
                            if status == "waiting_for_class" { row.aiEnabled = nil }
                        }
                        Button("Remove this class", role: .destructive) { removeClass = row.className }
                    } else {
                        Text("Legacy class preserved: \(row.name)")
                        Text("This class cannot be changed here.").font(.caption)
                    }
                }.disabled(!canSave)
            }
            Section("Add subscription") {
                ForEach(["12F", "12E"].filter { klass in !rows.contains { $0.className == klass } }, id: \.self) { klass in
                    Button("Add \(ClasseraClass.title(klass))") {
                        rows.append(ClasseraSubscription(className: klass, name: rows.first?.name ?? student?.signupSession?.name ?? "", aiEnabled: nil, status: "active"))
                    }.disabled(!canSave)
                }
            }
            Section {
                Button("Save changes") { confirmSave = true }.disabled(!canSave)
                Button("Reload from server") { Task { await reload() } }.disabled(busy || !api.accessAllowed)
                Text("Saving updates report eligibility for future scheduled reports. It does not send WhatsApp messages. Unselected legacy classes remain preserved.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Classera student").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .task(id: phase == .active && api.accessAllowed) {
            guard phase == .active && api.accessAllowed else { generation += 1; loaded = false; busy = false; student = nil; rows = []; return }
            await reload()
        }
        .onDisappear { generation += 1; loaded = false }
        .confirmationDialog("Save Classera subscriptions?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save") { Task { await save() } }; Button("Cancel", role: .cancel) {}
        } message: { Text("This includes any class removals. Authorize on your iPhone next. No message is sent now.") }
        .confirmationDialog("Remove this subscription?", isPresented: Binding(get: { removeClass != nil }, set: { if !$0 { removeClass = nil } }), titleVisibility: .visible) {
            Button("Remove class", role: .destructive) { rows.removeAll { $0.className == removeClass }; removeClass = nil }
            Button("Cancel", role: .cancel) { removeClass = nil }
        } message: { Text("The change takes effect only after Save. Other classes and the other student database remain unchanged.") }
    }
    private func reload() async {
        guard !busy && api.accessAllowed else { return }
        generation += 1; let epoch = generation; busy = true; loaded = false
        defer { if epoch == generation { busy = false } }
        do {
            let result = try await api.loadClasseraStudent(phone: phone)
            guard epoch == generation && api.accessAllowed && !Task.isCancelled else { return }
            student = result; rows = result.subscriptions; loaded = true; message = nil
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
            self.student = result; rows = result.subscriptions; message = "Saved. No WhatsApp message was sent."
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
}

enum ClasseraPhone {
    static func valid(_ value: String) -> Bool {
        (8...15).contains(value.count) && value.first != "0" && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}
