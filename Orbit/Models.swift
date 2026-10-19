import Foundation

struct DashboardResponse: Codable {
    let server: ServerStats
    let processes: [PM2Process]
    let containers: [DockerContainer]
    let gemini: [GeminiKey]?
}

struct ServerStats: Codable {
    let hostname: String
    let uptime: String
    let cpuPercent: Double
    let memoryUsedGB: Double
    let memoryTotalGB: Double
    let diskUsedGB: Double
    let diskTotalGB: Double
}

struct PM2Process: Codable, Identifiable {
    let id: Int
    let name: String
    let status: String
    let cpu: Double?
    let memoryMB: Double?
    var uptime: String? = nil
    var restartCount: Int? = nil

    var processId: Int {
        id
    }
}

struct DockerContainer: Codable, Identifiable {
    var id: String {
        name
    }

    let name: String
    let image: String?
    let status: String?
    let state: String?
}

struct GeminiKey: Codable, Identifiable {
    var id: String {
        name
    }

    let name: String
    let status: String?
}

struct HealthResponse: Codable {
    let ok: Bool
    let service: String?
    let version: String?
}
