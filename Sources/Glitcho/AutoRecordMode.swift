import Foundation

#if canImport(SwiftUI)

enum AutoRecordMode: String, CaseIterable, Codable, Equatable {
    case onlyPinned
    case onlyFollowed
    case pinnedAndFollowed
    case customAllowlist

    var title: String {
        switch self {
        case .onlyPinned:
            return "Only pinned"
        case .onlyFollowed:
            return "Only followed"
        case .pinnedAndFollowed:
            return "Pinned + followed"
        case .customAllowlist:
            return "Custom allowlist"
        }
    }
}

#endif
