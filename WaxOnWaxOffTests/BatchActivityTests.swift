import XCTest
@testable import WaxOnWaxOff

/// An update waits while any window has a batch running, and each view model
/// reports its own through `isProcessing`.
final class BatchActivityTests: XCTestCase {

    /// Other tests in this process leave a view model flagged as they finish,
    /// so this holds on to nothing but its own and lets those go first.
    func testRunsWhileAnyViewModelIsProcessing() {
        let waxOn = ContentViewModel()
        let waxOff = DeliveryViewModel()

        waxOn.isProcessing = true
        XCTAssertTrue(BatchActivity.isRunning)
        waxOff.isProcessing = true
        waxOn.isProcessing = false
        XCTAssertTrue(BatchActivity.isRunning, "the other window is still working")
        waxOff.isProcessing = false
        XCTAssertFalse(BatchActivity.isRunning)
    }

    /// A window that goes away with its flag set must not hold up an update
    /// until the next launch.
    func testAnOwnerThatGoesAwayStopsCounting() {
        autoreleasepool {
            let owner = NSObject()
            BatchActivity.set(owner, running: true)
            XCTAssertTrue(BatchActivity.isRunning)
        }
        XCTAssertFalse(BatchActivity.isRunning)
    }
}
