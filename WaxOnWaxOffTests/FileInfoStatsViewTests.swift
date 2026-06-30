import XCTest
@testable import WaxOnWaxOff

/// Covers `FileInfoStatsView.floorSeverity`, the pure classifier behind the FLOOR
/// stat's warning/critical coloring. WaxOn flags a high noise floor; WaxOff (finished
/// delivery mixes) shows the value but never flags it.
final class FileInfoStatsViewTests: XCTestCase {

    // MARK: WaxOn — warnings applied

    func testWaxOnCriticalAboveMinus40() {
        XCTAssertEqual(FileInfoStatsView.floorSeverity(dBFS: -35, applyWarnings: true), .critical)
        XCTAssertEqual(FileInfoStatsView.floorSeverity(dBFS: -10, applyWarnings: true), .critical)
    }

    func testWaxOnWarningBetweenMinus50AndMinus40() {
        XCTAssertEqual(FileInfoStatsView.floorSeverity(dBFS: -45, applyWarnings: true), .warning)
        // Boundary: −40 is not critical (uses strict >), but is still a warning.
        XCTAssertEqual(FileInfoStatsView.floorSeverity(dBFS: -40, applyWarnings: true), .warning)
    }

    func testWaxOnNormalAtOrBelowMinus50() {
        XCTAssertEqual(FileInfoStatsView.floorSeverity(dBFS: -55, applyWarnings: true), .normal)
        // Boundary: −50 is not a warning (strict >).
        XCTAssertEqual(FileInfoStatsView.floorSeverity(dBFS: -50, applyWarnings: true), .normal)
    }

    // MARK: WaxOff — warnings suppressed

    func testWaxOffNeverFlagsRegardlessOfLevel() {
        XCTAssertEqual(FileInfoStatsView.floorSeverity(dBFS: -10, applyWarnings: false), .normal)
        XCTAssertEqual(FileInfoStatsView.floorSeverity(dBFS: -35, applyWarnings: false), .normal)
        XCTAssertEqual(FileInfoStatsView.floorSeverity(dBFS: -45, applyWarnings: false), .normal)
        XCTAssertEqual(FileInfoStatsView.floorSeverity(dBFS: -90, applyWarnings: false), .normal)
    }

    // MARK: File-list noise-floor badge

    /// The file-list warning triangle fires when `floorSeverity(...) != .normal` — the
    /// same classifier as the stats panel. In WaxOn it fires above −50 dBFS (warning or
    /// critical); a clean floor shows no badge.
    func testFileListBadgeFiresInWaxOnAboveMinus50() {
        XCTAssertNotEqual(FileInfoStatsView.floorSeverity(dBFS: -30, applyWarnings: true), .normal)  // critical → badge
        XCTAssertNotEqual(FileInfoStatsView.floorSeverity(dBFS: -45, applyWarnings: true), .normal)  // warning → badge
        XCTAssertEqual(FileInfoStatsView.floorSeverity(dBFS: -55, applyWarnings: true), .normal)     // clean → no badge
    }

    /// In WaxOff the badge never fires, even for a high floor — a finished mix may
    /// legitimately carry continuous low-level content.
    func testFileListBadgeNeverFiresInWaxOff() {
        XCTAssertEqual(FileInfoStatsView.floorSeverity(dBFS: -30, applyWarnings: false), .normal)    // no badge
        XCTAssertEqual(FileInfoStatsView.floorSeverity(dBFS: -45, applyWarnings: false), .normal)    // no badge
    }
}
