import SwiftUI

enum StudentPalette {
    static let background = Color.black
    static let surface = Color(white: 0.09)
    static let alternate = Color(white: 0.055)
    static let border = Color(white: 0.20)
    static let secondary = Color(white: 0.68)
    static let accent = Color(red: 0.14, green: 0.55, blue: 1)
    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0.isWhitespace })
        return String(parts.prefix(2).compactMap(\.first)).uppercased()
    }
    static func statusColor(_ status: StudentActivityStatus) -> Color {
        switch status {
        case .allowed: return accent
        case .suspended: return .orange
        case .blocked: return Color(red: 1, green: 0.46, blue: 0.42)
        case .unknown: return secondary
        }
    }
}

struct StudentAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content.background(StudentPalette.background)
            .environment(\.colorScheme, .dark).tint(StudentPalette.accent)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

struct StudentSearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(StudentPalette.secondary)
            TextField("Name or phone", text: $text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .foregroundStyle(.white).accessibilityIdentifier("students.search")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(StudentPalette.secondary).accessibilityLabel("Clear search")
            }
        }.padding(.horizontal, 12).padding(.vertical, 11)
            .background(StudentPalette.surface, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct StudentFilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.medium))
                .foregroundStyle(.white).padding(.horizontal, 13).padding(.vertical, 10)
                .background(selected ? StudentPalette.accent : StudentPalette.surface, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct StudentAccessFilters: View {
    @Binding var selection: StudentActivityStatus?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                StudentFilterChip(title: "All", selected: selection == nil) { selection = nil }
                ForEach([StudentActivityStatus.allowed, .suspended, .blocked], id: \.rawValue) { status in
                    StudentFilterChip(title: status.title, selected: selection == status) { selection = status }
                }
            }
        }
    }
}

struct StudentStatusPill: View {
    let status: StudentActivityStatus
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(StudentPalette.statusColor(status)).frame(width: 6, height: 6)
            Text(status.title).font(.caption.weight(.medium))
        }.foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color(white: 0.16), in: Capsule())
            .accessibilityLabel("Reply access: \(status.title)")
    }
}

struct StudentCompactRow: View {
    let name: String
    let phone: String
    let chips: [String]
    let status: StudentActivityStatus
    var note: String? = nil
    var alternate = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(StudentPalette.initials(name)).font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white).frame(width: 34, height: 34)
                .background(Color(white: 0.24), in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(phone).font(.subheadline).monospacedDigit().foregroundStyle(StudentPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("student.phone.\(phone)")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) { ForEach(chips, id: \.self) { chip($0) } }
                    VStack(alignment: .leading, spacing: 5) { ForEach(chips, id: \.self) { chip($0) } }
                }
                if let note { Text(note).font(.caption).foregroundStyle(StudentPalette.secondary) }
                if typeSize.isAccessibilitySize { StudentStatusPill(status: status) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize { StudentStatusPill(status: status) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(StudentPalette.secondary).padding(.top, 8)
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(alternate ? StudentPalette.surface : StudentPalette.alternate)
            .overlay(alignment: .bottom) { Rectangle().fill(StudentPalette.border).frame(height: 0.5) }
            .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
    private func chip(_ title: String) -> some View {
        Text(title).font(.caption2).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color(white: 0.16), in: Capsule())
    }
}
