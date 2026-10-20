import Foundation
import XCTest
@testable import AFKCore

private final class ResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let body = path == "small" ? Data("{\"ok\":true}".utf8) : Data(repeating: 32, count: 65537)
        let headers = path == "declared" ? ["Content-Length": "65537"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class RelayResponseTests: XCTestCase {
    func testHTTPResponsesAreBoundedWithAndWithoutContentLength() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponseProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = RelayClient(session: session)
        let base = URL(string: "https://relay.invalid")!
        let small: [String: Bool] = try await client.request(base, path: "small")
        XCTAssertEqual(small["ok"], true)
        for path in ["declared", "streamed"] {
            do {
                let _: [String: Bool] = try await client.request(base, path: path)
                XCTFail("Oversized response accepted")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
            }
        }
    }
}
