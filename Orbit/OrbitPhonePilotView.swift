import SwiftUI

struct OrbitPhonePilotStatus: Decodable {
    struct Activity: Decodable, Identifiable {
        let id: String
        let kind: String?
        let status: String
        let at: Double
    }
    struct Settings: Decodable { let revision: Int; let mode: String; let forward_enabled: Bool }
    struct Health: Decodable { let at: Double?; let issues: [String]? }
    struct Runtime: Decodable {
        let adb: String
        let bluetooth: String
        let battery: Int?
        let workers: [String: String]
        let checked_at: Double?
    }
    struct AnsweringPause: Decodable { let until: Double? }
    let version: Int
    let phone_seen_seconds: Int?
    let phone_last_seen_at: Double?
    let recent_activity: [Activity]?
    let answering_pause_supported: Bool?
    let answering_pause: AnsweringPause?
    let queue_supported: Bool?
    let bluetooth_reconnect_supported: Bool?
    let test_channels: [String: String?]?
    let health: Health
    let settings: Settings
    let settings_applied: Bool
    let runtime: Runtime
}
struct OrbitPhonePilotCommand: Encodable {
    let request_id: String
    let kind: String
    var revision: Int? = nil
    var mode: String? = nil
    var forward_enabled: Bool? = nil
    var target: String? = nil
    var enabled: Bool? = nil
    var minutes: Int? = nil
    var job_id: String? = nil
    var channel: String? = nil
    var destination: String? = nil
}
struct OrbitPhonePilotResult: Decodable { let request_id: String; let status: String }

struct OrbitPhoneQueue: Decodable {
    struct Job: Decodable, Identifiable {
        let id: String
        let not_before: Double?
        let expires: Double
    }
    let jobs: [Job]
}

struct OrbitPhonePilotView: View {
    @ObservedObject var api: ServerAPI
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var value: OrbitPhonePilotStatus?
    @State private var mode = "web"
    @State private var forwarding = false
    @State private var dirty = false
    @State private var busy = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var refreshed: Date?
    @State private var pendingCommand: OrbitPhonePilotCommand?
    @State private var loading = false
    @State private var queue: OrbitPhoneQueue?
    @State private var queueLoading = false
    private var fresh: Bool { phase == .active && api.phonePilotStatusIsFresh && (refreshed.map { Date().timeIntervalSince($0) < 20 } ?? false) }
    private var canSend: Bool { fresh && api.canControl && !busy && !loading && pendingCommand == nil }
    var body: some View {
        Form {
            Section("Phone connection") {
                if let value {
                    LabeledContent("Companion", value: fresh ? (value.phone_seen_seconds.map { $0 < 20 ? "Connected" : "Last seen \($0)s ago" } ?? "Not connected") : "Status is stale")
                    LabeledContent("USB / ADB", value: value.runtime.adb.capitalized)
                    LabeledContent("Bluetooth", value: value.runtime.bluetooth.capitalized)
                    LabeledContent("Battery", value: value.runtime.battery.map { "\($0)%" } ?? "Unavailable")
                if let lastSeen = value.phone_last_seen_at {
                    LabeledContent("Last companion check-in", value: Date(timeIntervalSince1970: lastSeen).formatted())
                }
                if let checked = value.runtime.checked_at {
                    LabeledContent("USB and Bluetooth checked", value: Date(timeIntervalSince1970: checked).formatted())
                }
                if value.bluetooth_reconnect_supported == true {
                    Button("Reconnect Bluetooth") { prepare(kind: "reconnect_bluetooth") }
                        .disabled(!canSend)
                }
                    if value.health.at == nil || value.health.issues == nil || Date().timeIntervalSince1970 - (value.health.at ?? 0) > 60 { Text("Call health report is unavailable or stale.").foregroundStyle(.orange) }
                    else if (value.health.issues ?? []).isEmpty { Text("Call-system checks are passing.").foregroundStyle(.green) }
                    else { ForEach(value.health.issues ?? [], id: \.self) { Text($0).foregroundStyle(.orange) } }
                } else {
                    Text(failure == nil ? "Checking phone backend…" : "Phone backend not verified")
                    Text("The phone backend may not be activated yet. Controls stay disabled until a fresh status is received.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Refresh") { Task { await load() } }.disabled(busy || loading)
            }
            Section("Notifications") {
                Picker("Delivery", selection: Binding(get: { mode }, set: { mode = $0; dirty = true })) {
                    Text("Web notifications").tag("web")
                    Text("WhatsApp").tag("whatsapp")
                    Text("SMS (paid)").tag("sms")
                }
                Toggle("Forward incoming SMS", isOn: Binding(get: { forwarding }, set: { forwarding = $0; dirty = true }))
                Text("SMS forwarding is separate and uses SIM credit, even with web notifications selected.").font(.caption).foregroundStyle(.secondary)
                Button("Save settings") {
                    guard let value else { return }
                    pendingCommand = OrbitPhonePilotCommand(request_id: UUID().uuidString.lowercased(), kind: "settings", revision: value.settings.revision, mode: mode, forward_enabled: forwarding)
                }.disabled(!dirty || busy || !fresh || !api.canControl || loading || pendingCommand != nil)
                if let value { Text(value.settings_applied ? "Android confirmed the saved settings." : "Waiting for Android to apply settings. Monitoring must be active; SMS features need permission.").font(.caption).foregroundStyle(value.settings_applied ? Color.secondary : Color.orange) }
            }
            Section("Call automation") {
                if let value {
                    worker("Incoming AI answering", target: "answering", name: "jarvis-phone-worker", state: value)
                    worker("Outgoing call jobs", target: "outgoing", name: "jarvis-outgoing", state: value)
                    worker("Bluetooth recovery", target: "bluetooth", name: "jarvis-bluetooth-watch", state: value)
                }
                Text("Resuming outgoing jobs may place queued calls. Changes are refused during a call or when call state cannot be verified.").font(.caption).foregroundStyle(.secondary)
                Button("Pause automation and SMS forwarding", role: .destructive) { prepareAutomation("all", enabled: false) }
                    .disabled(busy || !fresh || !api.canControl || loading || pendingCommand != nil)
            }
            extraControls
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
            if let notice { Section { Text(notice).foregroundStyle(.secondary) } }
            if let activity = value?.recent_activity {
                Section("Recent activity") {
                    if activity.isEmpty { Text("No phone commands recorded.") }
                    ForEach(activity) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text((entry.kind ?? "Phone command").replacingOccurrences(of: "_", with: " ").capitalized)
                            Text(entry.status.replacingOccurrences(of: "_", with: " ").capitalized + " · " +
                                 Date(timeIntervalSince1970: entry.at).formatted())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Phone controls")
        .confirmationDialog("Confirm phone change", isPresented: Binding(get: { pendingCommand != nil }, set: { if !$0 { pendingCommand = nil } }), titleVisibility: .visible) {
            if let command = pendingCommand {
                Button("Confirm") { pendingCommand = nil; Task { await send(command) } }
            }
            Button("Cancel", role: .cancel) { pendingCommand = nil }
        } message: { Text(pendingCommand?.confirmationMessage ?? "") }
        .task {
            while !Task.isCancelled {
                if phase == .active && api.accessAllowed { await load() }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onDisappear { api.invalidatePhonePilotStatus() }
        .onChange(of: phase) { _, next in
            if next == .background { api.invalidatePhonePilotStatus(); refreshed = nil; pendingCommand = nil }
        }
        .onChange(of: api.latestReportsContext) { _, _ in
            value = nil; refreshed = nil; dirty = false; pendingCommand = nil; queue = nil
        }
        .onChange(of: api.accessAllowed) { _, allowed in if !allowed { value = nil; refreshed = nil; dismiss() } }
    }
    @ViewBuilder private var extraControls: some View {
        if value?.answering_pause_supported == true {
            Section("AI answering pause") {
                if let pause = value?.answering_pause {
                    if let until = pause.until {
                        LabeledContent("Paused until", value: Date(timeIntervalSince1970: until).formatted())
                    } else {
                        Text("Paused until manually resumed")
                    }
                    Button("Clear pause") { prepare(kind: "answering_pause", minutes: 0) }.disabled(!canSend)
                } else {
                    Button("Pause for 30 minutes") { prepare(kind: "answering_pause", minutes: 30) }.disabled(!canSend)
                    Button("Pause for an hour") { prepare(kind: "answering_pause", minutes: 60) }.disabled(!canSend)
                    Button("Pause until resumed") { prepare(kind: "answering_pause", minutes: -1) }.disabled(!canSend)
                }
            }
        }
        if value?.queue_supported == true {
            Section("Outgoing call queue") {
                Button("Refresh queue") { Task { await refreshQueue() } }.disabled(queueLoading || busy)
                if let queue {
                    if queue.jobs.isEmpty { Text("No calls waiting.") }
                    ForEach(queue.jobs) { job in
                        VStack(alignment: .leading) {
                            Text(job.not_before.map { "Scheduled " + Date(timeIntervalSince1970: $0 / 1000).formatted() } ?? "Waiting to be picked up")
                            Text("Expires " + Date(timeIntervalSince1970: job.expires / 1000).formatted())
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Cancel queued call", role: .destructive) {
                                prepare(kind: "cancel_call", jobID: job.id)
                            }.disabled(!canSend)
                        }
                    }
                } else {
                    Text("Refresh to see calls waiting.")
                }
            }
        }
        if let channels = value?.test_channels {
            Section("Test notification") {
                ForEach(["web", "whatsapp", "sms"], id: \.self) { channel in
                    if let destination = channels[channel] ?? nil {
                        Button("Test " + channelLabel(channel)) {
                            prepare(kind: "test_notification", channel: channel, destination: destination)
                        }.disabled(!canSend || (channel == "sms" && value?.settings.mode != "sms"))
                    }
                }
                if (channels["sms"] ?? nil) != nil && value?.settings.mode != "sms" {
                    Text("SMS tests require the companion to be in SMS mode.").font(.caption)
                }
            }
        }
    }

    @MainActor private func refreshQueue() async {
        guard phase == .active && api.accessAllowed && !queueLoading else { return }
        queueLoading = true
        defer { queueLoading = false }
        do { queue = try await api.phonePilotQueue() }
        catch { queue = nil; failure = "The outgoing call queue could not be verified." }
    }

    private func channelLabel(_ channel: String) -> String {
        switch channel {
        case "sms": return "SMS"
        case "whatsapp": return "WhatsApp"
        default: return "web notification"
        }
    }

    private func prepare(kind: String, minutes: Int? = nil, jobID: String? = nil,
                         channel: String? = nil, destination: String? = nil) {
        pendingCommand = OrbitPhonePilotCommand(request_id: UUID().uuidString.lowercased(),
            kind: kind, minutes: minutes, job_id: jobID, channel: channel, destination: destination)
    }
    private func worker(_ title: String, target: String, name: String, state: OrbitPhonePilotStatus) -> some View {
        let running = state.runtime.workers[name] == "online"
        return HStack {
            VStack(alignment: .leading) { Text(title); Text(state.runtime.workers[name] ?? "Unknown").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(running ? "Pause" : "Resume") { prepareAutomation(target, enabled: !running) }
                .buttonStyle(.bordered).disabled(busy || !fresh || !api.canControl || loading || pendingCommand != nil)
        }
    }
    @MainActor private func load() async {
        guard !busy && !loading && pendingCommand == nil && phase == .active && api.accessAllowed else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await api.phonePilotStatus()
            guard !Task.isCancelled && api.accessAllowed && phase == .active else { return }
            value = next; refreshed = Date(); failure = nil
            if !dirty { mode = next.settings.mode; forwarding = next.settings.forward_enabled }
        } catch { failure = "Phone pilot unavailable. The backend may not be activated, or the connection could not be verified. Refresh to check."; refreshed = nil }
    }
    @MainActor private func prepareAutomation(_ target: String, enabled: Bool) {
        pendingCommand = OrbitPhonePilotCommand(request_id: UUID().uuidString.lowercased(), kind: "automation", target: target, enabled: enabled)
    }
    @MainActor private func send(_ command: OrbitPhonePilotCommand) async {
        guard !busy && !loading && fresh && api.canControl && phase == .active else { return }
        busy = true; failure = nil; notice = nil
        do {
            let result = try await api.phonePilotSend(command)
            guard api.accessAllowed else { busy = false; return }
            if result.status == "failed" || result.status == "unknown" { failure = "Some components did not change. Refresh status before trying again." }
            else {
                switch result.status {
                case "queued": notice = "Test queued for web delivery."
                case "accepted": notice = "The messaging gateway accepted the test."
                case "pending_phone":
                    notice = command.kind == "test_notification"
                        ? "SMS test queued. Waiting for Android."
                        : "Saved. Waiting for Android confirmation."
                default: notice = "Command completed. Refreshing status."
                }
                if command.kind == "settings" || command.target == "all" { dirty = false }
            }
        } catch { failure = DeviceAuthorization.isCancellation(error) ? "Cancelled before sending, or access changed. Refresh status before another command." : "Command was not confirmed. Refresh status before retrying; it may have applied. Busy calls and stale settings are refused." }
        busy = false; await load()
        if command.kind == "cancel_call" { await refreshQueue() }
    }
}

extension OrbitPhonePilotCommand {
    var isValid: Bool {
        guard let id = UUID(uuidString: request_id), id.uuidString.lowercased() == request_id else { return false }
        switch kind {
        case "reconnect_bluetooth": return true
        case "answering_pause": return minutes.map { [-1, 0, 30, 60].contains($0) } == true
        case "cancel_call": return job_id.map { (1...64).contains($0.count) } == true
        case "test_notification": return ["web", "whatsapp", "sms"].contains(channel ?? "") && destination?.isEmpty == false
        case "settings": return revision.map { $0 >= 0 } == true && ["web", "whatsapp", "sms"].contains(mode ?? "") && forward_enabled != nil && target == nil && enabled == nil
        case "automation": return ["answering", "outgoing", "bluetooth", "all"].contains(target ?? "") && enabled != nil && revision == nil && mode == nil && forward_enabled == nil
        default: return false
        }
    }
    var confirmationMessage: String {
        switch kind {
        case "reconnect_bluetooth": return "Reconnect the paired Bluetooth phone. Orbit requires a verified idle call state."
        case "answering_pause":
            if minutes == 0 { return "Clear the AI answering pause." }
            if minutes == -1 { return "Pause AI answering until you clear the pause." }
            return "Pause AI answering for \(minutes ?? 0) minutes."
        case "cancel_call": return "Cancel this outgoing call if it is still waiting in the queue."
        case "test_notification":
            let label = channel == "sms" ? "SMS" : channel == "whatsapp" ? "WhatsApp" : "web"
            let cost = channel == "sms" ? " This may use SIM credit." : ""
            return "Send one \(label) test notification to \(destination ?? "the configured destination")." + cost
        default: break
        }
        if kind == "settings" {
            return "Change delivery to \(mode ?? "web") and \(forward_enabled == true ? "enable" : "disable") incoming SMS forwarding. SMS features may use SIM credit. Android must confirm these settings."
        }
        if target == "all" && enabled == false { return "Pause call automation, request web notifications and disable SMS forwarding. Android settings may remain pending. Reboot behavior is unchanged." }
        return "\(enabled == true ? "Resume" : "Pause") \(target ?? "automation"). Resuming outgoing jobs may place queued calls. Reboot behavior is unchanged."
    }
}
