import XCTest
import SwiftUI
@testable import Orbit

@MainActor
final class DownloadsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() async throws {
        suite = "Orbit.Downloads.\(UUID())"; defaults = UserDefaults(suiteName: suite)!
        MockURLProtocol.requests = []; MockURLProtocol.onStart = nil
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.handler = nil; MockURLProtocol.onStart = nil
    }
    private func api(token: String = "owner-fixture") -> ServerAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ServerAPI(session: URLSession(configuration: config), defaults: defaults,
                         tokenProvider: { token }, authorize: { _ in XCTFail("Read-only files cannot authorize a mutation") })
    }
    private func response(_ request: URLRequest, status: Int = 200, data: Data) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
    }
    func testListingUsesOwnerGetAndDecodesFoldersAndFiles() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/downloads")
            XCTAssertEqual(request.url?.query, "folder=MTJG")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-fixture")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
            return self.response(request, data: Data(#"{"version":1,"truncated":false,"items":[{"id":"ZmlsZQ","name":"Daily.pdf","kind":"file","size":10,"modified_at":1793000000}]}"#.utf8))
        }
        let result = try await api().downloads(folder: "MTJG")
        XCTAssertTrue(result.valid); XCTAssertEqual(result.items.first?.name, "Daily.pdf")
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }
    func testFileGetUsesNativeOwnerAuthAndReturnsBytesOnce() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/downloads/files/ZmlsZQ")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-fixture")
            return self.response(request, data: Data("%PDF-fixture".utf8))
        }
        let data = try await api().downloadFile(id: "ZmlsZQ")
        XCTAssertEqual(data, Data("%PDF-fixture".utf8)); XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }
    func testAuthenticationMissingEndpointAndRemovedFileAreDistinct() async {
        for (status, expected) in [(401, OrbitDownloadsError.authentication), (503, .unavailable), (404, .notFound)] {
            MockURLProtocol.handler = { request in self.response(request, status: status, data: Data("private upstream body".utf8)) }
            do { _ = try await api().downloadFile(id: "ZmlsZQ"); XCTFail("Expected rejection") }
            catch { XCTAssertEqual((error as? OrbitDownloadsError)?.message, expected.message) }
        }
    }
    func testInvalidIdentifiersAndMissingCredentialsNeverRequest() async {
        MockURLProtocol.handler = { _ in XCTFail("Must reject locally"); throw URLError(.cancelled) }
        for id in ["", "../secret", "x?token=secret", String(repeating: "a", count: 4097)] {
            do { _ = try await api().downloadFile(id: id); XCTFail("Expected invalid identifier") } catch {}
        }
        do { _ = try await api(token: "").downloads(); XCTFail("Expected authentication") } catch {}
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }
    func testMalformedListingAndNetworkFailureNeverBecomeSampleData() async {
        MockURLProtocol.handler = { request in self.response(request, data: Data(#"{"version":1,"truncated":false,"items":[{"id":"../secret","name":"secret","kind":"file","size":1,"modified_at":0}]}"#.utf8)) }
        do { _ = try await api().downloads(); XCTFail("Expected invalid response") } catch {}
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let before = MockURLProtocol.requests.count
        do { _ = try await api().downloads(); XCTFail("Expected network error") } catch {}
        XCTAssertEqual(MockURLProtocol.requests.count, before + 1)
    }
    func testReadOnlyPDFPreviewOnIPhone() async throws {
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 560)).pdfData { context in
            context.beginPage()
            ("Classera 12F — fixture daily report" as NSString).draw(at: CGPoint(x: 24, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        MockURLProtocol.handler = { request in self.response(request, data: pdf) }
        let item = try JSONDecoder().decode(OrbitDownloadItem.self, from: Data(#"{"id":"ZmlsZQ","name":"Daily report.pdf","kind":"file","size":1000,"modified_at":1793000000}"#.utf8))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: NavigationStack { DownloadPreviewView(api: api(), item: item) }.preferredColorScheme(.dark))
        window.makeKeyAndVisible(); defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "downloads-pdf-preview"
        attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }
}
