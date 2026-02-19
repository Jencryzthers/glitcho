import XCTest
@testable import Glitcho

final class AboutHTMLParserTests: XCTestCase {
    func testParseModel_ConvertsAnchorImageToPanelImageAndCleansRawURLText() async throws {
        let bioHTML = try fixture(named: "bio_messy")
        let panelHTML = try fixture(named: "panel_anchor_image")
        let parser = AboutHTMLParser()

        let model = parser.parseModel(
            channelName: "missmercyy",
            displayName: "MissMercyy",
            bioHTML: bioHTML,
            panelHTML: [panelHTML]
        )

        XCTAssertEqual(model.displayName, "MissMercyy")
        XCTAssertFalse(model.panels.isEmpty)

        let panel = try XCTUnwrap(model.panels.first)
        XCTAssertFalse(panel.images.isEmpty, "Expected <a><img></a> to become a clickable image model")
        XCTAssertNotNil(panel.images.first?.linkedURL)
        XCTAssertFalse(panel.bodyText.lowercased().contains("https://discord.gg/"))
    }

    func testParseModel_ExtractsSocialLinksAndRemovesTrackingParams() async throws {
        let bioHTML = try fixture(named: "bio_messy")
        let parser = AboutHTMLParser()

        let model = parser.parseModel(
            channelName: "missmercyy",
            displayName: "MissMercyy",
            bioHTML: bioHTML,
            panelHTML: []
        )

        let linkHosts = Set(model.socialLinks.map(\.domain))
        XCTAssertTrue(linkHosts.contains("discord.gg"))
        XCTAssertTrue(linkHosts.contains("twitter.com"))

        if let discord = model.socialLinks.first(where: { $0.domain == "discord.gg" }) {
            XCTAssertNil(URLComponents(url: discord.url, resolvingAgainstBaseURL: false)?.queryItems)
        } else {
            XCTFail("Expected parsed Discord link")
        }
    }

    func testParseModel_FallbackRemainsStableWhenPanelsAreMissing() async {
        let parser = AboutHTMLParser()
        let model = parser.parseModel(
            channelName: "fallbacktest",
            displayName: "",
            bioHTML: "<div><p>Only plain text bio.</p></div>",
            panelHTML: []
        )

        XCTAssertEqual(model.channelName, "fallbacktest")
        XCTAssertFalse(model.panels.isEmpty)
        XCTAssertFalse(model.bioText.isEmpty)
    }

    func testParseModel_UpgradesTwitchAvatarToHigherResolution() async {
        let parser = AboutHTMLParser()
        let model = parser.parseModel(
            channelName: "avatarcase",
            displayName: "AvatarCase",
            avatarURL: "https://static-cdn.jtvnw.net/jtv_user_pictures/abcd-profile_image-50x50.png",
            bioHTML: "<p>Hello</p>",
            panelHTML: []
        )

        let avatar = model.avatarURL?.absoluteString ?? ""
        XCTAssertTrue(avatar.contains("300x300"), "Expected upgraded avatar URL, got: \(avatar)")
    }

    private func fixture(named name: String) throws -> String {
        let bundle = Bundle.module
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "html", subdirectory: "About"),
            "Missing fixture: \(name).html"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}
