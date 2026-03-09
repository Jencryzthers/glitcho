import XCTest
@testable import Glitcho

final class ChannelAboutLinkIdentityTests: XCTestCase {
    func testSameURLCanCarryDistinctIDsForDifferentOccurrences() throws {
        let url = try XCTUnwrap(URL(string: "https://discord.gg/example"))
        let first = AboutLinkModel(
            id: "discord-example-0",
            title: "Discord",
            url: url,
            domain: "discord.gg",
            isImageLink: true
        )
        let second = AboutLinkModel(
            id: "discord-example-1",
            title: "Discord",
            url: url,
            domain: "discord.gg",
            isImageLink: true
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.url, second.url)
    }
}
