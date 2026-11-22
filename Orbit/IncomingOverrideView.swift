import SwiftUI

struct OrbitIncomingOverrideCard: View {
    @ObservedObject var api: ServerAPI
    @ObservedObject var state: OrbitAllowedCallersState
    @Environment(\.scenePhase) private var phase
    @State private var mode = "diaa"
    @State private var duration = 10
    @State private var custom = ""
    @State private var pending: OrbitIncomingOverrideChange?
    private var modes: [String] { state.snapshot?.overrideModes ?? [] }
    private var minutes: Int? { duration == 0 ? OrbitIncomingOverrideChange.customMinutes(custom) : duration }
    private var canChange: Bool { api.canControl && phase == .active && !state.busy && !state.needsRefresh && state.snapshot != nil }

    var body: some View {
        Section {
            if let override = state.snapshot?.incomingOverride {
                Label(OrbitIncomingMode.title(override.mode), systemImage: "phone.arrow.down.left.fill").font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(override.countdown(at: timeline.date)).monospacedDigit().foregroundStyle(.orange)
                        .accessibilityLabel("Incoming override: " + override.countdown(at: timeline.date))
                }
                Text("Includes unknown incoming numbers. Individual settings are temporarily overridden and remain saved.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Stop now", role: .destructive) { pending = OrbitIncomingOverrideChange(action: "clear_override") }
                    .disabled(!canChange)
            } else {
                Picker("Mode", selection: $mode) {
                    if !modes.contains(mode) { Text("Choose mode").tag(mode) }
                    ForEach(modes, id: \.self) { Text(OrbitIncomingMode.title($0)).tag($0) }
                }.disabled(!canChange || modes.isEmpty)
                Picker("Minutes", selection: $duration) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                    Text("Custom").tag(0)
                }.disabled(!canChange || modes.isEmpty)
                if duration == 0 {
                    TextField("1–120 whole minutes", text: $custom).keyboardType(.numberPad)
                        .disabled(!canChange)
                }
                Button("Start") {
                    guard let minutes else { return }
                    pending = OrbitIncomingOverrideChange(action: "override", mode: mode, minutes: minutes)
                }.disabled(!canChange || !modes.contains(mode) || minutes == nil)
                Text(modes.isEmpty ? "Override controls are unavailable until supported server settings are loaded." : "Includes unknown incoming numbers while active. Individual settings stay saved.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } header: { Label("Force incoming mode", systemImage: "timer") } footer: {
            Text("Stopping or expiry changes new incoming calls. An ongoing call is not cut off. Caller /mode choices do not bypass an active override.")
        }
        .confirmationDialog(pending?.action == "override" ? "Force incoming mode?" : "Stop incoming override?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { change in
            Button(change.action == "override" ? "Start override" : "Stop now", role: change.action == "clear_override" ? .destructive : nil) {
                pending = nil
                Task { await apply(change) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { change in
            Text(change.action == "override" ? "\(OrbitIncomingMode.title(change.mode ?? "")) for \(change.minutes ?? 0) minutes, including unknown incoming numbers." : "Restore saved settings for new incoming calls. Ongoing calls continue.")
        }
        .onChange(of: api.latestReportsContext) { _, _ in pending = nil }
        .onChange(of: phase) { _, value in if value == .background { pending = nil } }
    }
    private func apply(_ change: OrbitIncomingOverrideChange) async {
        guard canChange, change.isValid,
              change.action == "clear_override" || modes.contains(change.mode ?? "") else { return }
        // The POST returns server-generated expiry and current caller settings.
        _ = await state.apply { try await api.changeIncomingOverride(change) }
    }
}
