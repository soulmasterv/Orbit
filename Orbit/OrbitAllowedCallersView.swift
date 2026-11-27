import SwiftUI

private struct OrbitAllowedCallerRow: View {
    let caller: OrbitAllowedCaller
    let overridden: Bool
    var body: some View {
        HStack(spacing: 12) {
            Text(String(caller.displayName.prefix(1)).uppercased())
                .font(.title3.weight(.semibold)).foregroundStyle(.blue)
                .frame(width: 42, height: 42).background(Color.blue.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(caller.displayName).font(.headline)
                Text(caller.number).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    Circle().fill(caller.enabled ? Color.green : Color.gray).frame(width: 6, height: 6)
                    Text(caller.enabled ? "Enabled" : "Disabled")
                    Text("·")
                    Text(overridden ? "Temporarily overridden" : OrbitIncomingMode.title(caller.currentMode))
                }.font(.caption).foregroundStyle(overridden ? Color.orange : Color.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 5)
    }
}

struct OrbitAllowedCallersView: View {
    @ObservedObject var api: ServerAPI
    @StateObject private var state = OrbitAllowedCallersState()
    @Environment(\.scenePhase) private var phase
    @State private var editor: OrbitCallerDraft?
    private var active: Bool { api.accessAllowed && phase != .background }
    private var canEdit: Bool { active && phase == .active && api.canControl && !state.busy && !state.needsRefresh && state.snapshot != nil }

    var body: some View {
        List {
            if active {
                OrbitIncomingOverrideCard(api: api, state: state)
                Section {
                    if state.busy { ProgressView("Updating callers…") }
                    if let error = state.error {
                        Text(error).foregroundStyle(.orange)
                        Button("Refresh") { Task { await reload() } }.disabled(state.busy)
                    }
                    if let snapshot = state.snapshot {
                        if snapshot.callers.isEmpty { Text("No allowed callers yet.").foregroundStyle(.secondary) }
                        ForEach(snapshot.callers) { caller in
                            NavigationLink {
                                callerDetail(caller.number)
                            } label: {
                                OrbitAllowedCallerRow(caller: caller, overridden: state.snapshot?.incomingOverride != nil)
                            }
                        }
                    }
                } header: { Text("Allowed callers") }
            }
        }
        .navigationTitle("Allowed Callers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = OrbitCallerDraft() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add caller").disabled(!canEdit)
            }
        }
        .sheet(item: $editor) { draft in
            OrbitAllowedCallerEditor(api: api, state: state, initial: draft)
        }
        .task(id: "\(api.latestReportsContext)|\(active)") {
            editor = nil; state.clear()
            if active { await reload() }
        }
        .refreshable { await reload() }
        .onChange(of: phase) { _, value in
            if value == .active { Task { await reload() } }
        }
        .task(id: "\(api.latestReportsContext)|\(phase == .active)|\(api.accessAllowed)") {
            guard api.accessAllowed, phase == .active else { return }
            while !Task.isCancelled, api.accessAllowed, phase == .active {
                let remaining = state.snapshot?.incomingOverride?.expires.timeIntervalSinceNow ?? 5
                let delay = remaining > 0 ? max(0.25, min(5, remaining + 0.1)) : 5
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled, api.accessAllowed, phase == .active else { return }
                if state.snapshot?.incomingOverride != nil { await reload() }
            }
        }
    }

    @ViewBuilder private func callerDetail(_ number: String) -> some View {
        if active, let caller = state.snapshot?.callers.first(where: { $0.number == number }) {
            OrbitAllowedCallerDetail(api: api, state: state, number: caller.number)
        } else {
            ContentUnavailableView("Caller unavailable", systemImage: "person.crop.circle.badge.questionmark")
        }
    }
    private func reload() async { guard active else { return }; await state.load { try await api.allowedCallers() } }
    static func cairoCallTime(_ timestamp: Double) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Africa/Cairo"); formatter.dateFormat = "d MMM h:mm a"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp)) + " Cairo"
    }
}

struct OrbitAllowedCallerDetail: View {
    @ObservedObject var api: ServerAPI
    @ObservedObject var state: OrbitAllowedCallersState
    let number: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var editor: OrbitCallerDraft?
    @State private var deleting = false
    private var caller: OrbitAllowedCaller? { state.snapshot?.callers.first { $0.number == number } }
    private var canEdit: Bool { api.canControl && phase == .active && !state.busy && !state.needsRefresh }

    var body: some View {
        Form {
            if api.accessAllowed, phase != .background, let caller {
                Section {
                    Text(caller.displayName).font(.headline)
                    Text(caller.number).foregroundStyle(.secondary)
                    LabeledContent("Status", value: caller.enabled ? "Enabled" : "Disabled")
                    if caller.isOwner { Text("Owner · Private AI access").foregroundStyle(.secondary) }
                }
                Section("Incoming mode") {
                    if let override = state.snapshot?.incomingOverride {
                        Text("Temporarily overridden by \(OrbitIncomingMode.title(override.mode)). These personal settings remain saved.")
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("Admin default", value: OrbitIncomingMode.title(caller.defaultMode))
                    LabeledContent("Caller selected", value: caller.selectedMode.map(OrbitIncomingMode.title) ?? "Using default")
                    LabeledContent(state.snapshot?.incomingOverride == nil ? "Current mode" : "Saved personal mode", value: OrbitIncomingMode.title(caller.currentMode))
                }
                Section("Assigned modes") {
                    ForEach(caller.displayModes, id: \.self) { Text(OrbitIncomingMode.title($0)) }
                }
                Section { NavigationLink("Calls") { ContactCallsView(api: api, phone: number) } }
                Section {
                    Button("Edit caller") { editor = OrbitCallerDraft(caller) }.disabled(!canEdit)
                    NavigationLink("Call history") { OrbitDiaaCallHistoryView(api: api, number: caller.number, name: caller.name) }
                    if !caller.isOwner {
                        Button("Delete caller", role: .destructive) { deleting = true }.disabled(!canEdit)
                    }
                }
                if let error = state.error {
                    Section { Text(error).foregroundStyle(.orange); Button("Refresh") { Task { await reload() } }.disabled(state.busy) }
                }
            }
        }
        .navigationTitle("Caller")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editor) { OrbitAllowedCallerEditor(api: api, state: state, initial: $0) }
        .confirmationDialog("Delete this caller?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete caller", role: .destructive) { Task { await remove() } }
        } message: { Text("This number will lose its allowed incoming modes.") }
        .onChange(of: api.latestReportsContext) { _, _ in editor = nil; deleting = false }
        .onChange(of: phase) { _, phase in if phase == .background { editor = nil; deleting = false } }
        .refreshable { await reload() }
    }
    private func reload() async { guard api.accessAllowed, phase == .active else { return }; await state.load { try await api.allowedCallers() } }
    private func remove() async {
        guard canEdit, let caller, !caller.isOwner else { return }
        if await state.apply({ try await api.changeAllowedCaller(OrbitCallerChange(action: "delete", number: number)) }) { dismiss() }
    }
}

struct OrbitAllowedCallerEditor: View {
    @ObservedObject var api: ServerAPI
    @ObservedObject var state: OrbitAllowedCallersState
    @State private var draft: OrbitCallerDraft
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    init(api: ServerAPI, state: OrbitAllowedCallersState, initial: OrbitCallerDraft) {
        self.api = api; self.state = state; _draft = State(initialValue: initial)
    }
    private var available: [String] { OrbitIncomingMode.allCases.map(\.rawValue).filter { Set((state.snapshot?.availableModes ?? []).map(OrbitIncomingMode.canonical)).contains($0) } }
    private var change: OrbitCallerChange? { draft.change(available: available, existing: state.snapshot?.callers ?? []) }
    private var canSave: Bool { api.canControl && phase == .active && !state.busy && !state.needsRefresh && change != nil }
    private var assigned: [String] { available.filter { draft.modes.contains($0) } }
    var body: some View {
        NavigationStack {
            Form {
                if state.snapshot?.incomingOverride != nil {
                    Section { Text("Incoming mode is temporarily overridden. Edits here change saved personal settings, not the active override.").foregroundStyle(.orange) }
                }
                Section {
                    TextField("Name", text: $draft.name).textContentType(.name)
                    if draft.original == nil {
                        OrbitPhoneNumberField(prompt: "Phone number", text: $draft.number, canPick: !state.busy)
                    } else { LabeledContent("Number", value: draft.number) }
                    Toggle("Enabled", isOn: $draft.enabled).disabled(draft.isOwner)
                } footer: {
                    Text(draft.original == nil ? "Egyptian local or international numbers accepted." : "To change the number, add the new caller separately, then remove the old caller.")
                }
                Section("Assigned modes") {
                    ForEach(available, id: \.self) { mode in
                        Toggle(OrbitIncomingMode.title(mode), isOn: Binding(
                            get: { draft.modes.contains(mode) },
                            set: { draft.assign(mode, enabled: $0) }
                        )).disabled(mode == "jarvis" || OrbitIncomingMode(rawValue: mode) == nil)
                    }
                }
                Section {
                    Picker("Default mode", selection: $draft.defaultMode) {
                        if draft.defaultMode.isEmpty { Text("Assign a mode first").tag("") }
                        ForEach(assigned, id: \.self) { Text(OrbitIncomingMode.title($0)).tag($0) }
                    }
                }
                if let error = state.error {
                    Section {
                        Text(error).foregroundStyle(.orange)
                        Button("Refresh server settings") { Task { await state.load { try await api.allowedCallers() } } }.disabled(state.busy)
                    }
                }
                if state.busy { ProgressView("Saving…") }
            }
            .disabled(state.busy)
            .navigationTitle(draft.original == nil ? "Add caller" : "Edit caller")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { confirming = true }.disabled(!canSave) }
            }
            .confirmationDialog("Save incoming modes?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Save caller") { Task { await save() } }
            } message: { Text("Changes apply to incoming calls for \(draft.name.isEmpty ? draft.number : draft.name).") }
        }
        .interactiveDismissDisabled(state.busy)
        .onChange(of: api.latestReportsContext) { _, _ in dismiss() }
        .onChange(of: api.accessAllowed) { _, allowed in if !allowed { dismiss() } }
    }
    private func save() async {
        guard canSave, let change else { return }
        if await state.apply({ try await api.changeAllowedCaller(change) }) { dismiss() }
    }
}
