import SwiftUI

struct OrbitWhatsAppInboxView: View {
    @ObservedObject var api: ServerAPI
    @Environment(\.scenePhase) private var phase
    @State private var snapshot: OrbitWhatsAppChats?
    @State private var error: String?
    @State private var loading = false
    @State private var compose = false
    @State private var number = ""
    @State private var target: String?
    @State private var search = ""
    private var active: Bool { api.accessAllowed && phase == .active }
    var body: some View {
        List {
            Section {
                Label(snapshot?.connected == true ? "Connected" : snapshot == nil ? "Checking connection…" : "Disconnected",
                      systemImage: snapshot?.connected == true ? "checkmark.circle.fill" : "wifi.exclamationmark")
                    .foregroundStyle(snapshot?.connected == true ? Color.green : Color.secondary)
            }
            if let error { Text(error).foregroundStyle(.orange) }
            if loading && snapshot == nil { ProgressView("Loading chats…") }
            if let snapshot, snapshot.chats.isEmpty {
                ContentUnavailableView("No chats yet", systemImage: "message", description: Text("Chats appear as this linked session receives messages. Start a chat with +."))
            }
            ForEach((snapshot?.chats ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.contains(search) }) { chat in
                NavigationLink {
                    OrbitWhatsAppChatView(api: api, phone: chat.id, name: chat.name)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(chat.name).font(.headline).lineLimit(1)
                            Spacer()
                            Text(Date(timeIntervalSince1970: chat.at), style: .time).font(.caption).foregroundStyle(.secondary)
                            if chat.unread > 0 { Text("\(chat.unread)").font(.caption.bold()).padding(5).background(.blue, in: Capsule()).foregroundStyle(.white) }
                        }
                        Text(chat.latest).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(.vertical, 4)
                }
            }
            Section {
                Text("Text only. Older chats may be unavailable. Opening a chat clears its Orbit unread count; it does not send a WhatsApp read receipt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("WhatsApp")
        .searchable(text: $search, prompt: "Name or phone")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("New chat", systemImage: "square.and.pencil") { number = ""; compose = true }.disabled(!active) } }
        .sheet(isPresented: $compose) {
            NavigationStack {
                Form { OrbitPhoneNumberField(prompt: "Phone — 01xxxxxxxxx", text: $number, canPick: active) }
                    .navigationTitle("New chat")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { compose = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Open") { target = OrbitWhatsAppPhone.normalized(number); compose = false }.disabled(OrbitWhatsAppPhone.normalized(number) == nil || !active)
                        }
                    }
            }
        }
        .navigationDestination(isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            if let target { OrbitWhatsAppChatView(api: api, phone: target, name: target) }
        }
        .refreshable { await refresh() }
        .onChange(of: active) { _, allowed in if !allowed { snapshot = nil; search = ""; number = ""; compose = false; target = nil } }
        .onChange(of: api.latestReportsContext) { _, _ in snapshot = nil; search = ""; number = ""; compose = false; target = nil }
        .task(id: "\(active)|\(api.latestReportsContext)") {
            guard active else { snapshot = nil; search = ""; number = ""; compose = false; target = nil; return }
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await refresh()
            }
        }
    }
    private func refresh() async {
        guard active, !loading else { return }
        loading = true; defer { loading = false }
        do { snapshot = try await api.jarvisNativeRequest("/api/jarvis/whatsapp"); error = nil }
        catch { if active && !Task.isCancelled { self.error = api.friendly(error) } }
    }
}

struct OrbitWhatsAppChatView: View {
    @ObservedObject var api: ServerAPI
    let phone: String
    let name: String
    @Environment(\.scenePhase) private var phase
    @StateObject private var submission = OrbitWhatsAppSubmission()
    @State private var messages: [OrbitWhatsAppMessage] = []
    @State private var connected = false
    @State private var draft = ""
    @State private var error: String?
    @State private var loading = false
    @State private var older = false
    private var active: Bool { api.accessAllowed && phase == .active }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.count >= 50 {
                        Button("Load older messages") { Task { await refresh(before: messages.first?.id) } }.disabled(loading)
                    }
                    ForEach(messages) { message in
                        HStack {
                            if message.outgoing { Spacer(minLength: 35) }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.text).textSelection(.enabled)
                                HStack {
                                    Text(Date(timeIntervalSince1970: message.at), format: .dateTime.day().month().hour().minute())
                                    if message.outgoing { Text(message.status.capitalized) }
                                }.font(.caption2).foregroundStyle(.secondary)
                            }.padding(12).background(message.outgoing ? Color.blue.opacity(0.22) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                            if !message.outgoing { Spacer(minLength: 35) }
                        }
                    }
                    if loading && messages.isEmpty { ProgressView("Loading messages…") }
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding()
            }.defaultScrollAnchor(.bottom)
            VStack(alignment: .leading, spacing: 8) {
                if let notice = submission.notice { Text(notice).font(.caption).foregroundStyle(submission.pending == nil ? Color.secondary : Color.orange) }
                if submission.pending != nil {
                    Button("Check send status") { checkStatus() }.disabled(submission.busy || !active)
                }
                HStack(alignment: .bottom) {
                    TextField("Message", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                    Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                        .labelStyle(.iconOnly).font(.title2)
                        .disabled(!active || !connected || submission.busy || submission.pending != nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.utf16.count > 12000)
                }
            }.padding().background(.bar)
        }
        .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .onChange(of: active) { _, allowed in if !allowed { messages = []; draft = ""; connected = false; submission.clear() } }
        .onChange(of: api.latestReportsContext) { _, _ in messages = []; draft = ""; connected = false; submission.clear() }
        .task(id: "\(active)|\(api.latestReportsContext)") {
            guard active else { messages = []; draft = ""; connected = false; return }
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await refresh()
            }
        }
    }
    private func refresh(before: String? = nil) async {
        guard active, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let suffix = before.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }.map { "?before=" + $0 } ?? ""
            let result: OrbitWhatsAppMessages = try await api.jarvisNativeRequest("/api/jarvis/whatsapp/chats/" + phone + suffix)
            if before != nil { messages = result.messages + messages.filter { old in !result.messages.contains { $0.id == old.id } }; older = true }
            else if older { messages = messages.filter { old in !result.messages.contains { $0.id == old.id } } + result.messages }
            else { messages = result.messages }
            connected = result.connected; error = nil
            let _: OrbitWhatsAppResult = try await api.jarvisNativeRequest("/api/jarvis/whatsapp/read", method: "POST", body: JSONEncoder().encode(["destination":phone]))
        } catch { if active && !Task.isCancelled { self.error = api.friendly(error) } }
    }
    private func send() {
        guard active, connected else { return }
        let text = draft
        let context = api.latestReportsContext
        Task {
            await submission.submit(phone: phone, text: text) { request in
                try await api.jarvisNativeRequest("/api/jarvis/whatsapp/send", method: "POST", body: JSONEncoder().encode(request))
            }
            guard active, api.latestReportsContext == context else { return }
            if submission.pending == nil && draft == text { draft = "" }
            await refresh()
        }
    }
    private func checkStatus() {
        let text = submission.pending?.text
        let context = api.latestReportsContext
        Task {
            await submission.check { id in try await api.jarvisNativeRequest("/api/jarvis/whatsapp/requests/" + id) }
            guard active, api.latestReportsContext == context else { return }
            if submission.pending == nil && draft == text { draft = "" }
            await refresh()
        }
    }
}
