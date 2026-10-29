import SwiftUI

struct SubjectEditorView: View {
    @ObservedObject var api: ServerAPI
    @StateObject private var store: SubjectEditorStore
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    @State private var confirmLegacyRemoval = false
    @State private var confirmDiscard = false

    init(api: ServerAPI, phone: String, store: SubjectEditorStore? = nil) {
        self.api = api
        _store = StateObject(wrappedValue: store ?? SubjectEditorStore(api: api, phone: phone))
    }
    private var active: Bool { visible && phase == .active && api.accessAllowed }

    var body: some View {
        Form {
            Section {
                Text("Select optional subjects, then save all changes together.").font(.subheadline)
                Text("Saving does not send a WhatsApp message.").font(.caption).foregroundStyle(.secondary)
                if store.loading { ProgressView("Checking catalog and student choices…") }
                if !store.verified { Text("Save is available after the subject list and current choices are verified.").font(.caption).foregroundStyle(.secondary) }
                if store.selection?.editable == false { Label("Subject editing is disabled for this student.", systemImage: "lock.fill").foregroundStyle(.secondary) }
            }
            if let catalog = store.catalog {
                Section("Always included") {
                    ForEach(catalog.includedSubjects) { subject in
                        HStack {
                            Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary)
                            Text(subject.name)
                            Spacer()
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                         .accessibilityLabel("\(subject.name), permanently included")
                    }
                }
                Section("Optional subjects · \(catalog.optionalSubjects.count)") {
                    ForEach(catalog.optionalSubjects) { subject in
                        Button { store.toggle(subject.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: store.selectedIDs.contains(subject.id) ? "checkmark.square.fill" : "square")
                                    .font(.title3).foregroundStyle(store.selectedIDs.contains(subject.id) ? Brand.accent : Color.secondary)
                                Text(subject.name).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!store.canEdit || !subject.selectable)
                         .accessibilityLabel(subject.name)
                         .accessibilityValue(store.selectedIDs.contains(subject.id) ? "Selected" : "Not selected")
                         .accessibilityAddTraits(store.selectedIDs.contains(subject.id) ? .isSelected : [])
                    }
                }
                if let selection = store.selection, !selection.legacySubjectIDs.isEmpty {
                    Section {
                        ForEach(selection.legacySubjectIDs, id: \.self) { id in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(id == "computer_science" ? "Legacy Computer Science / Studies" : catalog.label(for: id))
                                Text(id).font(.caption).foregroundStyle(.secondary)
                                if id == "computer_science" {
                                    Text("This old combined choice stays separate. Selecting either new computer subject does not remove or split it.").font(.caption).foregroundStyle(.secondary)
                                    Button(store.removeCombined ? "Keep legacy combined choice" : "Remove legacy combined choice", role: store.removeCombined ? nil : .destructive) {
                                        if store.removeCombined { store.setRemoveCombined(false) } else { confirmLegacyRemoval = true }
                                    }.disabled(!store.canEdit)
                                    if store.removeCombined { Text("Will be removed only when you Save.").font(.caption).foregroundStyle(.orange) }
                                } else { Text("Preserved by the server.").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 4)
                        }
                    } header: { Text("Legacy choices") }
                }
                if let selection = store.selection, !selection.unknownSubjectIDs.isEmpty {
                    Section("Unrecognized IDs — preserved") {
                        ForEach(selection.unknownSubjectIDs, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                        Text("These IDs stay on the server until their mappings are confirmed.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if store.needsReview, let latest = store.selection {
                    Section("Review latest server choices") {
                        Text("Latest: " + choices(latest.optionalSubjects, catalog: catalog))
                        Text("Your unsaved choices: " + choices(store.orderedSelectedIDs, catalog: catalog))
                        Button("Use latest choices and review again") { confirmDiscard = true }
                    }
                }
            }
            Section {
                if let error = store.error { Text(error).foregroundStyle(.orange) }
                if let notice = store.notice { Text(notice).foregroundStyle(.secondary) }
                Text("\(store.selectedIDs.count) optional subjects selected\(store.hasChanges ? " · Unsaved changes" : "")").font(.caption).foregroundStyle(.secondary)
                Button("Refresh current choices") { Task { await store.load() } }.disabled(store.saving || store.loading || !api.accessAllowed)
                Text("An empty selection clears selectable electives. Required subjects, unknown IDs and legacy choices are preserved unless you explicitly remove the legacy combined choice.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Student Subjects").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    if store.saving { ProgressView() }
                    Button("Save") { Task { await store.save() } }.fontWeight(.semibold).disabled(!store.canSave)
                }
            }
        }
        .navigationBarBackButtonHidden(store.saving)
        .onAppear { visible = true }
        .onDisappear { visible = false; store.invalidate() }
        .onChange(of: api.accessAllowed) { _, allowed in
            if !allowed { confirmLegacyRemoval = false; confirmDiscard = false }
        }
        .task(id: active) {
            if active { await store.load() }
            else if !store.saving { store.invalidate() }
        }
        .onChange(of: phase) { _, value in if value == .background { store.invalidate() } }
        .confirmationDialog("Remove the old combined computer subject?", isPresented: $confirmLegacyRemoval, titleVisibility: .visible) {
            Button("Mark legacy choice for removal", role: .destructive) { store.setRemoveCombined(true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes computer_science only after Save. It does not select either new computer subject or copy any assessment schedule.") }
        .confirmationDialog("Replace your unsaved choices?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Use latest server choices", role: .destructive) { store.useLatestChoices() }
            Button("Keep reviewing", role: .cancel) {}
        }
    }
    private func choices(_ ids: [String], catalog: SubjectCatalog) -> String {
        ids.isEmpty ? "None" : ids.map { catalog.label(for: $0) }.joined(separator: ", ")
    }
}

