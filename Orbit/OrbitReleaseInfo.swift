import SwiftUI

struct OrbitBuildInfo: Equatable {
    let version: String
    let build: String
    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        func value(_ key: String) -> String {
            guard let text = info[key] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Unavailable" }
            return text
        }
        version = value("CFBundleShortVersionString"); build = value("CFBundleVersion")
    }
    var label: String { "Version \(version) · Build \(build)" }
}

struct OrbitChangelogEntry: Identifiable {
    let id: String
    let title: String
    let changes: [String]
    static let entries: [Self] = [
        .init(id: "2026-11-classera-one-class", title: "Class limits and student-owned opt-out", changes: [
            "Classera defaults to one active or paused class per student, with a confirmed administrator override for selected students.",
            "Students control opt-out. Classera administrators use Suspend/Resume rather than removing subscriptions or profiles.",
            "Existing subscriptions are preserved when removing an override. Accounts already above the limit are flagged for review.",
            "AI and No AI choices remain separate from administrator suspension. New class-limit controls require verified server enforcement."
        ]),
        .init(id: "2026-11-refresh-and-pause", title: "Quieter refresh and clearer subscription controls", changes: [
            "Brief app switches reuse recent read-only data during the same unlocked session. Manual refresh still fetches new data.",
            "Classera pull-to-refresh owns its request, avoiding false connection errors when the pull gesture is cancelled.",
            "Subscription choices are AI and No AI. Paused means the student paused reports; Suspended is an administrator restriction.",
            "Existing restrictions and AI preferences are preserved. App lock, connection changes and pending-action verification still invalidate or recheck data."
        ]),
        .init(id: "2026-11-student-delivery-status", title: "Student filters and AI requests", changes: [
            "Opted-out students have their own filter and explicit class labels. Suspended students appear last in the same list.",
            "Delivery history separates recorded attempt times from status updates using local twelve-hour dates and times.",
            "AI analysis button requests are separate from subscription preferences and delivery. Older missing evidence remains Unknown.",
            "Opted out and Paused class subscriptions retain their original status and AI preference during unrelated edits. Button tracking requires the server audit installation."
        ]),
        .init(id: "2026-11-report-administration", title: "Classera report administration", changes: [
            "Report settings with selected-class AI/No-AI previews and atomic updates, preserving paused subscriptions and unfinished signups.",
            "Queue one notice for the next new class-wide report. Open windows use plaintext; closed or unknown windows require an approved classera_wa_notice template.",
            "Saved request identities, read-only recovery and explicit cancellation prevent silent duplicate actions after a timeout.",
            "Verified class-ready template support reuses the existing Opt-in signup flow. Server installation and explicit class enablement are required."
        ]),
        .init(id: "2026-11-navigation-monitoring", title: "Workspace navigation and delivery history", changes: [
            "Home’s Students shortcut selects the existing Students tab instead of opening a second directory.",
            "Workspace destinations use stable navigation routes; refreshing cancellation no longer leaves the Classera directory loading.",
            "Report history can show an explicit full date from the report title, with its source labelled.",
            "Daily report statistics explain missing historical recipient totals without inventing delivery rates.",
            "Waiting lists show classes with waiting students. Invitation sending still requires verified server setup."
        ]),
        .init(id: "4.1.0", title: "Navigation and student status", changes: [
            "Compact blue/graphite styling, flatter workspace links and dense student rows.",
            "Visible version/build information and an offline in-app changelog.",
            "Keep the current tab and page through app switching and unlocking, with the existing app lock and API authorization guards.",
            "Separate WhatsApp open, closed and unknown states; show window loading, errors and a manual retry. Missing evidence never permits sending."
        ]),
        .init(id: "4.0-reports", title: "Last observed Classera reports", changes: [
            "Separate 12F and 12E report cards with recorded timestamps and loading, partial and unavailable states."
        ]),
        .init(id: "4.0-usage", title: "AI Key Usage", changes: [
            "Read-only Classera Gemini usage, friendly key labels, daily charts and class/period filters.",
            "Delivery-status refresh and twelve-hour window closing clocks."
        ])
    ]
}

struct OrbitVersionLink: View {
    private let info = OrbitBuildInfo()
    var body: some View {
        NavigationLink { OrbitChangelogView() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("What’s new").font(.caption.weight(.medium))
                Image(systemName: "chevron.right").font(.caption)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("orbit.version")
    }
}

struct OrbitChangelogView: View {
    private let info = OrbitBuildInfo()
    var body: some View {
        List {
            Section {
                LabeledContent("App", value: "Orbit")
                LabeledContent("Version", value: info.version)
                LabeledContent("Build", value: info.build)
            }
            ForEach(OrbitChangelogEntry.entries) { entry in
                Section(entry.title) {
                    ForEach(entry.changes, id: \.self) { change in Text(change).font(.subheadline) }
                }
            }
        }.scrollContentBackground(.hidden).background(Brand.background)
            .navigationTitle("What’s new").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("orbit.changelog")
    }
}

