import Foundation
import XCTest
@testable import FootballPerformanceWatch

final class WatchSessionRepositoryRecoveryTests: XCTestCase {
    func testHeaderOnlyPartialCanBeQuarantinedWithoutRepeatingRecoveryError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSessionRepositoryRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try WatchSessionRepository(sessionsDirectory: directory)
        let filename = "orphan.partial"
        let partialURL = directory.appendingPathComponent(filename)
        XCTAssertTrue(FileManager.default.createFile(atPath: partialURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: partialURL)
        try FootySessionPackageV1.writeHeader(to: handle)
        try handle.close()

        do {
            _ = try await repository.recoverPartial(named: filename)
            XCTFail("A partial without an envelope must not be presented as a recovered session")
        } catch let error as SessionPackageError {
            XCTAssertEqual(error, .missingSessionEnvelope)
        }

        let quarantinedFilename = try await repository.quarantinePartial(named: filename)
        let quarantinedURL = directory
            .appendingPathComponent("Quarantine", isDirectory: true)
            .appendingPathComponent(quarantinedFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path))
        let remainingPackages = try await repository.discover()
        XCTAssertTrue(remainingPackages.isEmpty)
    }
}
