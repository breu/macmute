import Foundation
import XCTest

final class ReleaseScriptTests: XCTestCase {
    func testCoverageGateCountsOnlyProductSourcesAndEnforcesExactFloor() throws {
        let report = """
        {"data":[{"files":[
          {"filename":"/repo/Sources/MacMuteApp/One.swift","summary":{"lines":{"count":8,"covered":4}}},
          {"filename":"/repo/Sources/MacMuteApp/MicMuteController.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Sources/MacMuteApp/HotkeyManager.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Sources/MacMuteApp/LaunchAtLoginManager.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Sources/MacMuteApp/PushToTalkController.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Sources/MacMuteApp/ClickSoundPlayer.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Sources/MacMuteApp/PreferencesWindow.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Sources/MacMuteApp/StatusBarController.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Tests/MacMuteAppTests/OneTests.swift","summary":{"lines":{"count":100,"covered":100}}}
        ]}]}
        """
        let accepted = try runCoverageGate(report: report, minimum: "73.33")
        XCTAssertEqual(accepted.status, 0, accepted.output)
        XCTAssertTrue(accepted.output.contains("73.33% (11/15 lines)"))

        let rejected = try runCoverageGate(report: report, minimum: "73.34")
        XCTAssertNotEqual(rejected.status, 0)
        XCTAssertTrue(rejected.output.contains("below the 73.34% release floor"))
    }

    func testCoverageGateFailsClosedWhenReportContainsNoProductSources() throws {
        let result = try runCoverageGate(
            report: "{\"data\":[{\"files\":[]}]}",
            minimum: "0"
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("contains no MacMute source lines"))
    }

    func testCoverageGateEnforcesCriticalFileFloorIndependentlyOfAggregate() throws {
        let entries = [
            "MicMuteController.swift": 1,
            "HotkeyManager.swift": 1,
            "LaunchAtLoginManager.swift": 1,
            "PushToTalkController.swift": 1,
            "ClickSoundPlayer.swift": 0,
            "PreferencesWindow.swift": 1,
            "StatusBarController.swift": 1,
        ].map { filename, covered in
            "{\"filename\":\"/repo/Sources/MacMuteApp/\(filename)\",\"summary\":{\"lines\":{\"count\":1,\"covered\":\(covered)}}}"
        }.joined(separator: ",")
        let result = try runCoverageGate(
            report: "{\"data\":[{\"files\":[\(entries)]}]}",
            minimum: "0"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("ClickSoundPlayer.swift coverage 0.00%"))
    }

    func testCoverageGateRejectsImpossibleLineCounts() throws {
        let result = try runCoverageGate(
            report: "{\"data\":[{\"files\":[{\"filename\":\"/repo/Sources/MacMuteApp/MicMuteController.swift\",\"summary\":{\"lines\":{\"count\":1,\"covered\":2}}}]}]}",
            minimum: "0"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("contains no MacMute source lines"))
    }

    func testReleaseModeRejectsNonBooleanValue() throws {
        let result = try runRepositoryScript("Scripts/build_app.sh", environment: ["MACMUTE_RELEASE": "true"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("MACMUTE_RELEASE must be exactly 0 or 1"))
    }

    func testReleaseFailsClosedUntilPinnedTeamIdentifierIsConfigured() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        try Data("REPLACE_WITH_BREUSOFTWARE_TEAM_ID\n".utf8).write(
            to: fixture.root.appendingPathComponent("Resources/BreuSoftwareTeamID.txt")
        )
        let result = try fixture.run("Scripts/build_app.sh")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("configure BreuSoftware's exact 10-character Team ID"))
    }

    func testReleaseDMGRequiresNotaryProfileBeforeBuilding() throws {
        let result = try runRepositoryScript("Scripts/build_dmg.sh", environment: ["MACMUTE_RELEASE": "1"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("release builds require MACMUTE_NOTARY_PROFILE"))
    }

    func testPinnedTeamIdentifierRejectsEnvironmentOverride() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        let result = try fixture.run(
            "Scripts/build_app.sh",
            extraEnvironment: ["MACMUTE_TEAM_ID": "ZZZZZ99999"]
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("does not match the repository-pinned"))
        XCTAssertFalse(fixture.appURL.exists)
    }

    func testReleaseRejectsIdentityWhoseNameOnlyContainsCompanyName() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        let result = try fixture.run(
            "Scripts/build_app.sh",
            extraEnvironment: [
                "MACMUTE_SIGNING_IDENTITY": "Developer ID Application: Other BreuSoftware LLC Name (ABCDE12345)"
            ]
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("full Developer ID Application identity"))
    }

    func testSignedTeamIdentifierMustMatchPinnedValue() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        let result = try fixture.run(
            "Scripts/build_app.sh",
            extraEnvironment: ["FAKE_SIGNED_TEAM_ID": "ZZZZZ99999"]
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("does not match"))
        XCTAssertFalse(fixture.appURL.exists)
    }

    func testSuccessfulReleaseVerifiesAndPublishesBothArtifacts() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        let result = try fixture.run("Scripts/build_dmg.sh")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(fixture.appURL.exists)
        XCTAssertTrue(fixture.dmgURL.exists)
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("swift test"))
        XCTAssertTrue(log.contains("--enable-code-coverage"))
        XCTAssertTrue(log.contains("Scripts/check_coverage.swift"))
        XCTAssertTrue(log.contains("swift build"))
        XCTAssertTrue(log.contains("--arch arm64 --arch x86_64"))
        XCTAssertGreaterThanOrEqual(log.components(separatedBy: "-verify_arch arm64 x86_64").count - 1, 3)
        XCTAssertGreaterThanOrEqual(log.components(separatedBy: "hdiutil attach").count - 1, 2)
        XCTAssertTrue(log.contains("xcrun notarytool submit"))
        XCTAssertTrue(log.contains("xcrun stapler staple"))
        let notaryRange = try XCTUnwrap(log.range(of: "xcrun notarytool submit"))
        let appAssessmentRange = try XCTUnwrap(log.range(of: "spctl --assess --type execute"))
        let imageAssessmentRange = try XCTUnwrap(log.range(of: "spctl --assess --type open"))
        XCTAssertLessThan(notaryRange.lowerBound, appAssessmentRange.lowerBound)
        XCTAssertLessThan(appAssessmentRange.lowerBound, imageAssessmentRange.lowerBound)
        XCTAssertGreaterThanOrEqual(log.components(separatedBy: "hdiutil verify").count - 1, 2)
        let plist = NSDictionary(contentsOf: fixture.appURL.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(plist?["MacMuteSourceRevision"] as? String, ReleaseFixture.sourceRevision)
    }

    func testReleaseRejectsUntrackedReleaseInput() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }

        let result = try fixture.run(
            "Scripts/build_app.sh",
            extraEnvironment: ["FAKE_GIT_STATUS": "?? Sources/Injected.swift"]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("pristine tracked and untracked release inputs"))
    }

    func testReleaseRequiresPinnedTeamIdentifierFileToBeCommitted() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }

        let result = try fixture.run(
            "Scripts/build_app.sh",
            extraEnvironment: ["FAKE_TEAM_UNTRACKED": "1"]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Team ID file must be committed"))
    }

    func testUntrackedReleaseInputMarksDevelopmentRevisionDirty() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }

        let result = try fixture.run(
            "Scripts/build_app.sh",
            extraEnvironment: [
                "MACMUTE_RELEASE": "0",
                "FAKE_GIT_STATUS": "?? Sources/Injected.swift",
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        let plist = NSDictionary(contentsOf: fixture.appURL.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(plist?["MacMuteSourceRevision"] as? String, "\(ReleaseFixture.sourceRevision)-dirty")
    }

    func testReleaseFixtureRemovesOuterReleaseRoutingVariables() {
        let environment = ReleaseFixture.sanitizedBaseEnvironment([
            "MACMUTE_APP_OUTPUT": "/tmp/outer.app",
            "MACMUTE_TEAM_ID": "OUTER12345",
            "PATH": "/usr/bin",
        ])

        XCTAssertNil(environment["MACMUTE_APP_OUTPUT"])
        XCTAssertNil(environment["MACMUTE_TEAM_ID"])
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }

    func testNotaryFailurePreservesPreviousArtifacts() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        try fixture.installPreviousArtifacts()
        let result = try fixture.run(
            "Scripts/build_dmg.sh",
            extraEnvironment: ["FAKE_FAIL_TOOL": "notarytool"]
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try fixture.appMarker(), "previous-app")
        XCTAssertEqual(try String(contentsOf: fixture.dmgURL, encoding: .utf8), "previous-dmg")
    }

    func testDMGVerificationFailurePreservesPreviousArtifacts() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        try fixture.installPreviousArtifacts()
        let result = try fixture.run(
            "Scripts/build_dmg.sh",
            extraEnvironment: ["FAKE_FAIL_TOOL": "hdiutil-verify"]
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try fixture.appMarker(), "previous-app")
        XCTAssertEqual(try String(contentsOf: fixture.dmgURL, encoding: .utf8), "previous-dmg")
    }

    func testEveryReleaseGateFailurePreservesPreviousArtifacts() throws {
        for failingTool in ["swift-test", "coverage", "swift-build", "codesign", "spctl", "stapler"] {
            let fixture = try ReleaseFixture()
            defer { fixture.remove() }
            try fixture.installPreviousArtifacts()

            let result = try fixture.run(
                "Scripts/build_dmg.sh",
                extraEnvironment: ["FAKE_FAIL_TOOL": failingTool]
            )

            XCTAssertNotEqual(result.status, 0, "Expected \(failingTool) failure")
            XCTAssertEqual(try fixture.appMarker(), "previous-app", "Failed at \(failingTool)")
            XCTAssertEqual(
                try String(contentsOf: fixture.dmgURL, encoding: .utf8),
                "previous-dmg",
                "Failed at \(failingTool)"
            )
        }
    }

    func testPartialFinalPublicationRollsBackBothArtifacts() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        try fixture.installPreviousArtifacts()

        let result = try fixture.run(
            "Scripts/build_dmg.sh",
            extraEnvironment: ["FAKE_FAIL_TOOL": "publish-dmg"]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try fixture.appMarker(), "previous-app")
        XCTAssertEqual(try String(contentsOf: fixture.dmgURL, encoding: .utf8), "previous-dmg")
    }

    private func runRepositoryScript(
        _ relativePath: String,
        environment overrides: [String: String]
    ) throws -> (status: Int32, output: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Self.run(
            executable: root.appendingPathComponent(relativePath),
            directory: root,
            environment: ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }
        )
    }

    private func runCoverageGate(
        report: String,
        minimum: String
    ) throws -> (status: Int32, output: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMuteCoverage.\(UUID().uuidString).json")
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: reportURL) }
        return try Self.run(
            executable: URL(fileURLWithPath: "/usr/bin/swift"),
            directory: root,
            environment: ProcessInfo.processInfo.environment,
            arguments: ["Scripts/check_coverage.swift", reportURL.path, minimum]
        )
    }

    fileprivate static func run(
        executable: URL,
        directory: URL,
        environment: [String: String],
        arguments: [String] = []
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = environment
        process.arguments = arguments
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private final class ReleaseFixture {
    static let teamID = "ABCDE12345"
    static let sourceRevision = String(repeating: "a", count: 40)

    let root: URL
    let binURL: URL
    let logURL: URL
    var appURL: URL { root.appendingPathComponent("MacMute.app") }
    var dmgURL: URL { root.appendingPathComponent("MacMute-1.3.dmg") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMuteReleaseTests.\(UUID().uuidString)")
        binURL = root.appendingPathComponent("bin")
        logURL = root.appendingPathComponent("tool.log")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for script in ["build_app.sh", "build_dmg.sh", "check_coverage.swift"] {
            try FileManager.default.copyItem(
                at: repositoryRoot.appendingPathComponent("Scripts/\(script)"),
                to: root.appendingPathComponent("Scripts/\(script)")
            )
        }
        try Data(Self.teamID.utf8).write(to: root.appendingPathComponent("Resources/BreuSoftwareTeamID.txt"))
        try Data("icon".utf8).write(to: root.appendingPathComponent("Resources/RaptorIcon.png"))
        try Self.infoPlist.write(
            to: root.appendingPathComponent("Resources/Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        try installFakeTools()
    }

    func run(
        _ relativePath: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        var environment = Self.sanitizedBaseEnvironment(ProcessInfo.processInfo.environment)
        environment["PATH"] = "\(binURL.path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["MACMUTE_RELEASE"] = "1"
        environment["MACMUTE_SIGNING_IDENTITY"] = "Developer ID Application: BreuSoftware LLC (\(Self.teamID))"
        environment["MACMUTE_NOTARY_PROFILE"] = "test-profile"
        environment["FAKE_SIGNED_TEAM_ID"] = Self.teamID
        environment["FAKE_SOURCE_REVISION"] = Self.sourceRevision
        environment["FAKE_TOOL_LOG"] = logURL.path
        environment["FAKE_FAIL_TOOL"] = ""
        environment["FAKE_GIT_STATUS"] = ""
        environment["FAKE_TEAM_UNTRACKED"] = "0"
        for (key, value) in extraEnvironment { environment[key] = value }
        return try ReleaseScriptTests.run(
            executable: root.appendingPathComponent(relativePath),
            directory: root,
            environment: environment
        )
    }

    fileprivate static func sanitizedBaseEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        var environment = environment
        environment.removeValue(forKey: "MACMUTE_APP_OUTPUT")
        environment.removeValue(forKey: "MACMUTE_TEAM_ID")
        return environment
    }

    func installPreviousArtifacts() throws {
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        try Data("previous-app".utf8).write(to: appURL.appendingPathComponent("Contents/marker"))
        try Data("previous-dmg".utf8).write(to: dmgURL)
    }

    func appMarker() throws -> String {
        try String(contentsOf: appURL.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private func installFakeTools() throws {
        try writeTool("security", body: """
        printf '1) ABCDEF "Developer ID Application: BreuSoftware LLC (ABCDE12345)"\n'
        """)
        try writeTool("git", body: """
        if [ "$1" = "rev-parse" ]; then echo "$FAKE_SOURCE_REVISION"; exit 0; fi
        if [ "$1" = "status" ]; then printf '%s' "$FAKE_GIT_STATUS"; exit 0; fi
        if [ "$1" = "ls-files" ]; then [ "$FAKE_TEAM_UNTRACKED" = "1" ] && exit 1; exit 0; fi
        exit 0
        """)
        try writeTool("swift", body: """
        echo "swift $*" >> "$FAKE_TOOL_LOG"
        if [ "$1" = "test" ] && [ "$2" = "--show-codecov-path" ]; then
          echo .build/fake-codecov.json
        fi
        if [ "$1" = "build" ]; then
          mkdir -p .build/apple/Products/Release
          printf '#!/bin/sh\nexit 0\n' > .build/apple/Products/Release/MacMuteApp
          chmod +x .build/apple/Products/Release/MacMuteApp
        fi
        [ "$FAKE_FAIL_TOOL" = "coverage" ] && [ "$1" = "Scripts/check_coverage.swift" ] && exit 9
        [ "$FAKE_FAIL_TOOL" = "swift-$1" ] && exit 9
        exit 0
        """)
        try writeTool("sips", body: """
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--out" ]; then shift; mkdir -p "$(dirname "$1")"; : > "$1"; exit 0; fi
          shift
        done
        exit 1
        """)
        try writeTool("iconutil", body: """
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then shift; : > "$1"; exit 0; fi
          shift
        done
        exit 1
        """)
        try writeTool("codesign", body: """
        echo "codesign $*" >> "$FAKE_TOOL_LOG"
        if [ "$1" = "-dv" ]; then echo "TeamIdentifier=$FAKE_SIGNED_TEAM_ID" >&2; exit 0; fi
        [ "$FAKE_FAIL_TOOL" = "codesign" ] && exit 9
        exit 0
        """)
        try writeTool("spctl", body: """
        echo "spctl $*" >> "$FAKE_TOOL_LOG"
        [ "$FAKE_FAIL_TOOL" = "spctl" ] && exit 9
        exit 0
        """)
        try writeTool("lipo", body: """
        echo "lipo $*" >> "$FAKE_TOOL_LOG"
        [ "$FAKE_FAIL_TOOL" = "lipo" ] && exit 9
        [ "$2" = "-verify_arch" ] && [ -f "$1" ]
        """)
        try writeTool("hdiutil", body: """
        echo "hdiutil $*" >> "$FAKE_TOOL_LOG"
        if [ "$1" = "verify" ]; then
          [ "$FAKE_FAIL_TOOL" = "hdiutil-verify" ] && exit 9
          [ -f "$2" ]
          exit $?
        fi
        if [ "$1" = "attach" ]; then
          [ "$FAKE_FAIL_TOOL" = "hdiutil-attach" ] && exit 9
          mountpoint=''
          image=''
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "-mountpoint" ]; then shift; mountpoint="$1"; else image="$1"; fi
            shift
          done
          cp -R "$image.contents/." "$mountpoint/"
          exit $?
        fi
        if [ "$1" = "detach" ]; then
          find "$2" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
          exit 0
        fi
        srcfolder=''
        last=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-srcfolder" ]; then shift; srcfolder="$1"; fi
          last="$1"
          shift
        done
        [ -d "$srcfolder/MacMute.app" ] || exit 8
        [ -L "$srcfolder/Applications" ] || exit 8
        mkdir -p "$last.contents"
        cp -R "$srcfolder/." "$last.contents/"
        : > "$last"
        exit 0
        """)
        try writeTool("xcrun", body: """
        echo "xcrun $*" >> "$FAKE_TOOL_LOG"
        [ "$FAKE_FAIL_TOOL" = "$1" ] && exit 9
        exit 0
        """)
        try writeTool("mv", body: """
        if [ "$FAKE_FAIL_TOOL" = "publish-dmg" ] && [ "$2" = "MacMute-1.3.dmg" ]; then
          case "$1" in *macmute-dmg-build.*/MacMute-1.3.dmg) exit 9 ;; esac
        fi
        exec /bin/mv "$@"
        """)
    }

    private func writeTool(_ name: String, body: String) throws {
        let url = binURL.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static let infoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleShortVersionString</key><string>1.3</string>
    <key>CFBundleExecutable</key><string>MacMute</string>
    <key>CFBundleIdentifier</key><string>com.breu.macmute</string>
    </dict></plist>
    """
}

private extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
