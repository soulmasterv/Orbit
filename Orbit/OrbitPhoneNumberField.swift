import SwiftUI
import ContactsUI

struct OrbitPhoneNumberField: View {
    let prompt: String
    @Binding var text: String
    var accessibilityName: String? = nil
    var canPick = true
    var formatSelection: (String) -> String = { number in
        let compact = OrbitPhoneNumberField.removingFormatting(number)
        let digits = compact.hasPrefix("+") ? String(compact.dropFirst()) : compact
        return ClasseraPhone.normalized(digits) ?? number
    }
    var didPick: (String) -> Void = { _ in }

    @State private var picking = false

    nonisolated static func removingFormatting(_ number: String) -> String {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "()-"))
        return number.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: separators).joined()
    }

    var body: some View {
        HStack(spacing: 0) {
            TextField(prompt, text: $text)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .accessibilityLabel(accessibilityName ?? prompt)
            Button {
                picking = true
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.body)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Choose from Contacts")
            .disabled(!canPick)
        }
        .sheet(isPresented: $picking) {
            OrbitContactNumberPicker { number in
                picking = false
                guard canPick else { return }
                let selected = formatSelection(number)
                text = selected
                didPick(selected)
            } onCancel: {
                picking = false
            }
        }
    }
}


private struct OrbitContactNumberPicker: UIViewControllerRepresentable {
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        picker.predicateForSelectionOfProperty = NSPredicate(format: "key == %@", CNContactPhoneNumbersKey)
        return picker
    }

    func updateUIViewController(_ picker: CNContactPickerViewController, context: Context) {
        context.coordinator.selection = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: self) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var selection: OrbitContactNumberPicker

        init(selection: OrbitContactNumberPicker) { self.selection = selection }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
            guard let number = property.value as? CNPhoneNumber else {
                selection.onCancel()
                return
            }
            selection.onSelect(number.stringValue)
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            selection.onCancel()
        }
    }
}
