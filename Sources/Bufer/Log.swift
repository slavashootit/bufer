import os

/// Unified-log messages marked public, so `log stream` shows them instead of <private>.
/// Watch with: log stream --predicate 'subsystem == "com.slava.bufer"'
enum Log {
    private static let logger = Logger(subsystem: "com.slava.bufer", category: "app")

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}
