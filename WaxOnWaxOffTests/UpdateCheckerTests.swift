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

/// `minimumMacOS(inReleaseNotes:)` and its helpers decide whether the update
/// check offers a release, from the marker release.sh writes into its notes.
/// A missing or malformed marker sets no minimum, so the release is offered as
/// it always was.
final class UpdateCheckerMinimumMacOSTests: XCTestCase {

    private func version(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    private func fields(_ version: OperatingSystemVersion?) -> [Int]? {
        version.map { [$0.majorVersion, $0.minorVersion, $0.patchVersion] }
    }

    /// The footer release.sh appends after the curated notes.
    func testReadsTheMarkerReleaseShWrites() {
        XCTAssertEqual(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "**Fixed**\n- Something.\n\n---\nRequires macOS 15.0 or later.\n<!-- minimum-macos: 15.0 -->")), [15, 0, 0])
        XCTAssertEqual(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15.2.1 -->")), [15, 2, 1])
        XCTAssertEqual(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 26 -->")), [26, 0, 0])
    }

    /// A release from before the marker runs on every macOS the installed build
    /// does, and the visible "Requires macOS" line is prose, not the marker.
    func testNotesWithoutAMarkerSetNoMinimum() {
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: nil))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "**Fixed**\n- Something."))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "Requires macOS 15.0 or later."))
    }

    func testAMalformedMarkerSetsNoMinimum() {
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: fifteen -->"))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15.0"))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15..0 -->"))
        XCTAssertNil(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 1.2.3.4 -->"))
    }

    func testComparesMajorThenMinorThenPatch() {
        XCTAssertFalse(UpdateChecker.runs(on: version(14, 6), given: version(15)))
        XCTAssertTrue(UpdateChecker.runs(on: version(15), given: version(15)))
        XCTAssertTrue(UpdateChecker.runs(on: version(26, 7, 1), given: version(15)))
        XCTAssertFalse(UpdateChecker.runs(on: version(15), given: version(15, 1)))
        XCTAssertTrue(UpdateChecker.runs(on: version(15, 1), given: version(15, 0, 1)))
    }

    func testDescribesAVersionTheWayMacOSDoes() {
        XCTAssertEqual(UpdateChecker.describe(version(15)), "15.0")
        XCTAssertEqual(UpdateChecker.describe(version(15, 2, 1)), "15.2.1")
    }
}
