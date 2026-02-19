import XCTest
@testable import Glitcho

final class ChannelVideosRoutingTests: XCTestCase {
    func testPreferredVideosRoute_IsSameOnlineAndOffline() {
        let online = ChannelVideosStore.preferredRouteURLForTests(
            channel: "ninja",
            section: .videos,
            offline: false
        )
        let offline = ChannelVideosStore.preferredRouteURLForTests(
            channel: "ninja",
            section: .videos,
            offline: true
        )

        XCTAssertEqual(online.absoluteString, "https://www.twitch.tv/ninja/videos")
        XCTAssertEqual(offline.absoluteString, online.absoluteString)
    }

    func testPreferredClipsRoute_IsSameOnlineAndOffline() {
        let online = ChannelVideosStore.preferredRouteURLForTests(
            channel: "ninja",
            section: .clips,
            offline: false
        )
        let offline = ChannelVideosStore.preferredRouteURLForTests(
            channel: "ninja",
            section: .clips,
            offline: true
        )

        XCTAssertEqual(online.absoluteString, "https://www.twitch.tv/ninja/clips")
        XCTAssertEqual(offline.absoluteString, online.absoluteString)
    }
}
