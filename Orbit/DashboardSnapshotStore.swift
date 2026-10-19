import Foundation

struct SavedDashboard: Codable {
    let baseURL: String
    let dashboard: DashboardResponse
    let updatedAt: Date
}

final class DashboardSnapshotStore {
    private let file: URL
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerControl/dashboard.json")
    }
    func read(baseURL: String) -> SavedDashboard? {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(SavedDashboard.self, from: data),
              saved.baseURL == baseURL else { return nil }
        return saved
    }
    func save(_ snapshot: SavedDashboard) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: file, options: [.atomic, .completeFileProtection])
            var protectedFile = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedFile.setResourceValues(values)
        } catch { /* A cache failure must never invalidate a successful live response. */ }
    }
    func clear() { try? FileManager.default.removeItem(at: file) }
}
