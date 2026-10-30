import SwiftUI
import PDFKit

struct OrbitDownloadItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String
    let size: Int
    let modifiedAt: Int
    enum CodingKeys: String, CodingKey { case id, name, kind, size; case modifiedAt = "modified_at" }
    var isFolder: Bool { kind == "folder" }
    var previewable: Bool { ["pdf", "png", "jpg", "jpeg", "txt"].contains((name as NSString).pathExtension.lowercased()) }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
        }
    }
}
struct OrbitDownloadsResponse: Decodable {
    let version: Int
    let items: [OrbitDownloadItem]
    let truncated: Bool
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case version, items, truncated; case nextCursor = "next_cursor" }
    var valid: Bool {
        version == 1 && items.count <= 1000 &&
        (nextCursor == nil || (nextCursor!.count <= 6 && !nextCursor!.isEmpty && nextCursor!.allSatisfy(\.isNumber))) &&
        Set(items.map(\.id)).count == items.count && items.allSatisfy {
            OrbitDownloadItem.validID($0.id) && !$0.name.isEmpty && $0.name.utf8.count <= 1024 &&
            ["folder", "file"].contains($0.kind) && $0.size >= 0
        }
    }
}
enum OrbitDownloadsError: Error {
    case authentication, unavailable, notFound, invalid, tooLarge
    var message: String {
        switch self {
        case .authentication: return "Authentication failed. Check your Orbit connection in Settings."
        case .unavailable: return "Downloads is not available on this backend yet. The read-only folder API needs to be installed."
        case .notFound: return "This file or folder is no longer available. Refresh Downloads."
        case .invalid: return "The server returned an unsupported Downloads response."
        case .tooLarge: return "This file exceeds the 25 MB in-app preview limit."
        }
    }
    static func message(_ error: Error) -> String {
        (error as? Self)?.message ?? "Could not load Downloads. Check your connection and retry."
    }
}

struct DownloadsView: View {
    @ObservedObject var api: ServerAPI
    var folder: OrbitDownloadItem? = nil
    @State private var snapshot: OrbitDownloadsResponse?
    @State private var loading = false
    @State private var failure: String?
    @State private var search = ""
    @State private var generation = 0
    private var items: [OrbitDownloadItem] {
        (snapshot?.items ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            if let failure {
                Section { Text(failure).foregroundStyle(.orange); Button("Retry") { Task { await refresh() } }.disabled(loading) }
            }
            if loading { ProgressView("Loading files…") }
            if snapshot != nil && items.isEmpty && !loading {
                ContentUnavailableView(search.isEmpty ? "No downloads yet" : "No matching files", systemImage: "folder")
            }
            ForEach(items) { item in
                NavigationLink(value: item) {
                    HStack(spacing: 12) {
                        Image(systemName: item.isFolder ? "folder" : "doc.text").foregroundStyle(Brand.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text(Date(timeIntervalSince1970: Double(item.modifiedAt)), format: .dateTime.day().month().hour().minute())
                                if !item.isFolder { Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }.listRowBackground(Brand.surface)
            }
            if snapshot?.nextCursor != nil {
                Button("Load more files") { Task { await refresh(more: true) } }.disabled(loading)
            } else if snapshot?.truncated == true {
                Text("More files are available. Update the Downloads backend to enable paging.").font(.caption)
            }
        }.scrollContentBackground(.hidden).background(Brand.background)
            .modifier(DownloadsDestinations(api: api, root: folder == nil))
            .navigationTitle(folder?.name ?? "Downloads").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search files")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading) } }
            .refreshable { await refresh() }
            .task(id: api.accessAllowed) { if api.accessAllowed { await refresh() } else { clear() } }
            .onDisappear { clear() }
    }
    private func clear() { generation += 1; snapshot = nil; failure = nil; loading = false; search = "" }
    @MainActor private func refresh(more: Bool = false) async {
        guard api.accessAllowed && !loading else { return }
        generation += 1; let epoch = generation; loading = true; failure = nil
        defer { if generation == epoch { loading = false } }
        do {
            let result = try await api.downloads(folder: folder?.id, cursor: more ? snapshot?.nextCursor : nil)
            guard epoch == generation && api.accessAllowed && !Task.isCancelled else { return }
            if more, let previous = snapshot {
                let existing = Set(previous.items.map(\.id))
                snapshot = OrbitDownloadsResponse(version: result.version, items: previous.items + result.items.filter { !existing.contains($0.id) }, truncated: result.truncated, nextCursor: result.nextCursor)
            } else { snapshot = result }
        } catch {
            guard epoch == generation && api.accessAllowed && !ServerAPI.isRefreshCancellation(error) else { return }
            snapshot = nil; failure = OrbitDownloadsError.message(error)
        }
    }
}

private struct DownloadsDestinations: ViewModifier {
    let api: ServerAPI
    let root: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if root {
            content.navigationDestination(for: OrbitDownloadItem.self) { item in
                if item.isFolder { DownloadsView(api: api, folder: item) }
                else { DownloadPreviewView(api: api, item: item) }
            }
        } else { content }
    }
}

struct DownloadPreviewView: View {
    @ObservedObject var api: ServerAPI
    let item: OrbitDownloadItem
    @State private var data: Data?
    @State private var failure: String?
    @State private var loading = false
    @State private var generation = 0
    var body: some View {
        Group {
            if let data, (item.name as NSString).pathExtension.lowercased() == "pdf" { OrbitPDFPreview(data: data) }
            else if let data, let image = UIImage(data: data) {
                ScrollView([.horizontal, .vertical]) { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 1200) }
            } else if let data, let text = String(data: data, encoding: .utf8) {
                ScrollView { Text(text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            } else if loading { ProgressView("Loading preview…") }
            else if let failure {
                VStack(spacing: 12) { Text(failure).multilineTextAlignment(.center); Button("Retry") { Task { await load() } } }.padding()
            } else { ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text("In-app previews support PDF, images and plain text files.")) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Brand.background)
            .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
            .task(id: api.accessAllowed) { if api.accessAllowed { await load() } else { clear() } }
            .onDisappear { clear() }
    }
    private func clear() { generation += 1; data = nil; failure = nil; loading = false }
    @MainActor private func load() async {
        guard api.accessAllowed && !loading && item.previewable else { return }
        generation += 1; let epoch = generation; loading = true; failure = nil
        defer { if epoch == generation { loading = false } }
        do {
            let result = try await api.downloadFile(id: item.id)
            guard epoch == generation && api.accessAllowed && !Task.isCancelled else { return }
            let ext = (item.name as NSString).pathExtension.lowercased()
            if ext == "pdf" { guard PDFDocument(data: result) != nil else { throw OrbitDownloadsError.invalid } }
            else if ext == "txt" { guard String(data: result, encoding: .utf8) != nil else { throw OrbitDownloadsError.invalid } }
            else { guard UIImage(data: result) != nil else { throw OrbitDownloadsError.invalid } }
            data = result
        } catch {
            guard epoch == generation && api.accessAllowed && !ServerAPI.isRefreshCancellation(error) else { return }
            failure = OrbitDownloadsError.message(error)
        }
    }
}
private struct OrbitPDFPreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; return view }
    func updateUIView(_ view: PDFView, context: Context) { if view.document == nil { view.document = PDFDocument(data: data) } }
    static func dismantleUIView(_ view: PDFView, coordinator: ()) { view.document = nil }
}
