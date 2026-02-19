#if canImport(SwiftUI)
import Foundation

struct PinnedChannel: Identifiable, Codable, Hashable {
    var login: String
    var displayName: String
    var thumbnailURLString: String?
    var pinnedAt: Date
    var notifyEnabled: Bool

    var id: String { login }

    init(login: String, displayName: String, thumbnailURL: URL?, pinnedAt: Date = Date(), notifyEnabled: Bool = true) {
        self.login = login
        self.displayName = displayName
        self.thumbnailURLString = thumbnailURL?.absoluteString
        self.pinnedAt = pinnedAt
        self.notifyEnabled = notifyEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case login
        case displayName
        case thumbnailURLString
        case pinnedAt
        case notifyEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        login = try container.decode(String.self, forKey: .login)
        displayName = try container.decode(String.self, forKey: .displayName)
        thumbnailURLString = try container.decodeIfPresent(String.self, forKey: .thumbnailURLString)
        pinnedAt = try container.decodeIfPresent(Date.self, forKey: .pinnedAt) ?? Date()
        notifyEnabled = try container.decodeIfPresent(Bool.self, forKey: .notifyEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(login, forKey: .login)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(thumbnailURLString, forKey: .thumbnailURLString)
        try container.encode(pinnedAt, forKey: .pinnedAt)
        try container.encode(notifyEnabled, forKey: .notifyEnabled)
    }

    var url: URL {
        URL(string: "https://www.twitch.tv/\(login)")!
    }

    var thumbnailURL: URL? {
        guard let thumbnailURLString else { return nil }
        return URL(string: thumbnailURLString)
    }
}

#if os(macOS)
extension TwitchChannel {
    var login: String { id }
}
#endif

#endif
