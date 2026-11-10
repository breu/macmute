import Foundation
import XCTest

final class ReleaseScriptTests: XCTestCase {
    func testCoverageGateCountsOnlyProductSourcesAndEnforcesExactFloor() throws {
        let report = """
        {"data":[{"files":[
          {"filename":"/repo/Sources/BruteApp/One.swift","summary":{"lines":{"count":8,"covered":4}}},
          {"filename":"/repo/Sources/BruteApp/MicMuteController.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Sources/BruteApp/HotkeyManager.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Sources/BruteApp/LaunchAtLoginManager.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Sources/BruteApp/MicrophoneActionController.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Sources/BruteApp/ClickSoundPlayer.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Sources/BruteApp/PreferencesWindow.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Sources/BruteApp/StatusBarController.swift","summary":{"lines":{"count":1,"covered":1}}},
          {"filename":"/repo/Tests/BruteAppTests/OneTests.swift","summary":{"lines":{"count":100,"covered":100}}}
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
        XCTAssertTrue(result.output.contains("contains no Brute source lines"))
    }

    func testCoverageGateEnforcesCriticalFileFloorIndependentlyOfAggregate() throws {
        let entries = [
            "MicMuteController.swift": 1,
            "HotkeyManager.swift": 1,
            "LaunchAtLoginManager.swift": 1,
            "MicrophoneActionController.swift": 1,
            "ClickSoundPlayer.swift": 0,
            "PreferencesWindow.swift": 1,
            "StatusBarController.swift": 1,
        ].map { filename, covered in
            "{\"filename\":\"/repo/Sources/BruteApp/\(filename)\",\"summary\":{\"lines\":{\"count\":1,\"covered\":\(covered)}}}"
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
            report: "{\"data\":[{\"files\":[{\"filename\":\"/repo/Sources/BruteApp/MicMuteController.swift\",\"summary\":{\"lines\":{\"count\":1,\"covered\":2}}}]}]}",
            minimum: "0"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("contains no Brute source lines"))
    }

    func testReleaseModeRejectsNonBooleanValue() throws {
        let result = try runRepositoryScript("Scripts/build_app.sh", environment: ["BRUTE_RELEASE": "true"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("BRUTE_RELEASE must be exactly 0 or 1"))
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
        for releaseFlag in ["BRUTE_RELEASE", "MACMUTE_RELEASE"] {
            let result = try runRepositoryScript("Scripts/build_dmg.sh", environment: [releaseFlag: "1"])
            XCTAssertNotEqual(result.status, 0, releaseFlag)
            XCTAssertTrue(result.output.contains("release builds require BRUTE_NOTARY_PROFILE"), releaseFlag)
        }
    }

    func testPinnedTeamIdentifierRejectsEnvironmentOverride() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        let result = try fixture.run(
            "Scripts/build_app.sh",
            extraEnvironment: ["BRUTE_TEAM_ID": "ZZZZZ99999"]
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("does not match the repository-pinned"))
        XCTAssertFalse(fixture.appURL.exists)
    }

    func testReleaseRequiresTheExactDeveloperIDIdentityFromTheKeychain() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        let result = try fixture.run(
            "Scripts/build_app.sh",
            extraEnvironment: [
                "BRUTE_SIGNING_IDENTITY": "Developer ID Application: Other BreuSoftware LLC Name (ABCDE12345)"
            ]
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("signing identity is not available in this keychain"))
    }

    func testReleaseRejectsDeveloperIDIdentityForAnotherTeam() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        let identity = "Developer ID Application: BreuSoftware LLC (ZZZZZ99999)"
        let result = try fixture.run(
            "Scripts/build_app.sh",
            extraEnvironment: ["BRUTE_SIGNING_IDENTITY": identity, "FAKE_SECURITY_IDENTITY": identity]
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("full Developer ID Application identity for the pinned team"))
    }

    func testReleaseAcceptsUpdatedDeveloperIDNameForThePinnedTeam() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.remove() }
        let identity = "Developer ID Application: Breu Software Updated Name (\(ReleaseFixture.teamID))"
        let result = try fixture.run(
            "Scripts/build_app.sh",
            extraEnvironment: ["BRUTE_SIGNING_IDENTITY": identity, "FAKE_SECURITY_IDENTITY": identity]
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(fixture.appURL.exists)
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
        XCTAssertEqual(
            try Data(contentsOf: fixture.appURL.appendingPathComponent("Contents/Resources/BruteHelp.html")),
            try Data(contentsOf: fixture.root.appendingPathComponent("Resources/BruteHelp.html"))
        )
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("swift test"))
        XCTAssertTrue(log.contains("--enable-code-coverage"))
        XCTAssertTrue(log.contains("Scripts/check_coverage.swift"))
        XCTAssertTrue(log.contains("swift build"))
        XCTAssertTrue(log.contains("--arch arm64 --arch x86_64 --show-bin-path"))
        for architecture in ["arm64", "x86_64"] {
            XCTAssertGreaterThanOrEqual(log.components(separatedBy: "-verify_arch \(architecture)").count - 1, 3)
        }
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
        XCTAssertEqual(plist?["BruteSourceRevision"] as? String, ReleaseFixture.sourceRevision)
        XCTAssertEqual(plist?["CFBundleShortVersionString"] as? String, "1.3")
        XCTAssertEqual(plist?["CFBundleVersion"] as? String, "14.2")
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
                "BRUTE_RELEASE": "0",
                "FAKE_GIT_STATUS": "?? Sources/Injected.swift",
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        let plist = NSDictionary(contentsOf: fixture.appURL.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(plist?["BruteSourceRevision"] as? String, "\(ReleaseFixture.sourceRevision)-dirty")
    }

    func testReleaseFixtureRemovesOuterReleaseRoutingVariables() {
        let environment = ReleaseFixture.sanitizedBaseEnvironment([
            "BRUTE_APP_OUTPUT": "/tmp/outer.app",
            "BRUTE_TEAM_ID": "OUTER12345",
            "MACMUTE_APP_OUTPUT": "/tmp/legacy.app",
            "MACMUTE_TEAM_ID": "LEGACY1234",
            "PATH": "/usr/bin",
        ])

        XCTAssertNil(environment["BRUTE_APP_OUTPUT"])
        XCTAssertNil(environment["BRUTE_TEAM_ID"])
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
        let baseEnvironment = ReleaseFixture.sanitizedBaseEnvironment(ProcessInfo.processInfo.environment)
        return try Self.run(
            executable: root.appendingPathComponent(relativePath),
            directory: root,
            environment: baseEnvironment.merging(overrides) { _, new in new }
        )
    }

    private func runCoverageGate(
        report: String,
        minimum: String
    ) throws -> (status: Int32, output: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BruteCoverage.\(UUID().uuidString).json")
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
    var appURL: URL { root.appendingPathComponent("Brute.app") }
    var dmgURL: URL { root.appendingPathComponent("Brute-1.3.dmg") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BruteReleaseTests.\(UUID().uuidString)")
        binURL = root.appendingPathComponent("bin")
        logURL = root.appendingPathComponent("tool.log")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for script in ["build_app.sh", "build_dmg.sh", "check_release.sh", "check_coverage.swift"] {
            try FileManager.default.copyItem(
                at: repositoryRoot.appendingPathComponent("Scripts/\(script)"),
                to: root.appendingPathComponent("Scripts/\(script)")
            )
        }
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("Resources/BruteHelp.html"),
            to: root.appendingPathComponent("Resources/BruteHelp.html")
        )
        try Data(Self.teamID.utf8).write(to: root.appendingPathComponent("Resources/BreuSoftwareTeamID.txt"))
        try Data("icon".utf8).write(to: root.appendingPathComponent("Resources/RaptorIcon.png"))
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("Resources/Info.plist"),
            to: root.appendingPathComponent("Resources/Info.plist")
        )
        try Data("MARKETING_VERSION = 1.3\nCURRENT_PROJECT_VERSION = 14.2\n".utf8).write(
            to: root.appendingPathComponent("Resources/Version.xcconfig")
        )
        try installFakeTools()
    }

    func run(
        _ relativePath: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        var environment = Self.sanitizedBaseEnvironment(ProcessInfo.processInfo.environment)
        environment["PATH"] = "\(binURL.path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["BRUTE_RELEASE"] = "1"
        environment["BRUTE_SIGNING_IDENTITY"] = "Developer ID Application: BreuSoftware LLC (\(Self.teamID))"
        environment["BRUTE_NOTARY_PROFILE"] = "test-profile"
        environment["FAKE_SECURITY_IDENTITY"] = environment["BRUTE_SIGNING_IDENTITY"]
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
        environment.filter { key, _ in
            !key.hasPrefix("BRUTE_") && !key.hasPrefix("MACMUTE_")
        }
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
        printf '1) ABCDEF "%s"\n' "$FAKE_SECURITY_IDENTITY"
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
          case " $* " in
            *" --show-bin-path "*) printf '%s\n' "$PWD/.build/universal products" ;;
            *)
              mkdir -p '.build/universal products'
              printf '#!/bin/sh\nexit 0\n' > '.build/universal products/BruteApp'
              chmod +x '.build/universal products/BruteApp'
              ;;
          esac
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
        [ "$#" -eq 3 ] && [ "$2" = "-verify_arch" ] && [ -f "$1" ]
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
        [ -d "$srcfolder/Brute.app" ] || exit 8
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
        if [ "$FAKE_FAIL_TOOL" = "publish-dmg" ] && [ "$2" = "Brute-1.3.dmg" ]; then
          case "$1" in *brute-dmg-build.*/Brute-1.3.dmg) exit 9 ;; esac
        fi
        exec /bin/mv "$@"
        """)
    }

    private func writeTool(_ name: String, body: String) throws {
        let url = binURL.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
