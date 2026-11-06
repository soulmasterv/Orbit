import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

enum DiaaCallNumber {
    static func normalized(_ input: String) -> String? {
        let number = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if number.hasPrefix("+"), ClasseraPhone.valid(String(number.dropFirst())) { return number }
        guard number.count == 11, number.hasPrefix("01"),
              let digits = ClasseraPhone.normalized(number) else { return nil }
        return "+" + digits
    }
}

struct OrbitDiaaSettings: Decodable {
    struct Clip: Decodable, Identifiable {
        let id: String
        let title: String?
        let seconds: Double
    }

    let enabled: Bool
    let revision: String
    let duration_seconds: Int
    let clips: [String]
    let shuffle: Bool?
    let ending: String
    let available_clips: [Clip]
}

struct OrbitDiaaPlaylistUpdate: Encodable {
    let revision: String
    let duration_seconds: Int
    let clips: [String]
    let shuffle: Bool
}

struct OrbitDiaaPauseState: Decodable {
    let paused: Bool
}

struct OrbitDiaaUploadSummary {
    var settings: OrbitDiaaSettings?
    var uploaded = 0
    var rejected = 0
    var unconfirmed = false
}

struct OrbitDiaaSettingsView: View {
    @ObservedObject var api: ServerAPI
    @Environment(\.scenePhase) private var phase
    @State private var settings: OrbitDiaaSettings?
    @State private var seconds = 20
    @State private var playlist: [String] = []
    @State private var shuffle = true
    @State private var busy = false
    @State private var error: String?
    @State private var action: Action?
    @State private var importingAudio = false
    @State private var player: AVAudioPlayer?
    @State private var previewID: String?
    @State private var destination = ""
    @State private var callStatus: String?
    @State private var clipToEdit: OrbitDiaaSettings.Clip?
    @State private var renaming = false
    @State private var newClipTitle = ""
    @State private var uploadStatus: String?

    private enum Action: String, Identifiable {
        case save, pause, resume, call, deleteClip
        var id: Self { self }
        var title: String {
            switch self {
            case .save: "Save playlist"
            case .pause: "Disable Diaa"
            case .resume: "Enable Diaa"
            case .call: "Call with Face ID"
            case .deleteClip: "Delete audio"
            }
        }
    }

    private var active: Bool { api.accessAllowed && phase == .active }
    private var canEdit: Bool { active && !busy && api.canControl }
    private var callNumber: String? { DiaaCallNumber.normalized(destination) }
    private var changed: Bool {
        guard let settings else { return false }
        return settings.duration_seconds != seconds || settings.clips != playlist || (settings.shuffle ?? false) != shuffle
    }

    var body: some View {
        Form {
            if let settings, active {
                Section("Diaa mode") {
                    LabeledContent("Status", value: settings.enabled ? "Enabled" : "Disabled")
                    Button(settings.enabled ? "Disable Diaa" : "Enable Diaa", role: settings.enabled ? .destructive : nil) {
                        action = settings.enabled ? .pause : .resume
                    }.disabled(!canEdit)
                }
                Section("Call a person") {
                    TextField("Mobile number, e.g. 01012345678", text: $destination)
                        .keyboardType(.phonePad)
                    Button("Call with Face ID") { action = .call }
                        .disabled(!canEdit || !settings.enabled || callNumber == nil)
                    if let callStatus { Text(callStatus).font(.footnote) }
                }
                Section("Playback") {
                    Stepper("Start clips for \(seconds) seconds", value: $seconds, in: 5...45)
                        .disabled(!canEdit)
                    Toggle("Shuffle", isOn: $shuffle).disabled(!canEdit)
                    if shuffle {
                        Text("Enabled clips play in random order. Each plays at most once per call.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Noqta after each clip", systemImage: "lock")
                        Spacer()
                        previewButton(id: "noqta", title: "Noqta")
                    }
                    Text("The last clip and Noqta can finish after the cutoff.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Audio clips") {
                    Button("Upload audio files", systemImage: "square.and.arrow.up") { importingAudio = true }
                        .disabled(!canEdit || changed)
                    if let uploadStatus { Text(uploadStatus).font(.footnote) }
                    if changed { Text("Save playlist changes before managing audio files.").font(.footnote) }
                    ForEach(settings.available_clips) { clip in
                        HStack {
                            Toggle(isOn: Binding(
                            get: { playlist.contains(clip.id) },
                            set: { enabled in
                                if enabled {
                                    playlist = settings.available_clips.map(\.id).filter {
                                        $0 == clip.id || playlist.contains($0)
                                    }
                                } else {
                                    playlist.removeAll { $0 == clip.id }
                                }
                            }
                        )) {
                            VStack(alignment: .leading) {
                                Text(clip.title ?? clip.id)
                                Text("\(clip.seconds.formatted(.number.precision(.fractionLength(0...2)))) sec")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            }.disabled(!canEdit)
                            previewButton(id: clip.id, title: clip.title ?? clip.id)
                            Menu {
                                Button("Rename", systemImage: "pencil") {
                                    clipToEdit = clip
                                    newClipTitle = clip.title ?? clip.id
                                    renaming = true
                                }
                                Button(role: .destructive) {
                                    clipToEdit = clip
                                    action = .deleteClip
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Manage \(clip.title ?? clip.id)")
                            .disabled(!canEdit || changed)
                        }
                    }
                }
                Section {
                    Button("Save playlist") { action = .save }
                        .disabled(!canEdit || !changed)
                }
            }
            if busy { ProgressView("Checking Diaa settings…") }
            if let error {
                Text(error).foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }.disabled(!active || busy)
            }
        }
        .navigationTitle("Diaa Settings")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { Task { await upload(urls) } }
        }
        .onDisappear { stopPreview() }
        .alert("Rename audio", isPresented: $renaming) {
            TextField("Name", text: $newClipTitle)
            Button("Save") {
                guard let clip = clipToEdit else { return }
                let title = newClipTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await editClip(clip, title: title) }
            }.disabled(newClipTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newClipTitle.count > 60)
            Button("Cancel", role: .cancel) { clipToEdit = nil }
        }
        .task(id: "\(api.latestReportsContext)|\(active)") {
            if !active {
                action = nil
                stopPreview()
                return
            }
            await load()
        }
        .refreshable { await load() }
        .confirmationDialog(action?.title ?? "Confirm change", isPresented: Binding(
            get: { action != nil }, set: { if !$0 { action = nil } }
        ), titleVisibility: .visible, presenting: action) { next in
            Button(next.title, role: next == .pause || next == .deleteClip ? .destructive : nil) {
                action = nil
                Task { await apply(next) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { next in
            if next == .call {
                Text("Call \(callNumber ?? "") using the saved Diaa playlist?")
            } else if next == .deleteClip {
                Text("Delete \(clipToEdit?.title ?? clipToEdit?.id ?? "this clip") from Diaa and remove it from the playlist?")
            } else {
                Text(next == .pause ? "New Diaa calls will be disabled for everyone." :
                     next == .resume ? "New Diaa calls can use the saved playlist." :
                     "This playlist applies to new Diaa calls.")
            }
        }
    }

    private func previewButton(id: String, title: String) -> some View {
        Button {
            if previewID == id && player?.isPlaying == true { stopPreview() }
            else { Task { await play(id) } }
        } label: {
            Image(systemName: previewID == id && player?.isPlaying == true ? "stop.circle" : "play.circle")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Preview \(title)")
        .disabled(!active || busy)
    }

    private func stopPreview() {
        player?.stop()
        player = nil
        previewID = nil
    }

    private func play(_ id: String) async {
        guard active, !busy else { return }
        stopPreview()
        previewID = id
        let context = api.latestReportsContext
        busy = true
        defer { busy = false }
        do {
            let data = try await api.diaaAudio(id)
            guard active, previewID == id, context == api.latestReportsContext else { return }
            let preview = try AVAudioPlayer(data: data)
            guard preview.play() else { throw URLError(.cannotDecodeContentData) }
            player = preview
            error = nil
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(preview.duration))
                if player === preview { stopPreview() }
            }
        } catch {
            guard previewID == id else { return }
            stopPreview()
            self.error = "Could not play this clip."
        }
    }

    private func upload(_ urls: [URL]) async {
        guard canEdit, !changed else { return }
        stopPreview()
        let context = api.latestReportsContext
        busy = true
        uploadStatus = nil
        defer { busy = false }
        do {
            let summary = try await api.uploadDiaaAudio(urls)
            guard active, context == api.latestReportsContext else { return }
            if let next = summary.settings { use(next) }
            if summary.unconfirmed || summary.uploaded + summary.rejected < urls.count {
                error = "Uploaded \(summary.uploaded) of \(urls.count). The batch stopped. Refresh before retrying."
            } else if summary.rejected > 0 {
                error = "Uploaded \(summary.uploaded) of \(urls.count). Some files were unreadable, unsupported, or exceeded a library limit."
            } else {
                error = nil
                uploadStatus = "Uploaded \(summary.uploaded) of \(urls.count)."
            }
        } catch {
            guard active, context == api.latestReportsContext else { return }
            self.error = (error as? APIError)?.localizedDescription ?? "Upload unconfirmed. Refresh before retrying."
        }
    }

    private func use(_ next: OrbitDiaaSettings) {
        settings = next
        seconds = next.duration_seconds
        playlist = next.clips
        shuffle = next.shuffle ?? false
    }

    private func load() async {
        guard active, !busy else { return }
        let context = api.latestReportsContext
        busy = true
        defer { busy = false }
        do {
            let result = try await api.diaaSettings()
            guard active, context == api.latestReportsContext, !Task.isCancelled else { return }
            use(result)
            error = nil
        } catch {
            guard active, context == api.latestReportsContext, !Task.isCancelled else { return }
            settings = nil
            self.error = "Diaa settings are unavailable. Try again."
        }
    }

    private func call() async {
        guard api.canControl, !busy, settings?.enabled == true, let number = callNumber else { return }
        let context = api.latestReportsContext
        busy = true
        defer { busy = false }
        stopPreview()
        callStatus = nil
        do {
            try await api.callDiaaNumber(number)
            guard active, context == api.latestReportsContext else { return }
            callStatus = "Call queued."
            destination = ""
        } catch {
            guard active, context == api.latestReportsContext else { return }
            if let error = error as? APIError {
                callStatus = error.localizedDescription
            } else {
                callStatus = "Call unconfirmed. Check the outgoing queue before trying again."
            }
        }
    }

    private func apply(_ next: Action) async {
        if next == .call { await call(); return }
        if next == .deleteClip {
            if let clip = clipToEdit { await editClip(clip) }
            return
        }
        guard canEdit, let settings else { return }
        let context = api.latestReportsContext
        let update = OrbitDiaaPlaylistUpdate(revision: settings.revision, duration_seconds: seconds, clips: playlist, shuffle: shuffle)
        busy = true
        defer { busy = false }
        do {
            let result: OrbitDiaaSettings
            if next == .save {
                result = try await api.saveDiaaSettings(update)
            } else {
                try await api.setDiaaEnabled(next == .resume)
                result = try await api.diaaSettings()
            }
            guard active, context == api.latestReportsContext, !Task.isCancelled else { return }
            use(result)
            error = nil
        } catch {
            guard active, context == api.latestReportsContext, !Task.isCancelled else { return }
            switch (error as? HTTPFailure)?.status {
            case 422: self.error = "Check the selected clips and duration, then try again."
            case 409: self.error = "Settings changed on the server. Refresh before saving again."
            default: self.error = "The change could not be confirmed. Refresh before trying again."
            }
        }
    }

    private func editClip(_ clip: OrbitDiaaSettings.Clip, title: String? = nil) async {
        guard canEdit, !changed else { return }
        let context = api.latestReportsContext
        stopPreview()
        busy = true
        defer { busy = false; clipToEdit = nil }
        do {
            let next = try await api.editDiaaAudio(clip.id, title: title)
            guard active, context == api.latestReportsContext, !Task.isCancelled else { return }
            use(next)
            error = nil
        } catch {
            guard active, context == api.latestReportsContext, !Task.isCancelled else { return }
            self.error = "Audio change unconfirmed. Refresh to check."
        }
    }
}

