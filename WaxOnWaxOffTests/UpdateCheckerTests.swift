import XCTest
@testable import WaxOnWaxOff

/// Unit tests for `UpdateChecker`'s non-200 response classification. The networking
/// itself isn't exercised — `responseError(statusCode:body:)` is pure, so the
/// rate-limit-vs-connectivity decision can be tested with stub response bodies.
final class UpdateCheckerTests: XCTestCase {

    /// A 403 carrying GitHub's primary rate-limit body must surface a rate-limit
    /// error, not the generic "check your internet connection" failure.
    func testPrimaryRateLimit403SurfacesRateLimitError() throws {
        let body = Data(#"""
        {"message":"API rate limit exceeded for 203.0.113.5. (But here's the good news: Authenticated requests get a higher rate limit. Check out the documentation for more details.)","documentation_url":"https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"}
        """#.utf8)

        let message = try XCTUnwrap(UpdateChecker.responseError(statusCode: 403, body: body).errorDescription)
        XCTAssertNotNil(message.range(of: "rate limit", options: .caseInsensitive),
                        "403 rate-limit response should surface a rate-limit message, got: \(message)")
        XCTAssertNil(message.range(of: "internet connection", options: .caseInsensitive),
                     "rate-limit response must not be reported as a connectivity failure")
    }

    /// Secondary/abuse rate limits also use 403 with a "secondary rate limit" message.
    func testSecondaryRateLimit403SurfacesRateLimitError() throws {
        let body = Data(#"{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}"#.utf8)
        let message = try XCTUnwrap(UpdateChecker.responseError(statusCode: 403, body: body).errorDescription)
        XCTAssertNotNil(message.range(of: "rate limit", options: .caseInsensitive))
    }

    /// A 403 that is genuinely not a rate limit (e.g. plain "Forbidden") still maps to
    /// the connectivity failure — we only special-case the rate-limit message.
    func testForbidden403WithoutRateLimitBodyIsConnectivityFailure() throws {
        let body = Data(#"{"message":"Forbidden"}"#.utf8)
        let message = try XCTUnwrap(UpdateChecker.responseError(statusCode: 403, body: body).errorDescription)
        XCTAssertNil(message.range(of: "rate limit", options: .caseInsensitive))
        XCTAssertNotNil(message.range(of: "internet connection", options: .caseInsensitive))
    }

    /// Other non-200s (server errors, empty bodies) remain connectivity failures.
    func testServerErrorIsConnectivityFailure() throws {
        let message = try XCTUnwrap(UpdateChecker.responseError(statusCode: 500, body: Data()).errorDescription)
        XCTAssertNil(message.range(of: "rate limit", options: .caseInsensitive))
        XCTAssertNotNil(message.range(of: "internet connection", options: .caseInsensitive))
    }
}
