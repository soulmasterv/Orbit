import SwiftUI
import UIKit
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

enum OrbitWhatsAppMediaKind: String, Codable, Sendable { case image, video, document }

struct OrbitWhatsAppAttachment: Decodable, Identifiable {
    let id: String
    let kind: OrbitWhatsAppMediaKind
    let name: String
    let mime: String
    let size: Int?
    let state: String
    let thumbnail: String?
    var sizeLabel: String { size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Size unavailable" }
}

struct OrbitWhatsAppMediaDraft: Identifiable, Sendable {
    static let limit = 25 * 1024 * 1024
    let id: String
    let url: URL
    let kind: OrbitWhatsAppMediaKind
    let name: String
    let mime: String
    let size: Int
    let thumbnail: String?
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("orbit-whatsapp-media", isDirectory: true) }
    static func copy(_ url: URL, name: String? = nil, kind: OrbitWhatsAppMediaKind = .document, mime: String? = nil) throws -> Self {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= limit else { throw APIError.message("Choose a file up to 25 MB.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString.lowercased()
        let filename = String((name ?? url.lastPathComponent).replacingOccurrences(of: "/", with: "_").prefix(120))
        let originalExtension = (filename as NSString).pathExtension
        let suggestedExtension = originalExtension.isEmpty ? (mime.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "") : originalExtension
        let ext = String(suggestedExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(10))
        let target = directory.appendingPathComponent(id + (ext.isEmpty ? "" : "." + ext))
        do {
            try FileManager.default.copyItem(at: url, to: target)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
        } catch { remove(target); throw error }
        let thumbnail: String?
        if kind == .image { thumbnail = CGImageSourceCreateWithURL(target as CFURL, nil).flatMap { source in
            CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceThumbnailMaxPixelSize:128, kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary)
        }.flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.55) }.flatMap { $0.count <= 4000 ? $0.base64EncodedString() : nil } }
        else if kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: target))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 128, height: 128)
            thumbnail = (try? generator.copyCGImage(at: .zero, actualTime: nil)).flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.55) }.flatMap { $0.count <= 4000 ? $0.base64EncodedString() : nil }
        } else { thumbnail = nil }
        return Self(id: id, url: target, kind: kind, name: filename, mime: mime ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream", size: size, thumbnail: thumbnail)
    }
    static func photo(_ url: URL) throws -> Self {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceThumbnailMaxPixelSize:2048, kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary),
              let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.88), data.count <= limit else { throw APIError.message("This photo could not be prepared.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".jpg")
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
        defer { remove(temporary) }
        return try copy(temporary, name: "Photo.jpg", kind: .image, mime: "image/jpeg")
    }
    static func video(_ url: URL) async throws -> Self {
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPreset1280x720) else { throw APIError.message("This video could not be prepared.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { remove(temporary) }
        export.outputURL = temporary; export.outputFileType = .mp4; export.shouldOptimizeForNetworkUse = true; export.metadata = []
        await export.export()
        try Task.checkCancellation()
        guard export.status == .completed else { throw APIError.message("This video could not be converted to MP4.") }
        return try copy(temporary, name: "Video.mp4", kind: .video, mime: "video/mp4")
    }
    static func remove(_ url: URL) {
        guard url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
    static func thumbnailImage(_ value: String?) -> UIImage? {
        guard let value, let data = Data(base64Encoded: value), data.count <= 4000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceThumbnailMaxPixelSize:256] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct OrbitWhatsAppPickedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { file in
            Self(url: try OrbitWhatsAppMediaDraft.copy(file.file).url)
        }
    }
}

struct WhatsAppAttachmentCard: View {
    let attachment: OrbitWhatsAppAttachment
    var loading = false
    let open: () -> Void
    private var icon: String { attachment.kind == .image ? "photo" : attachment.kind == .video ? "play.rectangle.fill" : "doc.fill" }
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                if let image = OrbitWhatsAppMediaDraft.thumbnailImage(attachment.thumbnail) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.title2).frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attachment.name).font(.subheadline.weight(.medium)).lineLimit(2)
                        Text(attachment.state == "too_large" ? "Over 25 MB" : attachment.state == "unavailable" ? "Unavailable" : attachment.sizeLabel).font(.caption2).foregroundStyle(WhatsAppPalette.muted)
                    }
                    Spacer(minLength: 4)
                    if loading { ProgressView() }
                    else { Image(systemName: "arrow.down.circle").font(.title3) }
                }
            }.padding(10).frame(minWidth: 190, maxWidth: 260, alignment: .leading)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(loading || attachment.state != "available")
            .accessibilityLabel("Open \(attachment.name), \(attachment.sizeLabel)")
    }
}
