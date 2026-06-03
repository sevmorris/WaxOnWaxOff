import Foundation

/// Shared configuration constants for concurrent audio processing.
enum ProcessingConfig {
    /// Maximum number of concurrent ffmpeg jobs, scaled to available CPU.
    /// Formula: max(2, activeProcessorCount / 2) — at least 2 workers, up to
    /// half the active cores, leaving the remainder for the UI and OS.
    static var maxConcurrentJobs: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
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
