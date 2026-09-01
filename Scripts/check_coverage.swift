#!/usr/bin/env swift

import Foundation

struct CoverageError: Error, CustomStringConvertible {
    let description: String
}

let criticalFileFloors: [String: Double] = [
    "MicMuteController.swift": 55,
    "HotkeyManager.swift": 50,
    "LaunchAtLoginManager.swift": 70,
    "PushToTalkController.swift": 65,
    "ClickSoundPlayer.swift": 30,
    "PreferencesWindow.swift": 10,
    "StatusBarController.swift": 14,
]

guard CommandLine.arguments.count == 3,
      let minimumPercent = Double(CommandLine.arguments[2]),
      (0 ... 100).contains(minimumPercent) else {
    fputs("usage: check_coverage.swift <codecov-json> <minimum-percent>\n", stderr)
    exit(2)
}

do {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let runs = root["data"] as? [[String: Any]] else {
        throw CoverageError(description: "coverage report has no data runs")
    }

    var coveredLines = 0
    var executableLines = 0
    var sourceFiles = 0
    var fileCoverage: [String: (covered: Int, count: Int)] = [:]

    for run in runs {
        guard let files = run["files"] as? [[String: Any]] else { continue }
        for file in files {
            guard let filename = file["filename"] as? String,
                  filename.contains("/Sources/MacMuteApp/"),
                  let summary = file["summary"] as? [String: Any],
                  let lines = summary["lines"] as? [String: Any],
                  let count = lines["count"] as? Int,
                  let covered = lines["covered"] as? Int,
                  count >= 0,
                  covered >= 0,
                  covered <= count else { continue }
            sourceFiles += 1
            executableLines += count
            coveredLines += covered
            let basename = URL(fileURLWithPath: filename).lastPathComponent
            let prior = fileCoverage[basename] ?? (0, 0)
            fileCoverage[basename] = (prior.covered + covered, prior.count + count)
        }
    }

    guard sourceFiles > 0, executableLines > 0 else {
        throw CoverageError(description: "coverage report contains no MacMute source lines")
    }

    let percent = Double(coveredLines) * 100 / Double(executableLines)
    print(String(format: "MacMute source coverage: %.2f%% (%d/%d lines)", percent, coveredLines, executableLines))
    guard percent >= minimumPercent else {
        throw CoverageError(
            description: String(format: "source coverage %.2f%% is below the %.2f%% release floor", percent, minimumPercent)
        )
    }
    for (filename, floor) in criticalFileFloors.sorted(by: { $0.key < $1.key }) {
        guard let coverage = fileCoverage[filename], coverage.count > 0 else {
            throw CoverageError(description: "coverage report is missing critical source file \(filename)")
        }
        let filePercent = Double(coverage.covered) * 100 / Double(coverage.count)
        print(String(format: "  %@: %.2f%% (%d/%d lines)", filename, filePercent, coverage.covered, coverage.count))
        guard filePercent >= floor else {
            throw CoverageError(
                description: String(format: "%@ coverage %.2f%% is below the %.2f%% critical-file floor", filename, filePercent, floor)
            )
        }
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
