import SwiftUI
import CoreImage.CIFilterBuiltins

struct OrbitPhonePairing: Decodable, Encodable, Identifiable {
    let format: String
    let version: Int
    let key: String
    let device: String
    var id: String { device }
}

struct OrbitPhonePairingView: View {
    let pairing: OrbitPhonePairing
    @Environment(\.dismiss) private var dismiss
    private var qr: UIImage? {
        guard let data = try? JSONEncoder().encode(pairing) else { return nil }
        let generator = CIFilter.qrCodeGenerator()
        generator.message = data
        generator.correctionLevel = "M"
        guard let output = generator.outputImage,
              let cgImage = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                  from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Private companion pairing").font(.title2.bold())
                if let qr {
                    Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                        .padding(24).background(.white).frame(maxWidth: 340)
                        .accessibilityLabel("Private Android pairing QR")
                } else {
                    Text("The pairing QR could not be generated.")
                }
                Text("Import an image of this QR in Orbit Phone on Android. It contains the companion credential and should only be used for your own setup.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Pause monitoring on the old companion before moving its pairing to another device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .privacySensitive()
            .navigationTitle("Android pairing")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
