import XCTest
@testable import WaxOnWaxOff

/// Exercises the cross-volume branch of `FileManager.moveAtomically` (copy → rename
/// → source cleanup). Same-volume moves are already covered implicitly by the
/// processing integration tests; the cross-volume path only runs when source and
/// destination live on different volumes, which this test forces with a throwaway
/// RAM-disk volume. Skips cleanly where a RAM disk can't be created (e.g. a CI
/// sandbox without `hdiutil`/`diskutil` privileges).
final class MoveAtomicallyTests: XCTestCase {

    func testMoveAtomicallyAcrossVolumes() throws {
        let ram = try makeRAMDiskOrSkip()
        defer { detachRAMDisk(ram.device) }

        // Source on the boot volume's temp area.
        let srcDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waxon-mv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: srcDir) }

        let source = srcDir.appendingPathComponent("payload.bin")
        let payload = Data((0..<4096).map { UInt8($0 & 0xFF) })
        try payload.write(to: source)

        let destination = ram.mountPoint.appendingPathComponent("delivered.bin")

        // Guard: confirm source and destination really are on different volumes, so
        // this test exercises the cross-volume branch rather than silently passing
        // through the same-volume rename.
        guard let srcVol = try source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let dstVol = try ram.mountPoint.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            throw XCTSkip("Could not resolve volume identifiers; cannot confirm the cross-volume branch.")
        }
        try XCTSkipIf((srcVol as AnyObject).isEqual(dstVol as AnyObject),
                      "Source and RAM disk resolved to the same volume; cross-volume branch not exercised.")

        try FileManager.moveAtomically(at: source, to: destination)

        // Destination has the exact bytes; source is gone after the copy.
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "cross-volume move should remove the source after copying")

        // The hidden `.<UUID>.bin` staging temp must have been renamed into place,
        // not left behind — the only `.bin` on the volume is the delivered file.
        let binFiles = try FileManager.default.contentsOfDirectory(atPath: ram.mountPoint.path)
            .filter { $0.hasSuffix(".bin") }
            .sorted()
        XCTAssertEqual(binFiles, ["delivered.bin"],
                       "cross-volume move left a staging temp behind: \(binFiles)")
    }

    // MARK: - RAM disk helpers

    private func makeRAMDiskOrSkip() throws -> (mountPoint: URL, device: String) {
        // 32768 × 512-byte sectors = 16 MB — ample for an HFS+ volume and a few files.
        let attachOutput: String
        do {
            attachOutput = try runProcess("/usr/bin/hdiutil", ["attach", "-nomount", "ram://32768"])
        } catch {
            throw XCTSkip("Could not attach a RAM disk via hdiutil: \(error.localizedDescription)")
        }
        guard let device = attachOutput
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .first.map(String.init), device.hasPrefix("/dev/") else {
            throw XCTSkip("hdiutil returned an unexpected device string: \(attachOutput)")
        }

        let volumeName = "WaxOnRAM-\(UUID().uuidString.prefix(8))"
        do {
            _ = try runProcess("/usr/sbin/diskutil", ["erasevolume", "HFS+", volumeName, device])
        } catch {
            detachRAMDisk(device)
            throw XCTSkip("Could not format the RAM disk: \(error.localizedDescription)")
        }

        let mountPoint = URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: mountPoint.path) else {
            detachRAMDisk(device)
            throw XCTSkip("RAM disk did not mount at \(mountPoint.path).")
        }
        return (mountPoint, device)
    }

    private func detachRAMDisk(_ device: String) {
        _ = try? runProcess("/usr/bin/hdiutil", ["detach", device, "-force"])
    }

    @discardableResult
    private func runProcess(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "runProcess", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(launchPath) exited \(process.terminationStatus): \(stderr)"
            ])
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
