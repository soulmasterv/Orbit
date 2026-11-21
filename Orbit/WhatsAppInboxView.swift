import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

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
    @State private var unreadOnly = false
    @State private var information = false
    private var active: Bool { api.accessAllowed && phase == .active }
    private var filteredChats: [OrbitWhatsAppChat] {
        (snapshot?.chats ?? []).filter {
            (!unreadOnly || $0.unread > 0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.contains(search))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(WhatsAppPalette.muted)
                    TextField("Search", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !search.isEmpty { Button("Clear search", systemImage: "xmark.circle.fill") { search = "" }.labelStyle(.iconOnly) }
                }.padding(.horizontal, 12).padding(.vertical, 10)
                    .background(WhatsAppPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 8) {
                    WhatsAppFilterChip(title: "All", selected: !unreadOnly) { unreadOnly = false }
                    WhatsAppFilterChip(title: "Unread", selected: unreadOnly) { unreadOnly = true }
                    Spacer()
                }
            }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            List {
                if let error { Text(error).font(.caption).foregroundStyle(.orange).listRowBackground(Color.clear) }
                if loading && snapshot == nil { ProgressView("Loading chats…").listRowBackground(Color.clear) }
                if snapshot != nil && filteredChats.isEmpty {
                    ContentUnavailableView(unreadOnly ? "You're all caught up" : search.isEmpty ? "No chats yet" : "No matching chats",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(unreadOnly ? "No unread conversations." : "Use the compose button to start a conversation."))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(filteredChats) { chat in
                    NavigationLink {
                        OrbitWhatsAppChatView(api: api, phone: chat.id, name: chat.name)
                    } label: { WhatsAppChatRow(chat: chat) }
                    .listRowBackground(WhatsAppPalette.background)
                    .listRowSeparatorTint(StudentPalette.border)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .refreshable { await refresh() }
        }
        .modifier(WhatsAppAppearance())
        .navigationTitle("WhatsApp")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 3) {
                    Text("Chats").font(.headline)
                    WhatsAppConnectionLabel(connected: snapshot?.connected)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Inbox information", systemImage: "info.circle") { information = true }
                Button { number = ""; compose = true } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.black).frame(width: 30, height: 30)
                        .background(WhatsAppPalette.accent, in: Circle()).frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("New chat").disabled(!active)
            }
        }
        .alert("About this inbox", isPresented: $information) { Button("Done", role: .cancel) {} } message: {
            Text("Messages use JARVIS’s existing WhatsApp number. Photos, videos and files up to 25 MB are supported. Older chat history and view-once media may be unavailable. Opening a chat clears its Orbit unread count without sending a WhatsApp read receipt.")
        }
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
    @State private var attachment: OrbitWhatsAppMediaDraft?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?
    @State private var preparing = false
    @State private var transferring = false
    @State private var downloadingID: String?
    @State private var previewURL: URL?
    @State private var mediaVisible = true
    private var active: Bool { api.accessAllowed && phase == .active }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    if messages.count >= 50 {
                        Button("Load older messages") { Task { await refresh(before: messages.first?.id) } }.disabled(loading)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || !Calendar.current.isDate(Date(timeIntervalSince1970: messages[index - 1].at), inSameDayAs: Date(timeIntervalSince1970: message.at)) {
                            WhatsAppDateSeparator(timestamp: message.at)
                        }
                        WhatsAppMessageBubble(message: message, downloading: downloadingID == message.media?.id) {
                            if let attachment = message.media { open(attachment) }
                        }
                    }
                    if loading && messages.isEmpty { ProgressView("Loading messages…") }
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }.defaultScrollAnchor(.bottom).background(WhatsAppPalette.conversation)
            composer
        }
        .modifier(WhatsAppAppearance())
        .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 9) {
                    WhatsAppAvatar(name: name, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if name != phone { Text(phone).font(.caption2).foregroundStyle(WhatsAppPalette.muted).lineLimit(1) }
                    }
                }
            }
        }
        .refreshable { await refresh() }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .any(of: [.images, .videos]), preferredItemEncoding: .compatible)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { prepareFile(url) }
            else if case .failure = result { error = "The file could not be selected." }
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { old, new in if let old, old != new { OrbitWhatsAppMediaDraft.remove(old) } }
        .onChange(of: photoItem) { _, item in if let item { preparePhoto(item) } }
        .onAppear { mediaVisible = true }
        .onDisappear { mediaVisible = false; if !transferring { removeAttachment() } }
        .onChange(of: active) { _, allowed in if !allowed { messages = []; draft = ""; connected = false; submission.clear(); clearMedia() } }
        .onChange(of: api.latestReportsContext) { _, _ in messages = []; draft = ""; connected = false; submission.clear(); clearMedia() }
        .task(id: "\(active)|\(api.latestReportsContext)") {
            guard active else { messages = []; draft = ""; connected = false; return }
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await refresh()
            }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if preparing { ProgressView("Preparing attachment…") }
            if transferring { ProgressView(submission.busy ? "Sending…" : "Uploading attachment…") }
            if let attachment {
                HStack(spacing: 9) {
                    Image(systemName: attachment.kind == .image ? "photo" : attachment.kind == .video ? "video.fill" : "doc.fill")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attachment.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)).font(.caption2).foregroundStyle(WhatsAppPalette.muted)
                    }
                    Spacer()
                    Button("Remove attachment", systemImage: "xmark.circle.fill") { removeAttachment() }.labelStyle(.iconOnly)
                        .disabled(transferring || submission.busy || submission.pending != nil)
                }.padding(10).background(WhatsAppPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            if let notice = submission.notice { Text(notice).font(.caption).foregroundStyle(submission.pending == nil ? Color.secondary : Color.orange) }
            if submission.pending != nil {
                Button("Check send status") { checkStatus() }.disabled(submission.busy || !active)
            }
            HStack(alignment: .bottom) {
                Menu {
                    Section("Attachments · 25 MB max") {
                        Button("Photos & videos", systemImage: "photo.on.rectangle") { showPhotos = true }
                        Button("File", systemImage: "doc") { showFiles = true }
                    }
                } label: { Image(systemName: "plus").font(.title2).frame(width: 34, height: 44) }
                    .accessibilityLabel("Attach photo, video or file")
                    .disabled(!active || preparing || transferring || submission.busy || submission.pending != nil)
                TextField(attachment == nil ? "Message" : "Caption (optional)", text: $draft, axis: .vertical).lineLimit(1...5)
                    .padding(.horizontal, 15).padding(.vertical, 12)
                    .background(WhatsAppPalette.surface, in: RoundedRectangle(cornerRadius: 22))
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.black).frame(width: 38, height: 38)
                        .background(WhatsAppPalette.accent, in: Circle()).frame(width: 44, height: 44)
                }.accessibilityLabel("Send message")
                    .disabled(!active || !connected || preparing || transferring || submission.busy || submission.pending != nil || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil) || draft.utf16.count > (attachment == nil ? 12000 : 1024))
            }
            if attachment != nil { Text("25 MB max · Caption up to 1,024 characters").font(.caption2).foregroundStyle(WhatsAppPalette.muted) }
        }.padding(.horizontal, 12).padding(.vertical, 10).background(WhatsAppPalette.background)
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
        guard active, connected, !preparing, !transferring, !submission.busy, submission.pending == nil else { return }
        let text = draft
        let context = api.latestReportsContext
        let selected = attachment
        transferring = true
        Task {
            defer { transferring = false; if !mediaVisible { removeAttachment() } }
            var mediaID: String?
            if let selected {
                do { mediaID = try await api.uploadWhatsAppAttachment(selected).id }
                catch { if active && api.latestReportsContext == context { self.error = "Attachment upload failed. The message was not submitted. Check the format and 25 MB limit." }; return }
            }
            guard active, api.latestReportsContext == context else { return }
            await submission.submit(phone: phone, text: text, mediaID: mediaID) { request in
                try await api.jarvisNativeRequest("/api/jarvis/whatsapp/send", method: "POST", body: JSONEncoder().encode(request), timeout: request.media_id == nil ? 22 : 90)
            }
            guard active, api.latestReportsContext == context else { return }
            if submission.pending == nil {
                if draft == text { draft = "" }
                if attachment?.id == selected?.id { removeAttachment() }
            }
            await refresh()
        }
    }
    private func checkStatus() {
        let text = submission.pending?.text
        let context = api.latestReportsContext
        Task {
            await submission.check { id in try await api.jarvisNativeRequest("/api/jarvis/whatsapp/requests/" + id) }
            guard active, api.latestReportsContext == context else { return }
            if submission.pending == nil { if draft == text { draft = "" }; removeAttachment() }
            await refresh()
        }
    }
    private func removeAttachment() {
        if let attachment { OrbitWhatsAppMediaDraft.remove(attachment.url) }
        attachment = nil
    }
    private func clearMedia() {
        removeAttachment(); showPhotos = false; showFiles = false; photoItem = nil
        if let previewURL { OrbitWhatsAppMediaDraft.remove(previewURL) }
        previewURL = nil
    }
    private func prepareFile(_ url: URL) {
        guard active, !preparing, !transferring else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { let value = try OrbitWhatsAppMediaDraft.copy(url); removeAttachment(); attachment = value; error = nil }
        catch { self.error = "Choose a regular file up to 25 MB." }
    }
    private func preparePhoto(_ item: PhotosPickerItem) {
        guard active, !preparing, !transferring else { return }
        preparing = true
        let context = api.latestReportsContext
        Task {
            defer { preparing = false; photoItem = nil }
            var copied: URL?
            defer { if let copied { OrbitWhatsAppMediaDraft.remove(copied) } }
            do {
                guard let file = try await item.loadTransferable(type: OrbitWhatsAppPickedFile.self) else { throw URLError(.cannotDecodeContentData) }
                copied = file.url
                guard active, mediaVisible, api.latestReportsContext == context else { return }
                let value: OrbitWhatsAppMediaDraft
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) { value = try await OrbitWhatsAppMediaDraft.video(file.url) }
                else { value = try OrbitWhatsAppMediaDraft.photo(file.url) }
                guard active, mediaVisible, api.latestReportsContext == context else { OrbitWhatsAppMediaDraft.remove(value.url); return }
                removeAttachment(); attachment = value; error = nil
            } catch { if active && api.latestReportsContext == context { self.error = "This photo or video could not be prepared. Choose one up to 25 MB." } }
        }
    }
    private func open(_ attachment: OrbitWhatsAppAttachment) {
        guard active, downloadingID == nil, attachment.state == "available" else { return }
        downloadingID = attachment.id
        let context = api.latestReportsContext
        Task {
            defer { downloadingID = nil }
            do {
                let url = try await api.downloadWhatsAppAttachment(attachment)
                guard active, mediaVisible, api.latestReportsContext == context else { OrbitWhatsAppMediaDraft.remove(url); return }
                previewURL = url
            } catch { if active && api.latestReportsContext == context { self.error = "Attachment unavailable or expired. Try downloading it again." } }
        }
    }
}
