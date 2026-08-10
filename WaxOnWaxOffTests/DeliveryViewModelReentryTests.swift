import XCTest
@testable import WaxOnWaxOff

/// The re-entry gate that decides whether `process()` starts a batch or returns.
///
/// Asserted through `canStartNewBatch` rather than by driving a real batch: the
/// verification tail is a timing window, and asserting against it directly is
/// the trap the #24 boundary test hit. The decision is pure state, so it can be
/// pinned exactly.
@MainActor
final class DeliveryViewModelReentryTests: XCTestCase {

    func testIdleStarts() {
        let vm = DeliveryViewModel()
        vm.isProcessing = false
        vm.isVerifying = false
        XCTAssertTrue(vm.canStartNewBatch, "an idle view model must start")
    }

    /// The gate. A drop-and-start during active delivery would abandon renders
    /// in progress — unlike the tail, where every file is already written.
    func testActiveDeliveryDoesNotStart() {
        let vm = DeliveryViewModel()
        vm.isProcessing = true
        vm.isVerifying = false
        XCTAssertFalse(vm.canStartNewBatch,
                       "a batch that is still delivering must not be restartable")
    }

    /// The window this change opens: delivery finished, only the advisory
    /// re-measurement outstanding.
    func testVerificationTailStarts() {
        let vm = DeliveryViewModel()
        vm.isProcessing = true
        vm.isVerifying = true
        XCTAssertTrue(vm.canStartNewBatch,
                      "the verification tail must be restartable")
    }

    /// Delivered rows are `.processed`, and the batch only ever takes `.ready`
    /// rows — so a restart cannot pick up the previous batch's files. Pins that
    /// the two statuses are distinct and that `.processed` is not `.ready`.
    func testProcessedRowsAreNotReady() {
        let processed = FileStatus.processed(outputURL: URL(fileURLWithPath: "/tmp/out.wav"))
        if case .ready = processed {
            XCTFail("a delivered row must not read as .ready, or a restart would reprocess it")
        }
    }
}
