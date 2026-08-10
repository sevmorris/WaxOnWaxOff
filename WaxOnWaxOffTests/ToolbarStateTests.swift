import XCTest
@testable import WaxOnWaxOff

/// The toolbar's state machine, and the two rules the view used to enforce by
/// hand: which controls appear, and when the file list may be edited.
///
/// Before `toolbarState` existed the view walked `isRestarting` / `isProcessing`
/// / `isVerifying` itself. That left "Process is offered exactly when the model
/// would start a batch" as a coincidence between two pieces of code rather than
/// a stated rule — and it had already drifted, since `canStartNewBatch` read
/// true during a restart while `process()` refused.
@MainActor
final class ToolbarStateTests: XCTestCase {

    /// `.restarting` is deliberately absent: `isRestarting` is `private(set)`,
    /// so it cannot be posed here. It is covered against a real batch in
    /// `DeliveryViewModelRestartWindowTests`.
    private func viewModel(processing: Bool, verifying: Bool) -> DeliveryViewModel {
        let vm = DeliveryViewModel()
        vm.isProcessing = processing
        vm.isVerifying = verifying
        return vm
    }

    // MARK: - State selection

    func testIdle() {
        XCTAssertEqual(viewModel(processing: false, verifying: false).toolbarState, .idle)
    }

    func testDelivering() {
        XCTAssertEqual(viewModel(processing: true, verifying: false).toolbarState, .delivering)
    }

    func testVerifying() {
        XCTAssertEqual(viewModel(processing: true, verifying: true).toolbarState, .verifying)
    }

    /// `isVerifying` without `isProcessing` is not a state the model produces —
    /// the tail is a phase of a running batch. Pinned so that if it ever occurs
    /// it reads as idle rather than as a tail with no batch behind it.
    func testVerifyingWithoutProcessingReadsAsIdle() {
        XCTAssertEqual(viewModel(processing: false, verifying: true).toolbarState, .idle)
    }

    // MARK: - The rule the view used to enforce by hand

    /// Process is offered exactly when `process()` would start a batch.
    ///
    /// The expected column is written out rather than derived, so that a change
    /// to `canStartNewBatch` has to be argued for here instead of silently
    /// agreeing with itself.
    func testProcessIsOfferedExactlyWhenABatchWouldStart() {
        let cases: [(processing: Bool, verifying: Bool, state: DeliveryViewModel.ToolbarState, offersProcess: Bool)] = [
            (false, false, .idle,       true),
            (true,  false, .delivering, false),
            (true,  true,  .verifying,  true)
        ]
        for c in cases {
            let vm = viewModel(processing: c.processing, verifying: c.verifying)
            XCTAssertEqual(vm.toolbarState, c.state,
                           "isProcessing=\(c.processing) isVerifying=\(c.verifying)")
            XCTAssertEqual(vm.canStartNewBatch, c.offersProcess,
                           "\(c.state) must agree with whether the toolbar offers Process")
        }
    }

    // MARK: - File-list editing

    func testFileListEditableWhenIdle() {
        XCTAssertTrue(viewModel(processing: false, verifying: false).canEditFileList)
    }

    /// The guard that matters. The batch runs from a snapshot taken at Process,
    /// so clearing the list here stops nothing — it only removes the rows the
    /// completion callbacks were going to write into.
    func testFileListNotEditableWhileDelivering() {
        XCTAssertFalse(viewModel(processing: true, verifying: false).canEditFileList,
                       "editing during delivery orphans the batch's UI state without stopping it")
    }

    /// Editable on purpose. Refusing here would contradict letting a new batch
    /// start during the same window.
    func testFileListEditableDuringVerification() {
        XCTAssertTrue(viewModel(processing: true, verifying: true).canEditFileList,
                      "the tail's files are already on disk")
    }

    // MARK: - WaxOn symmetry

    /// WaxOn has no tail, so the rule is the simpler half of WaxOff's.
    func testWaxOnFileListFollowsProcessing() {
        let vm = ContentViewModel()
        vm.isProcessing = false
        XCTAssertTrue(vm.canEditFileList)
        vm.isProcessing = true
        XCTAssertFalse(vm.canEditFileList)
    }
}
