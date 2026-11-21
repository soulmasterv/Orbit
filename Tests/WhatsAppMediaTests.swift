import XCTest
import UIKit
@testable import Orbit

@MainActor
final class WhatsAppMediaTests: XCTestCase {
    func testPhotosArePreparedAsBoundedJPEGWithThumbnail() throws {
        try FileManager.default.createDirectory(at: OrbitWhatsAppMediaDraft.directory, withIntermediateDirectories: true)
        let source = OrbitWhatsAppMediaDraft.directory.appendingPathComponent(UUID().uuidString + ".png")
        defer { OrbitWhatsAppMediaDraft.remove(source) }
        let data = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try data.write(to: source)
        let draft = try OrbitWhatsAppMediaDraft.photo(source)
        defer { OrbitWhatsAppMediaDraft.remove(draft.url) }
        XCTAssertEqual(draft.kind, .image)
        XCTAssertEqual(draft.mime, "image/jpeg")
        XCTAssertEqual(draft.url.pathExtension, "jpg")
        XCTAssertTrue(draft.size > 0 && draft.size <= OrbitWhatsAppMediaDraft.limit)
        XCTAssertNotNil(OrbitWhatsAppMediaDraft.thumbnailImage(draft.thumbnail))
    }
    func testInvalidVideoFailsWithoutProducingAnAttachment() async throws {
        try FileManager.default.createDirectory(at: OrbitWhatsAppMediaDraft.directory, withIntermediateDirectories: true)
        let source = OrbitWhatsAppMediaDraft.directory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { OrbitWhatsAppMediaDraft.remove(source) }
        try Data("not a video".utf8).write(to: source)
        do { let draft = try await OrbitWhatsAppMediaDraft.video(source); OrbitWhatsAppMediaDraft.remove(draft.url); XCTFail("Invalid video was accepted") }
        catch { /* No upload or send was attempted. */ }
    }
    func testOlderTextOnlyResponsesStillDecode() throws {
        let response = try JSONDecoder().decode(OrbitWhatsAppMessages.self, from: Data(#"{"connected":true,"messages":[{"id":"fixture","chat":"201000000001","text":"Fixture","outgoing":false,"at":1700000000,"status":"received"}]}"#.utf8))
        XCTAssertNil(response.messages.first?.media)
    }
    func testUnknownMediaSizeIsNotDisplayedAsZero() throws {
        let response = try JSONDecoder().decode(OrbitWhatsAppAttachment.self, from: Data(#"{"id":"11111111-1111-4111-8111-111111111111","kind":"document","name":"Fixture.pdf","mime":"application/pdf","size":null,"state":"available"}"#.utf8))
        XCTAssertNil(response.size)
        XCTAssertEqual(response.sizeLabel, "Size unavailable")
    }
    func testMediaRequestIDRemainsStableAfterUncertainSend() async throws {
        let model = OrbitWhatsAppSubmission()
        let id = UUID().uuidString.lowercased()
        var calls = 0
        await model.submit(phone: "201000000001", text: "Fixture caption", mediaID: id) { request in
            calls += 1
            XCTAssertEqual(request.media_id, id)
            throw URLError(.timedOut)
        }
        let first = model.pending?.request_id
        await model.submit(phone: "201000000001", text: "Fixture caption", mediaID: id) { _ in calls += 1; throw URLError(.timedOut) }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.pending?.request_id, first)
        XCTAssertEqual(model.pending?.media_id, id)
    }
    func testSelectedFilesAreCopiedPrivatelyAndSizeLimited() throws {
        try FileManager.default.createDirectory(at: OrbitWhatsAppMediaDraft.directory, withIntermediateDirectories: true)
        let original = OrbitWhatsAppMediaDraft.directory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { OrbitWhatsAppMediaDraft.remove(original) }
        try Data("fixture document".utf8).write(to: original)
        let draft = try OrbitWhatsAppMediaDraft.copy(original, name: "Fixture.pdf")
        defer { OrbitWhatsAppMediaDraft.remove(draft.url) }
        XCTAssertNotEqual(draft.url, original)
        XCTAssertEqual(draft.size, 16)
        XCTAssertEqual(draft.kind, .document)
        XCTAssertEqual(draft.mime, "application/pdf")
        XCTAssertThrowsError(try OrbitWhatsAppMediaDraft.copy(OrbitWhatsAppMediaDraft.directory))
        let huge = OrbitWhatsAppMediaDraft.directory.appendingPathComponent(UUID().uuidString + ".bin")
        defer { OrbitWhatsAppMediaDraft.remove(huge) }
        try Data(count: OrbitWhatsAppMediaDraft.limit + 1).write(to: huge)
        XCTAssertThrowsError(try OrbitWhatsAppMediaDraft.copy(huge))
    }
    func testUploadUsesOwnerAuthenticationAndDoesNotSendAMessage() async throws {
        let suite = "WhatsAppMediaTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockURLProtocol.self]
        let api = ServerAPI(session: URLSession(configuration: configuration), defaults: defaults, tokenProvider: { "fixture-owner" }, authorize: { _ in })
        try FileManager.default.createDirectory(at: OrbitWhatsAppMediaDraft.directory, withIntermediateDirectories: true)
        let source = OrbitWhatsAppMediaDraft.directory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { OrbitWhatsAppMediaDraft.remove(source) }
        try Data("fixture document".utf8).write(to: source)
        let draft = try OrbitWhatsAppMediaDraft.copy(source, name: "Fixture.pdf")
        defer { OrbitWhatsAppMediaDraft.remove(draft.url) }
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-owner")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            XCTAssertFalse(request.url!.absoluteString.contains("Fixture.pdf"))
            XCTAssertEqual(request.url?.path, "/api/jarvis/whatsapp/media/" + draft.id)
            return (200, try JSONSerialization.data(withJSONObject: ["id":draft.id,"kind":"document","name":"Fixture.pdf","mime":"application/pdf","size":draft.size,"state":"available"]))
        }
        let result = try await api.uploadWhatsAppAttachment(draft)
        XCTAssertEqual(result.id, draft.id)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.httpMethod == "POST" })
    }
}
