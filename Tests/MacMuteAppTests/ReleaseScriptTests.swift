import Foundation
import XCTest

final class ReleaseScriptTests: XCTestCase {
    func testReleaseModeRejectsNonBooleanValue() throws {
        let result = try runScript(
            "Scripts/build_app.sh",
            environment: ["MACMUTE_RELEASE": "true"]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("MACMUTE_RELEASE must be exactly 0 or 1"))
    }

    func testReleaseAppRequiresExactTeamIdentifier() throws {
        let result = try runScript(
            "Scripts/build_app.sh",
            environment: ["MACMUTE_RELEASE": "1"]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("exact 10-character MACMUTE_TEAM_ID"))
    }

    func testReleaseDMGRequiresNotaryProfileBeforeBuilding() throws {
        let result = try runScript(
            "Scripts/build_dmg.sh",
            environment: [
                "MACMUTE_RELEASE": "1",
                "MACMUTE_TEAM_ID": "ABCDE12345"
            ]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("release builds require MACMUTE_NOTARY_PROFILE"))
    }

    private func runScript(
        _ relativePath: String,
        environment overrides: [String: String]
    ) throws -> (status: Int32, output: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = root.appendingPathComponent(relativePath)
        process.currentDirectoryURL = root
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }
}
