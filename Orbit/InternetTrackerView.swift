import SwiftUI
import AVFoundation
import UIKit

struct ContactCallsView: View {
    @ObservedObject var api: ServerAPI
    let phone: String
    var body: some View {
        List {
            NavigationLink { InternetTrackerView(api: api, phone: phone) } label: {
                Label("Internet Tracker", systemImage: "network")
            }.disabled(!api.accessAllowed)
        }.navigationTitle("Calls").navigationBarTitleDisplayMode(.inline)
    }
}

struct InternetTrackerView: View {
    @ObservedObject var api: ServerAPI
    let phone: String
    @StateObject private var store = InternetTrackerStore()
    @Environment(\.scenePhase) private var phase
    @State private var action: InternetTrackerChange?
    @State private var audio: AVAudioPlayer?
    @State private var playing: String?
    @State private var downloading: String?
    @State private var downloadGeneration = UUID()
    @State private var files: [String: URL] = [:]
    @State private var shared: InternetRecordingShare?
    @State private var audioError: String?
    private var active: Bool { api.accessAllowed && phase != .background }
    private var editable: Bool { active && phase == .active && api.canControl && !store.busy && !store.uncertain }

    var body: some View {
        Form {
            if active {
                if let value = store.value {
                    Section {
                        Toggle("Allow Internet checks", isOn: Binding(get: { value.permissionGranted }, set: {
                            var change = InternetTrackerChange(action: "permission", revision: value.revision); change.enabled = $0; action = change
                        })).disabled(!editable || !value.permissionEditable)
                        if !value.friendChecksEnabled && value.permissionEditable {
                            Text("Friend checks are disabled globally.").foregroundStyle(.orange)
                        }
                    }
                    ForEach(value.lines) { line in lineSection(line, value: value) }
                    Section("History") {
                        if value.pending { Label("Check pending", systemImage: "clock") }
                        if value.history.isEmpty { Text("No checks recorded.").foregroundStyle(.secondary) }
                        ForEach(value.history) { event in historyRow(event) }
                    }
                } else if store.busy { ProgressView("Loading Internet Tracker…") }
                if let notice = store.notice { Text(notice).foregroundStyle(.secondary) }
                if let error = store.error {
                    Text(error).foregroundStyle(.orange)
                    Button("Refresh") { Task { await load() } }.disabled(store.busy)
                }
                if let audioError { Text(audioError).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Internet Tracker").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $action) { InternetTrackerActionView(api: api, store: store, phone: phone, initial: $0) }
        .sheet(item: $shared) { InternetRecordingShareView(file: $0.url) }
        .task(id: "\(api.latestReportsContext)|\(active)|\(phone)") {
            store.clear(); cleanup(); action = nil
            guard active else { return }
            await load()
            while !Task.isCancelled && active {
                do { try await Task.sleep(for: .seconds(store.value?.pending == true ? 3 : 15)) } catch { return }
                guard !Task.isCancelled && active else { return }
                if phase == .active && (store.value?.pending == true || store.value?.lines.contains(where: \.weekly) == true) { await load() }
            }
        }
        .onChange(of: phase) { _, value in if value == .active { Task { await load() } } }
        .onDisappear { cleanup() }
        .refreshable { await load() }
    }
    @ViewBuilder private func lineSection(_ line: InternetTrackerSnapshot.Line, value: InternetTrackerSnapshot) -> some View {
        Section("Line \(line.slot)") {
            if let number = line.number {
                Text(number).font(.headline).textSelection(.enabled)
                Text(InternetTrackerFormat.provider(line.provider)).foregroundStyle(.secondary)
                HStack {
                    Button("Edit") { prepare("line", slot: line.slot, value: value) }.disabled(!editable || value.pending)
                    Spacer()
                    Button("Delete", role: .destructive) { prepare("delete_line", slot: line.slot, value: value) }.disabled(!editable || value.pending)
                }
                Button("Check now") { prepare("check", slot: line.slot, value: value) }.disabled(!editable || value.pending || !value.allowed)
                Toggle("Weekly checks", isOn: Binding(get: { line.weekly }, set: { enabled in
                    var change = InternetTrackerChange(action: "schedule", revision: value.revision); change.slot = line.slot; change.enabled = enabled; action = change
                })).disabled(!editable || (!line.weekly && (value.pending || !value.allowed)))
                if line.weekly {
                    LabeledContent("Next check", value: InternetTrackerFormat.time(line.nextAt))
                    LabeledContent("Delivery", value: line.channel == "sms" ? "SMS" : line.channel == "whatsapp" ? "WhatsApp" : "Unavailable")
                    Button("Change delivery") {
                        var change = InternetTrackerChange(action: "schedule", revision: value.revision); change.slot = line.slot; change.enabled = true; action = change
                    }.disabled(!editable || value.pending || !value.allowed)
                }
            } else {
                Button("Add landline") { prepare("line", slot: line.slot, value: value) }
                    .disabled(!editable || value.pending || (line.slot == 2 && value.lines.first?.number == nil))
            }
        }
    }
    private func historyRow(_ event: InternetTrackerSnapshot.Event) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(InternetTrackerFormat.time(event.at)).font(.subheadline)
                Spacer()
                Text(event.status == "completed" && !event.hasAllowance ? "Unreadable" : InternetTrackerFormat.status(event.status)).font(.caption)
                    .foregroundStyle(event.pending ? Color.blue : event.status == "completed" && event.hasAllowance ? Color.green : Color.orange)
            }
            Text(event.number).font(.headline).textSelection(.enabled)
            Text(InternetTrackerFormat.provider(event.provider)).font(.subheadline).foregroundStyle(.secondary)
            if !event.pending { Text(event.allowance).font(.subheadline) }
            HStack {
                Text(event.eventId.map { "ID " + $0 } ?? "ID unavailable")
                Spacer(); Text(event.channel == "sms" ? "SMS" : "WhatsApp")
            }.font(.caption).foregroundStyle(.secondary)
            if event.recordingAvailable && !event.expired(), event.eventId != nil {
                HStack {
                    Button(playing == event.id && audio?.isPlaying == true ? "Stop" : "Play") { Task { await recording(event, share: false) } }
                    Spacer()
                    Button("Download") { Task { await recording(event, share: true) } }
                }.disabled(downloading != nil)
                if downloading == event.id { ProgressView("Loading recording…") }
            } else if !event.pending { Text("Recording expired").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 5)
    }
    private func prepare(_ name: String, slot: Int, value: InternetTrackerSnapshot) {
        var change = InternetTrackerChange(action: name, revision: value.revision); change.slot = slot; action = change
    }
    private func load() async { guard active, phase == .active else { return }; await store.load { try await api.internetTracker(phone: phone) } }
    private func recording(_ event: InternetTrackerSnapshot.Event, share: Bool) async {
        guard active, phase == .active, let id = event.eventId, !event.expired(), downloading == nil else { return }
        if !share && playing == event.id && audio?.isPlaying == true { audio?.stop(); playing = nil; return }
        let context = api.latestReportsContext, generation = UUID(); downloadGeneration = generation; downloading = event.id; audioError = nil
        defer { if downloadGeneration == generation { downloading = nil } }
        do {
            let file: URL
            if let cached = files[id] { file = cached } else { file = try await api.internetRecording(phone: phone, event: id) }
            guard active, context == api.latestReportsContext, downloadGeneration == generation, !Task.isCancelled else { InternetRecordingFiles.remove(file); return }
            files[id] = file
            if share { shared = InternetRecordingShare(url: file) }
            else {
                audio?.stop(); let player = try AVAudioPlayer(contentsOf: file)
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                audio = player; playing = event.id; player.play()
            }
        } catch { guard active, context == api.latestReportsContext, downloadGeneration == generation else { return }; audioError = error is APIError ? error.localizedDescription : "Recording unavailable. Try again." }
    }
    private func cleanup() {
        audio?.stop(); audio = nil; playing = nil; shared = nil; downloading = nil; downloadGeneration = UUID()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        for file in files.values { InternetRecordingFiles.remove(file) }
        files = [:]
    }
}

private struct InternetRecordingShare: Identifiable { let id = UUID(); let url: URL }
private struct InternetRecordingShareView: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [file], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct InternetTrackerActionView: View {
    @ObservedObject var api: ServerAPI
    @ObservedObject var store: InternetTrackerStore
    let phone: String
    let initial: InternetTrackerChange
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var number = ""
    @State private var provider = ""
    @State private var channel = ""
    @State private var consent = false
    private var line: InternetTrackerSnapshot.Line? { store.value?.lines.first { $0.slot == initial.slot } }
    private var needsChannel: Bool { initial.mayStartCheck }
    private var title: String {
        switch initial.action {
        case "permission": initial.enabled == true ? "Allow checks" : "Disable checks"
        case "line": "Landline"
        case "delete_line": "Delete landline"
        case "schedule": initial.enabled == true ? "Weekly checks" : "Stop weekly checks"
        default: "Check now"
        }
    }
    private var valid: Bool {
        api.canControl && !store.busy && !store.uncertain && phase == .active &&
        (initial.action != "line" || (InternetTrackerFormat.landline(number) != nil && ["we","vodafone"].contains(provider))) &&
        (!needsChannel || (["sms","whatsapp"].contains(channel) && consent))
    }
    var body: some View {
        NavigationStack {
            Form {
                if initial.action == "line" {
                    OrbitPhoneNumberField(prompt: "Landline with area code", text: $number, canPick: !store.busy)
                    Picker("Provider", selection: $provider) {
                        Text("Choose provider").tag(""); Text("Vodafone").tag("vodafone"); Text("WE").tag("we")
                    }
                } else if let line, let number = line.number {
                    Text(number).font(.headline); Text(InternetTrackerFormat.provider(line.provider)).foregroundStyle(.secondary)
                }
                if needsChannel {
                    LabeledContent("Deliver to", value: phone)
                    Picker("Delivery", selection: $channel) {
                        Text("Choose delivery").tag(""); Text("WhatsApp").tag("whatsapp"); Text("SMS").tag("sms")
                    }
                    if initial.action == "schedule" {
                        Text(line?.weekly == true ? "Keeps the next check time; repeats every seven days." : "Starts today and repeats every seven days.")
                    }
                    Text("Only check lines you own or manage. Checks send up to 10 seconds of call audio to \(store.value?.audioProvider ?? "the configured transcriber"). Recordings remain private for seven days.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Toggle("I own or manage this line and agree to audio processing", isOn: $consent)
                }
                if initial.action == "delete_line" { Text("Remove this saved line and its weekly schedule?") }
                if let error = store.error { Text(error).foregroundStyle(.orange) }
                if store.busy { ProgressView("Submitting…") }
                Button(needsChannel ? "Confirm with Face ID" : "Confirm", role: initial.action == "delete_line" ? .destructive : nil) { Task { await submit() } }
                    .disabled(!valid)
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(store.busy) } }
            .onAppear { number = line?.number ?? ""; provider = line?.provider ?? "" }
            .disabled(store.busy)
        }
        .interactiveDismissDisabled(store.busy)
        .onChange(of: api.latestReportsContext) { _, _ in dismiss() }
        .onChange(of: api.accessAllowed) { _, allowed in if !allowed { dismiss() } }
        .onChange(of: phase) { _, phase in if phase == .background { dismiss() } }
    }
    private func submit() async {
        guard valid else { return }; var change = initial
        if initial.action == "line" { change.number = InternetTrackerFormat.landline(number); change.provider = provider }
        if needsChannel { change.channel = channel; change.policy = store.value?.policy; change.confirmed = true }
        if await store.submit(change, send: { try await api.updateInternetTracker(phone: phone, change: $0) }) { dismiss() }
    }
}
