import XCTest
@testable import WaxOnWaxOff

/// An update waits while any window has a batch running, and each view model
/// reports its own through `isProcessing`.
final class BatchActivityTests: XCTestCase {

    func testRunsWhileAnyViewModelIsProcessing() {
        let waxOn = ContentViewModel()
        let waxOff = DeliveryViewModel()
        XCTAssertFalse(BatchActivity.isRunning)

        waxOn.isProcessing = true
        XCTAssertTrue(BatchActivity.isRunning)
        waxOff.isProcessing = true
        waxOn.isProcessing = false
        XCTAssertTrue(BatchActivity.isRunning, "the other window is still working")
        waxOff.isProcessing = false
        XCTAssertFalse(BatchActivity.isRunning)
    }
}
