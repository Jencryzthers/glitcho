import Foundation
import OSLog

#if canImport(SwiftUI)

enum GlitchoTelemetry {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Glitcho",
        category: "telemetry"
    )

    static func track(_ event: String, metadata: [String: String] = [:]) {
        if metadata.isEmpty {
            logger.info("event=\(event, privacy: .public)")
            return
        }

        let details = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        logger.info("event=\(event, privacy: .public) \(details, privacy: .public)")
    }
}

#endif
