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
