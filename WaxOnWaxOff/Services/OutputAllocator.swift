import Foundation

/// Collision-safe output path allocator for a single processing batch.
/// Each call to `allocate(for:in:)` claims a path unique within this instance.
///
/// The caller supplies a `computeBaseName` closure that maps an input URL to the
/// desired output filename (e.g. `"interview-44kwaxon.wav"` for WaxOn or
/// `"interview-lev-18LUFS.wav"` for WaxOff). On collision, the allocator inserts
/// a short path-hash tag between the input stem and the type suffix, with a UUID
/// fragment as a second-level fallback — identical to the previous inline logic
/// in `AudioProcessor.allocateWaxOnOutput` and `DeliveryProcessor.allocateOutputStem`.
///
/// Marked `@unchecked Sendable` because it is used exclusively from within
/// actor-isolated code; the actor's serial executor provides the necessary
/// serialization of `allocate(for:in:)` calls.
final class OutputAllocator: @unchecked Sendable {
    // nonisolated(unsafe): both fields are accessed exclusively from actor-isolated code;
    // the actor's serial executor provides serialization, making direct access safe.
    private nonisolated(unsafe) var reserved: Set<String> = []
    private nonisolated(unsafe) let computeBaseName: (URL) -> String

    /// - Parameter computeBaseName: Maps an input URL to a candidate output filename.
    ///   Should follow the pattern `stem-typeSuffix[.ext]` so the allocator can
    ///   correctly insert disambiguation tags between the stem and the type suffix.
    nonisolated init(computeBaseName: @escaping (URL) -> String) {
        self.computeBaseName = computeBaseName
    }

    // nonisolated: under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the implicit
    // deinit would be MainActor-isolated even though every other member is
    // nonisolated, and macOS 15's isolated-deinit runtime malloc-aborts in
    // task-local scope teardown when the last release happens off-task — this
    // allocator is created per batch and released from within actor-isolated
    // processing. Stored properties need no isolated teardown, so opt out.
    nonisolated deinit {}

    /// Returns a unique output URL inside `directory` for the given `input`.
    /// The first call with a given base name claims it; subsequent calls for the
    /// same base name receive a tag-disambiguated variant.
    nonisolated func allocate(for input: URL, in directory: URL) -> URL {
        let baseName = computeBaseName(input)
        let baseURL = directory.appendingPathComponent(baseName)

        if !reserved.contains(baseURL.path) {
            reserved.insert(baseURL.path)
            return baseURL
        }

        // Collision: insert a path-hash tag between the input stem and the type
        // suffix to produce e.g. "interview-a1b2c3-44kwaxon.wav".
        let inputStem = input.deletingPathExtension().lastPathComponent
        let noExt = (baseName as NSString).deletingPathExtension
        let ext = (baseName as NSString).pathExtension
        let extStr = ext.isEmpty ? "" : ".\(ext)"
        // typeSuffix is everything after "inputStem-" in the extension-stripped base name.
        let prefixToStrip = inputStem + "-"
        let typeSuffix = noExt.hasPrefix(prefixToStrip)
            ? String(noExt.dropFirst(prefixToStrip.count))
            : noExt

        let tag = OutputNaming.shortPathTag(for: input.path)
        var taggedName = "\(inputStem)-\(tag)-\(typeSuffix)\(extStr)"
        var taggedURL = directory.appendingPathComponent(taggedName)
        if reserved.contains(taggedURL.path) {
            let uuidPart = UUID().uuidString.prefix(4)
            taggedName = "\(inputStem)-\(tag)-\(uuidPart)-\(typeSuffix)\(extStr)"
            taggedURL = directory.appendingPathComponent(taggedName)
        }
        reserved.insert(taggedURL.path)
        return taggedURL
    }
}
