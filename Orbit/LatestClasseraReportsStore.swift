import Foundation
import Combine

@MainActor
final class LatestClasseraReportsStore: ObservableObject {
    @Published private(set) var snapshot: LatestClasseraReportsResponse?
    @Published private(set) var state: LatestClasseraReportsState = .idle
    private var generation = 0
    var loading: Bool { state == .loading }

    func clear() {
        generation += 1
        snapshot = nil
        state = .idle
    }

    func load(fetch: () async throws -> LatestClasseraReportsResponse) async {
        guard !loading && !Task.isCancelled else { return }
        generation += 1
        let epoch = generation
        snapshot = nil
        state = .loading
        do {
            let value = try await fetch()
            guard epoch == generation && !Task.isCancelled else {
                if epoch == generation { state = .idle }
                return
            }
            guard value.isValid else { throw LatestClasseraReportsFailure.invalidResponse }
            snapshot = value
            switch value.observedCount {
            case 2: state = .ready
            case 1: state = .partial
            default: state = .unavailable
            }
        } catch {
            guard epoch == generation else { return }
            if error is CancellationError || Task.isCancelled ||
                (error as? URLError)?.code == .cancelled {
                state = .idle
            } else if let failure = error as? LatestClasseraReportsFailure {
                switch failure {
                case .authenticationRequired: state = .authenticationRequired
                case .endpointUnavailable: state = .unavailable
                case .invalidResponse: state = .failed
                }
            } else {
                state = .failed
            }
        }
    }
}
