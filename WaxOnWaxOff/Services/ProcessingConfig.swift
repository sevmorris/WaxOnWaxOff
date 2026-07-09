import Foundation

/// Shared configuration constants for concurrent audio processing.
enum ProcessingConfig {
    /// Maximum number of concurrent ffmpeg jobs for WaxOn batch processing,
    /// scaled to available CPU. Formula: max(2, activeProcessorCount / 2) —
    /// at least 2 workers, up to half the active cores, leaving the
    /// remainder for the UI and OS.
    static var maxConcurrentJobs: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    /// Maximum number of concurrent WaxOff delivery jobs (and their deferred
    /// verification passes). Split from `maxConcurrentJobs` so the delivery
    /// cap can be tuned independently of WaxOn processing and of the
    /// load-time analysis gate; the initial value is identical.
    static var deliveryConcurrency: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    /// Maximum number of files analyzed simultaneously at load time (the
    /// `.ready` gate in FileQueueCoordinator). Split from
    /// `maxConcurrentJobs` for independent tuning; the initial value is
    /// identical.
    static var analysisConcurrency: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    /// Size of the verification pool that drains deferred output
    /// verifications concurrently with delivery. Fully independent of
    /// `deliveryConcurrency` — verification must never consume a delivery
    /// slot, but it may overlap delivery so deep batches don't serialize a
    /// verification tail after the last render.
    ///
    /// Width matters most when the delivery cap meets or exceeds the queue
    /// depth: every file then completes in a single wave, so ALL
    /// verifications arrive at once and the pool is the only parallelism
    /// available for the tail (a fixed pool of 3 measured a ~152 s tail on
    /// an 8-file batch with the machine 70% idle). cores ÷ 2 soaks up the
    /// idle cores after delivery drains; the cap of 6 bounds worst-case
    /// oversubscription while delivery is still active, and the floor of 3
    /// keeps small machines draining.
    static var verificationConcurrency: Int {
        min(6, max(3, ProcessInfo.processInfo.activeProcessorCount / 2))
    }
}

/// Runs `body` over each element in `inputs` with at most `limit` tasks executing concurrently.
/// Uses the addNext+drain pattern: starts up to `limit` tasks immediately, then adds the next
/// task each time one completes. A task that throws propagates the error and
/// `withThrowingTaskGroup` automatically cancels all remaining in-flight tasks — matching the
/// existing batch-cancellation semantics in `AudioProcessor` and `DeliveryProcessor`.
func runBoundedConcurrent<Input: Sendable, Output: Sendable>(
    inputs: [Input],
    limit: Int,
    body: @Sendable @escaping (Input) async throws -> Output
) async throws -> [Output] {
    guard !inputs.isEmpty else { return [] }
    let cap = max(1, min(limit, inputs.count))
    return try await withThrowingTaskGroup(of: Output.self) { group in
        var results: [Output] = []
        results.reserveCapacity(inputs.count)
        var index = 0
        func addNext() {
            guard index < inputs.count else { return }
            let input = inputs[index]
            index += 1
            group.addTask { try await body(input) }
        }
        for _ in 0..<cap { addNext() }
        for try await output in group {
            results.append(output)
            addNext()
        }
        return results
    }
}
