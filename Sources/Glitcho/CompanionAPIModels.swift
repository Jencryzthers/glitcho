import Foundation

#if canImport(SwiftUI)

struct CompanionRecordingStartRequest: Codable {
    let target: String
    let channelName: String?
    let quality: String?
}

struct CompanionRecordingStopRequest: Codable {
    let channelLogin: String?
}

struct CompanionDownloadTaskRequest: Codable {
    let id: String?
}

#endif
