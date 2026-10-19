#if DEBUG
import Foundation

enum PreviewFixtures {
    // Simulator-only fixtures; Release builds contain no preview entry point or data.
    static let dashboard = DashboardResponse(
        server: ServerStats(hostname: "home-server", uptime: "17 days, 4 hours", cpuPercent: 24.6,
                            memoryUsedGB: 5.2, memoryTotalGB: 16, diskUsedGB: 36.8, diskTotalGB: 64),
        processes: [
            PM2Process(id: 1, name: "classera-service", status: "online", cpu: 1.2, memoryMB: 84),
            PM2Process(id: 2, name: "padel-webhook", status: "online", cpu: 0.4, memoryMB: 52),
            PM2Process(id: 3, name: "service-monitor", status: "stopped", cpu: 0, memoryMB: 0)
        ] + (4...16).map { PM2Process(id: $0, name: "preview-service-\($0)", status: "online", cpu: 0.2, memoryMB: 32) },
        containers: [
            DockerContainer(name: "uptime-kuma", image: "louislam/uptime-kuma:latest", status: "Up 17 days (healthy)", state: "running"),
            DockerContainer(name: "immich-server", image: "ghcr.io/immich-app/immich-server:release", status: "Up 17 days (healthy)", state: "running"),
            DockerContainer(name: "backup-worker", image: "backup:latest", status: "Exited (0) 2 hours ago", state: "exited")
        ], gemini: []
    )
}
#endif
