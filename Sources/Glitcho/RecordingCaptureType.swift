import Foundation

enum RecordingCaptureType: String, Codable, Hashable {
    case liveRecording = "live_recording"
    case streamDownload = "stream_download"
    case clipDownload = "clip_download"

    var isDownload: Bool {
        self != .liveRecording
    }

    var filenameTag: String {
        switch self {
        case .liveRecording:
            return "live"
        case .streamDownload:
            return "vod"
        case .clipDownload:
            return "clip"
        }
    }

    var listLabel: String {
        switch self {
        case .liveRecording:
            return "Recorded Stream"
        case .streamDownload:
            return "Stream Download"
        case .clipDownload:
            return "Clip Download"
        }
    }

    var actionLabel: String {
        switch self {
        case .liveRecording:
            return "Recording"
        case .streamDownload, .clipDownload:
            return "Download"
        }
    }

    static func fromFilenameTag(_ tag: String) -> RecordingCaptureType? {
        switch tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "live":
            return .liveRecording
        case "vod":
            return .streamDownload
        case "clip":
            return .clipDownload
        default:
            return nil
        }
    }

    static func infer(fromTarget target: String) -> RecordingCaptureType {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            resolved = trimmed
        } else {
            resolved = "https://\(trimmed)"
        }

        guard let url = URL(string: resolved) else { return .liveRecording }
        let host = url.host?.lowercased() ?? ""
        let parts = url.path.split(separator: "/").map { String($0).lowercased() }

        if host == "clips.twitch.tv" {
            return .clipDownload
        }
        if parts.contains("clip") || parts.contains("clips") {
            return .clipDownload
        }
        if parts.contains("videos") {
            return .streamDownload
        }
        return .liveRecording
    }
}
