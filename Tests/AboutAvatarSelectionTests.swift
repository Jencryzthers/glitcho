import XCTest
@testable import Glitcho

final class AboutAvatarSelectionTests: XCTestCase {
    func testSelectURL_PrefersStreamerAvatarOverViewerMenuAvatar() {
        let selected = AboutAvatarSelector.selectURL(
            channelName: "streamer123",
            payloadAvatarURL: "https://static-cdn.jtvnw.net/jtv_user_pictures/viewer-profile_image-70x70.png",
            candidates: [
                AboutAvatarCandidate(
                    url: "https://static-cdn.jtvnw.net/jtv_user_pictures/viewer-profile_image-70x70.png",
                    alt: "viewer avatar",
                    linkHref: "/settings/profile",
                    isInUserMenu: true,
                    isInNavigation: true,
                    isInChannelHeader: false
                ),
                AboutAvatarCandidate(
                    url: "https://static-cdn.jtvnw.net/jtv_user_pictures/streamer-profile_image-70x70.png",
                    alt: "streamer123 profile picture",
                    linkHref: "/streamer123/about",
                    isInUserMenu: false,
                    isInNavigation: false,
                    isInChannelHeader: true
                )
            ]
        )

        XCTAssertEqual(
            selected,
            "https://static-cdn.jtvnw.net/jtv_user_pictures/streamer-profile_image-70x70.png"
        )
    }

    func testSelectURL_PrefersChannelLinkCandidateWhenHeaderMetadataMissing() {
        let selected = AboutAvatarSelector.selectURL(
            channelName: "mychannel",
            payloadAvatarURL: "https://static-cdn.jtvnw.net/jtv_user_pictures/fallback-profile_image-70x70.png",
            candidates: [
                AboutAvatarCandidate(
                    url: "https://static-cdn.jtvnw.net/jtv_user_pictures/unknown-profile_image-70x70.png",
                    alt: "",
                    linkHref: "",
                    isInUserMenu: false,
                    isInNavigation: false,
                    isInChannelHeader: false
                ),
                AboutAvatarCandidate(
                    url: "https://static-cdn.jtvnw.net/jtv_user_pictures/streamer2-profile_image-70x70.png",
                    alt: "",
                    linkHref: "/mychannel",
                    isInUserMenu: false,
                    isInNavigation: false,
                    isInChannelHeader: false
                )
            ]
        )

        XCTAssertEqual(
            selected,
            "https://static-cdn.jtvnw.net/jtv_user_pictures/streamer2-profile_image-70x70.png"
        )
    }

    func testSelectURL_FallsBackToPayloadWhenNoCandidatesExist() {
        let selected = AboutAvatarSelector.selectURL(
            channelName: "fallback",
            payloadAvatarURL: "https://static-cdn.jtvnw.net/jtv_user_pictures/fallback-profile_image-70x70.png",
            candidates: []
        )

        XCTAssertEqual(
            selected,
            "https://static-cdn.jtvnw.net/jtv_user_pictures/fallback-profile_image-70x70.png"
        )
    }
}
