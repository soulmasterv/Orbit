import Foundation
import Combine

@MainActor
final class ClasseraDirectoryStore: ObservableObject {
    @Published private(set) var students: [ClasseraStudent] = []
    @Published private(set) var loading = false
    @Published var error: String?
    private var generation = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshContext: UUID?
    private var freshness = ReadSnapshotFreshness()

    func refresh(api: ServerAPI, automatic: Bool = false) async {
        guard api.accessAllowed else { clear(); return }
        if let refreshTask, refreshContext == api.latestReportsContext { await refreshTask.value; return }
        if refreshTask != nil { clear() }
        if !freshness.belongs(to: api.latestReportsContext) { students = []; error = nil }
        if automatic, error == nil, freshness.isFresh(context: api.latestReportsContext) { return }
        generation += 1
        let epoch = generation
        let context = api.latestReportsContext
        loading = true
        // The store owns the read and commits its result. Cancelling a SwiftUI
        // refreshable waiter must not cancel or discard this read-only refresh.
        let task = Task { @MainActor in
            defer {
                if epoch == self.generation { self.loading = false; self.refreshTask = nil; self.refreshContext = nil }
            }
            do {
                let result = try await api.loadClasseraDirectory()
                guard epoch == self.generation, context == api.latestReportsContext, api.accessAllowed, !Task.isCancelled else { return }
                self.students = result
                self.error = nil
                self.freshness.record(context: context)
            } catch {
                guard epoch == self.generation, api.accessAllowed, !Task.isCancelled,
                      !ServerAPI.isRefreshCancellation(error) else { return }
                self.error = error.localizedDescription
            }
        }
        refreshTask = task
        refreshContext = context
        await task.value
    }

    func clear(removeSnapshot: Bool = true) {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshContext = nil
        loading = false
        if removeSnapshot { students = []; freshness.clear(); error = nil }
    }
}
