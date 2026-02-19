import XCTest
@testable import Glitcho

final class ChannelAboutLinkIdentityTests: XCTestCase {
    func testSameURLCanGenerateDistinctIDsWithDifferentOccurrences() throws {
        let url = try XCTUnwrap(URL(string: "https://discord.gg/example"))
        let first = ChannelAboutLink(
            title: "",
            url: url,
            imageURL: URL(string: "https://static-cdn.jtvnw.net/example.png"),
            isImageLink: true,
            occurrence: 0
        )
        let second = ChannelAboutLink(
            title: "",
            url: url,
            imageURL: URL(string: "https://static-cdn.jtvnw.net/example.png"),
            isImageLink: true,
            occurrence: 1
        )

        XCTAssertNotEqual(first.id, second.id)
    }
}
