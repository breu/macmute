import Foundation
import os

/// Unified logging for Brute. A subsystem lets failures be filtered in Console,
/// which the bare `NSLog("Brute: …")` prefix did not allow.
///
/// Volume values are deliberately not logged: they are user audio settings.
enum BruteLog {
    static let subsystem = "com.breu.macmute"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let feedback = Logger(subsystem: subsystem, category: "feedback")
    static let launch = Logger(subsystem: subsystem, category: "launch")
}
