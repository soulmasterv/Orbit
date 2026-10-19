import SwiftUI

struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("Clear search")
            }
        }.font(.subheadline).padding(12).background(Brand.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
struct SnapshotStamp: View {
    let date: Date?
    var failed = false
    var body: some View {
        if let date {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 4) {
                    Text("Last updated:")
                    Text(HumanTime.label(date, now: context.date))
                    if failed || context.date.timeIntervalSince(date) > 120 { Text("• Stale").foregroundStyle(.orange) }
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
