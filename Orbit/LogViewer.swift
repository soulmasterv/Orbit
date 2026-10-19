import SwiftUI
import UIKit

struct LogLine: Codable, Identifiable {
    let id: String
    let stream: String
    let text: String
    let timestamp: String?
}
struct LogSnapshot: Codable {
    let lines: [LogLine]
    let truncated: Bool?
    let fetchedAt: String?
}
enum LogTarget: Hashable {
    case process(Int), docker(String)
    @MainActor var path: String {
        get throws {
            switch self {
            case .process(let id): return "/api/process/\(id)/logs?limit=500"
            case .docker(let name): return "/api/docker/\(try ServerAPI.encodedContainerName(name))/logs?limit=500"
            }
        }
    }
}
struct LogViewer: View {
    @ObservedObject var api: ServerAPI
    let target: LogTarget
    let name: String
    @Environment(\.scenePhase) private var phase
    @State private var snapshot: LogSnapshot?
    @State private var message: String?
    @State private var loading = false
    @State private var live = false
    @State private var search = ""
    @State private var stream = "all"
    @State private var autoFollow = true
    private var lines: [LogLine] {
        (snapshot?.lines ?? []).filter {
            (stream == "all" || $0.stream == stream) && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        ScrollViewReader { reader in
            VStack(spacing: 8) {
                HStack {
                    Button(live ? "Pause" : "Live") { live.toggle() }
                    Toggle("Follow", isOn: $autoFollow).toggleStyle(.button)
                    Spacer()
                    Button("Jump to latest") { if let id = lines.last?.id { reader.scrollTo(id, anchor: .bottom) } }
                    Button { Task { await refresh() } } label: { ZStack { Image(systemName: "arrow.clockwise").opacity(loading ? 0 : 1); if loading { ProgressView().controlSize(.small) } } }.disabled(loading).accessibilityLabel("Refresh logs")
                }.font(.caption).padding(.horizontal)
                HStack {
                    Label(live ? "Live • every 5 seconds" : "Paused", systemImage: live ? "dot.radiowaves.left.and.right" : "pause.circle")
                    Spacer()
                    Button("Copy visible") { UIPasteboard.general.string = lines.map { "[\($0.stream)] \($0.text)" }.joined(separator: "\n") }.disabled(lines.isEmpty)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                Picker("Output", selection: $stream) {
                    Text("All").tag("all"); Text("stdout").tag("stdout"); Text("stderr").tag("stderr")
                }.pickerStyle(.segmented).padding(.horizontal)
                if loading && snapshot == nil { ProgressView("Loading logs").controlSize(.small) }
                if snapshot != nil, let message { Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                if snapshot == nil && !loading, let message {
                    FeatureUnavailable(title: "Logs unavailable", message: message)
                }
                if let fetched = snapshot?.fetchedAt { Text("Last updated: \(HumanTime.label(fetched))").font(.caption2).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(lines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(line.stream).font(.caption2.bold())
                                    if let timestamp = line.timestamp { Text(timestamp).font(.caption2) }
                                }.foregroundStyle(line.stream == "stderr" ? Color.orange : Color.secondary)
                                Text(line.text).font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.stream == "stderr" ? Color.orange : Color.primary)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    .contextMenu { Button("Copy line") { UIPasteboard.general.string = line.text } }
                            }.padding(8).background(Brand.surface, in: RoundedRectangle(cornerRadius: 8)).id(line.id)
                        }
                        if lines.isEmpty && snapshot != nil { FeatureUnavailable(title: search.isEmpty ? "No log lines" : "No matches", message: "Choose another stream or refresh the console.") }
                        if snapshot?.truncated == true { Text("Showing the latest 500 lines").font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.horizontal)
                }.refreshable { await refresh() }
                .onChange(of: lines.last?.id) { _, id in
                    if autoFollow, let id { reader.scrollTo(id, anchor: .bottom) }
                }
            }.padding(.top, 8)
        }.background(Brand.background).navigationTitle("\(name) logs").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search logs")
        .task {
            snapshot = api.cachedLogs(target)
            await refresh()
        }
        .task(id: live && phase == .active && api.accessAllowed) {
            guard live && phase == .active && api.accessAllowed else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }
    private func refresh() async {
        guard !loading && api.accessAllowed else { return }
        loading = true
        defer { loading = false }
        do { snapshot = try await api.loadLogs(target); message = nil }
        catch {
            guard api.accessAllowed && !ServerAPI.isRefreshCancellation(error) else { return }
            if let http = error as? HTTPFailure, [404, 501].contains(http.status) {
                message = "Logs are not available from this backend yet."
            } else { message = api.friendly(error) }
        }
    }
}

struct ProcessDetailView: View {
    @ObservedObject var api: ServerAPI
    let processID: Int
    let requestCommand: (PendingCommand) -> Void
    private var process: PM2Process? { api.dashboard?.processes.first { $0.id == processID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let p = process {
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            StatusBadge(status: p.status.capitalized)
                            LabeledContent("PM2 ID", value: String(p.id))
                            LabeledContent("CPU", value: p.cpu?.percentText ?? "Not reported")
                            LabeledContent("RAM", value: p.memoryMB.map { "\($0.oneDecimal) MB" } ?? "Not reported")
                            LabeledContent("Uptime", value: p.uptime ?? "Not reported")
                            LabeledContent("Restarts", value: p.restartCount.map(String.init) ?? "Not reported")
                            NavigationLink { LogViewer(api: api, target: .process(p.id), name: p.name) } label: { Label("Logs", systemImage: "text.alignleft") }
                            CommandButtons(name: p.name, target: .process(p.id), api: api, requestCommand: requestCommand)
                        }
                    }
                    SnapshotStamp(date: api.lastUpdated, failed: api.errorMessage != nil)
                } else { Text("This process is no longer in the latest snapshot.").foregroundStyle(.secondary) }
            }.padding(16)
        }.background(Brand.background).navigationTitle(process?.name ?? "Process").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { FavoriteButton(target: .process(processID)) } }
        .refreshable { await api.loadDashboard() }
    }
}
