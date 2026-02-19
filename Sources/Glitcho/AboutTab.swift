import AppKit
import CryptoKit
import Foundation
import SwiftUI
import WebKit

#if canImport(SwiftUI)

// MARK: - Typed About Model

struct AboutModel: Equatable {
    let channelName: String
    let displayName: String
    let avatarURL: URL?
    let bioText: String
    let bioBlocks: [AboutRichTextBlock]
    let socialLinks: [AboutLinkModel]
    let panels: [AboutPanelModel]
    let cacheTag: String
    let lastUpdated: Date
}

struct AboutPanelModel: Identifiable, Equatable {
    let id: String
    let title: String
    let bodyText: String
    let bodyBlocks: [AboutRichTextBlock]
    let images: [AboutImageModel]
    let linkTargets: [AboutLinkModel]
}

struct AboutLinkModel: Identifiable, Hashable, Equatable {
    let id: String
    let title: String
    let url: URL
    let domain: String
    let isImageLink: Bool
}

struct AboutImageModel: Identifiable, Hashable, Equatable {
    let id: String
    let url: URL
    let linkedURL: URL?
    let caption: String?
    let aspectHint: CGFloat?
}

struct AboutRichTextBlock: Identifiable, Hashable, Equatable {
    let id: String
    let tokens: [AboutInlineToken]
}

enum AboutInlineToken: Hashable, Equatable {
    case text(String)
    case emphasis(String)
    case link(title: String, url: URL)
}

struct AboutInstrumentation: Equatable {
    var parseDurationMs: Double = 0
    var timeToFirstRenderMs: Double = 0
    var imageLoadCount: Int = 0
    var usedCache = false
}

private struct AboutRawPayload {
    let channelName: String
    let displayName: String
    let avatarURL: String
    let bioHTML: String
    let panelHTML: [String]
    let signature: String
    let fetchedAt: Date
}

struct AboutAvatarCandidate: Equatable {
    let url: String
    let alt: String
    let linkHref: String
    let isInUserMenu: Bool
    let isInNavigation: Bool
    let isInChannelHeader: Bool

    init(
        url: String,
        alt: String,
        linkHref: String,
        isInUserMenu: Bool,
        isInNavigation: Bool,
        isInChannelHeader: Bool
    ) {
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.linkHref = linkHref.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isInUserMenu = isInUserMenu
        self.isInNavigation = isInNavigation
        self.isInChannelHeader = isInChannelHeader
    }

    init?(payload: [String: Any]) {
        let url = (payload["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !url.isEmpty else { return nil }
        self.init(
            url: url,
            alt: (payload["alt"] as? String) ?? "",
            linkHref: (payload["linkHref"] as? String) ?? "",
            isInUserMenu: Self.bool(payload["isInUserMenu"]),
            isInNavigation: Self.bool(payload["isInNavigation"]),
            isInChannelHeader: Self.bool(payload["isInChannelHeader"])
        )
    }

    private static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "true" || normalized == "1" || normalized == "yes"
        }
        return false
    }
}

enum AboutAvatarSelector {
    static func selectURL(channelName: String, payloadAvatarURL: String, candidates: [AboutAvatarCandidate]) -> String {
        let fallback = payloadAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let deduped = dedupe(candidates)
        guard !deduped.isEmpty else { return fallback }

        let normalizedChannel = normalizeChannelName(channelName)
        let ranked = deduped
            .map { candidate in
                (
                    candidate: candidate,
                    score: score(candidate, channelName: normalizedChannel)
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.candidate.url.count > rhs.candidate.url.count
                }
                return lhs.score > rhs.score
            }

        if let best = ranked.first, best.score >= 0 {
            return best.candidate.url
        }

        if let nonNavigation = deduped.first(where: { !$0.isInUserMenu && !$0.isInNavigation }) {
            return nonNavigation.url
        }

        if !fallback.isEmpty {
            return fallback
        }
        return ranked.first?.candidate.url ?? ""
    }

    private static func dedupe(_ candidates: [AboutAvatarCandidate]) -> [AboutAvatarCandidate] {
        var seen = Set<String>()
        var result: [AboutAvatarCandidate] = []
        for candidate in candidates {
            let url = candidate.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { continue }
            guard seen.insert(url).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    private static func score(_ candidate: AboutAvatarCandidate, channelName: String) -> Int {
        var value = 0
        if candidate.isInUserMenu { value -= 240 }
        if candidate.isInNavigation { value -= 120 }
        if candidate.isInChannelHeader { value += 170 }
        if linkTargetsChannel(candidate.linkHref, channelName: channelName) { value += 130 }
        if altMentionsChannel(candidate.alt, channelName: channelName) { value += 80 }
        if !candidate.isInUserMenu && !candidate.isInNavigation { value += 20 }
        return value
    }

    private static func normalizeChannelName(_ channelName: String) -> String {
        channelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func linkTargetsChannel(_ linkHref: String, channelName: String) -> Bool {
        guard !channelName.isEmpty else { return false }
        let trimmed = linkHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let candidatePath: String
        if let url = URL(string: trimmed), let host = url.host {
            guard host.lowercased().contains("twitch.tv") else { return false }
            candidatePath = url.path
        } else {
            candidatePath = trimmed
        }

        let pathComponents = candidatePath
            .lowercased()
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let login = pathComponents.first else { return false }
        return login == channelName
    }

    private static func altMentionsChannel(_ alt: String, channelName: String) -> Bool {
        guard !channelName.isEmpty else { return false }
        let normalized = alt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "'s", with: " ")
        guard !normalized.isEmpty else { return false }
        return normalized.contains(channelName)
    }
}

private struct AboutParseOutput {
    let model: AboutModel
    let parseDurationMs: Double
}

// MARK: - Hash Helpers

private enum AboutHash {
    static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func signature(_ values: [String]) -> String {
        sha256(values.joined(separator: "\u{241E}"))
    }
}

// MARK: - Parser

final class AboutHTMLParser {
    private let anchorRegex = try! NSRegularExpression(
        pattern: #"(?is)<a\b[^>]*href\s*=\s*(["'])(.*?)\1[^>]*>(.*?)</a>"#
    )
    private let imageTagRegex = try! NSRegularExpression(
        pattern: #"(?is)<img\b([^>]*)>"#
    )
    private let headingRegex = try! NSRegularExpression(
        pattern: #"(?is)<(?:h1|h2|h3|h4|h5|h6|strong|b)[^>]*>(.*?)</(?:h1|h2|h3|h4|h5|h6|strong|b)>"#
    )
    private let tagRegex = try! NSRegularExpression(pattern: #"(?is)<[^>]+>"#)
    private let styleRegex = try! NSRegularExpression(
        pattern: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#
    )
    private let chromeTagRegex = try! NSRegularExpression(
        pattern: #"(?is)<(nav|header|footer|aside|button|svg|iframe|video)\b[^>]*>.*?</\1>"#
    )
    private let selfClosingChromeRegex = try! NSRegularExpression(
        pattern: #"(?i)<(input|iframe|video|svg)\b[^>]*/?\s*>"#
    )
    private let chromeLabelRegex = try! NSRegularExpression(
        pattern: #"(?m)^\s*(Follow|Subscribe|Gift a Sub|Notifications?|Home|About|Schedule|Videos|Chat|Clips|Suggested Channels?|Recommended Channels?)\s*$"#
    )
    private let tokenRegex = try! NSRegularExpression(
        pattern: #"§§(LINK|BOLD)(\d+)§§"#
    )
    private let bareURLRegex = try! NSRegularExpression(
        pattern: #"(?i)\bhttps?://[^\s<>()]+"#
    )
    private let bareHostURLRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:www\.)?[a-z0-9.-]+\.[a-z]{2,}(?:/[^\s<>()]*)?"#
    )
    private let whitespaceRegex = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private let newlinesRegex = try! NSRegularExpression(pattern: #"\n{3,}"#)

    fileprivate func parse(payload: AboutRawPayload) -> AboutParseOutput {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let model = try buildModel(payload: payload)
            let parseMs = max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000)
            return AboutParseOutput(model: model, parseDurationMs: parseMs)
        } catch {
            let fallback = fallbackModel(payload: payload)
            let parseMs = max(0, (CFAbsoluteTimeGetCurrent() - start) * 1000)
            return AboutParseOutput(model: fallback, parseDurationMs: parseMs)
        }
    }

    func parseModel(
        channelName: String,
        displayName: String,
        avatarURL: String = "",
        bioHTML: String,
        panelHTML: [String],
        signature: String? = nil
    ) -> AboutModel {
        let resolvedSignature = signature ?? AboutHash.signature([channelName, displayName, avatarURL, bioHTML] + panelHTML)
        let payload = AboutRawPayload(
            channelName: channelName,
            displayName: displayName,
            avatarURL: avatarURL,
            bioHTML: bioHTML,
            panelHTML: panelHTML,
            signature: resolvedSignature,
            fetchedAt: Date()
        )
        return parse(payload: payload).model
    }

    private func buildModel(payload: AboutRawPayload) throws -> AboutModel {
        let displayName = cleanedText(payload.displayName).isEmpty ? payload.channelName : cleanedText(payload.displayName)
        let avatarURL = upgradedTwitchAvatarURL(normalizedURL(from: payload.avatarURL))
        let sanitizedBioHTML = sanitizeHTML(payload.bioHTML)
        let parsedBio = parseRichBlocks(from: sanitizedBioHTML, includeImageLinks: false)
        let bioText = parsedBio.plainText

        var socialLinks = parsedBio.links.filter { !$0.isImageLink }
        var panels: [AboutPanelModel] = []

        for (index, rawHTML) in payload.panelHTML.enumerated() {
            let sanitized = sanitizeHTML(rawHTML)
            if let panel = parsePanel(html: sanitized, index: index) {
                panels.append(panel)
                socialLinks.append(contentsOf: panel.linkTargets.filter { !$0.isImageLink })
            }
        }

        if panels.isEmpty, !sanitizedBioHTML.isEmpty {
            let fallbackPanel = AboutPanelModel(
                id: "fallback-\(AboutHash.sha256(sanitizedBioHTML))",
                title: "About \(displayName)",
                bodyText: bioText,
                bodyBlocks: parsedBio.blocks,
                images: [],
                linkTargets: parsedBio.links
            )
            panels = [fallbackPanel]
        }

        let dedupedSocialLinks = dedupeLinks(socialLinks).prefix(14)

        return AboutModel(
            channelName: payload.channelName,
            displayName: displayName,
            avatarURL: avatarURL,
            bioText: bioText,
            bioBlocks: parsedBio.blocks,
            socialLinks: Array(dedupedSocialLinks),
            panels: dedupePanels(panels),
            cacheTag: payload.signature,
            lastUpdated: payload.fetchedAt
        )
    }

    private func parsePanel(html: String, index: Int) -> AboutPanelModel? {
        let title = extractPanelTitle(from: html)
        let parsedBody = parseRichBlocks(from: html, includeImageLinks: true)
        let images = extractImages(from: html)
        let links = dedupeLinks(parsedBody.links)

        let bodyText = parsedBody.plainText
        guard !title.isEmpty || !bodyText.isEmpty || !images.isEmpty || !links.isEmpty else {
            return nil
        }

        let identity = AboutHash.signature([
            title,
            bodyText,
            images.map { $0.url.absoluteString }.joined(separator: ","),
            links.map { $0.url.absoluteString }.joined(separator: ","),
            String(index)
        ])

        return AboutPanelModel(
            id: identity,
            title: title,
            bodyText: bodyText,
            bodyBlocks: parsedBody.blocks,
            images: images,
            linkTargets: links
        )
    }

    private func fallbackModel(payload: AboutRawPayload) -> AboutModel {
        let cleanedBio = cleanedText(stripTags(payload.bioHTML))
        let block = AboutRichTextBlock(
            id: AboutHash.sha256(cleanedBio),
            tokens: cleanedBio.isEmpty ? [] : [.text(cleanedBio)]
        )
        let fallbackPanel = AboutPanelModel(
            id: "fallback-\(AboutHash.sha256(payload.signature))",
            title: payload.displayName.isEmpty ? "About \(payload.channelName)" : "About \(payload.displayName)",
            bodyText: cleanedBio,
            bodyBlocks: cleanedBio.isEmpty ? [] : [block],
            images: [],
            linkTargets: []
        )

        return AboutModel(
            channelName: payload.channelName,
            displayName: payload.displayName.isEmpty ? payload.channelName : payload.displayName,
            avatarURL: upgradedTwitchAvatarURL(normalizedURL(from: payload.avatarURL)),
            bioText: cleanedBio,
            bioBlocks: cleanedBio.isEmpty ? [] : [block],
            socialLinks: [],
            panels: [fallbackPanel],
            cacheTag: payload.signature,
            lastUpdated: payload.fetchedAt
        )
    }

    private func parseRichBlocks(from rawHTML: String, includeImageLinks: Bool) -> (blocks: [AboutRichTextBlock], links: [AboutLinkModel], plainText: String) {
        var working = sanitizeHTML(rawHTML)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var links: [AboutLinkModel] = []
        var linkTokens: [Int: AboutLinkModel] = [:]
        var boldTokens: [Int: String] = [:]
        var linkIndex = 0
        var boldIndex = 0

        working = replaceMatches(in: working, regex: anchorRegex) { [weak self] match, source in
            guard let self else { return "" }
            let href = source.substring(with: match.range(at: 2))
            let inner = source.substring(with: match.range(at: 3))
            let containsImage = inner.range(of: "<img", options: [.caseInsensitive, .regularExpression]) != nil

            guard let url = self.normalizedURL(from: href) else {
                return containsImage ? "" : self.cleanedText(self.stripTags(inner))
            }

            let textTitle = self.cleanedText(self.stripTags(inner))
            let derivedTitle = textTitle.isEmpty ? (url.host ?? url.absoluteString) : textTitle
            let domain = self.normalizedDomain(for: url)
            let link = AboutLinkModel(
                id: AboutHash.signature([url.absoluteString, derivedTitle.lowercased(), containsImage ? "image" : "text", String(linkIndex)]),
                title: derivedTitle,
                url: url,
                domain: domain,
                isImageLink: containsImage
            )

            if !containsImage || includeImageLinks {
                links.append(link)
            }

            if containsImage {
                return ""
            }

            let token = "§§LINK\(linkIndex)§§"
            linkTokens[linkIndex] = link
            linkIndex += 1
            return token
        }

        working = replaceMatches(in: working, pattern: #"(?is)<(strong|b)\b[^>]*>(.*?)</\1>"#) { [weak self] match, source in
            guard let self else { return "" }
            let value = self.cleanedText(self.stripTags(source.substring(with: match.range(at: 2))))
            guard !value.isEmpty else { return "" }
            let token = "§§BOLD\(boldIndex)§§"
            boldTokens[boldIndex] = value
            boldIndex += 1
            return token
        }

        working = replaceMatches(in: working, pattern: #"(?is)<br\s*/?>"#) { _, _ in "\n" }
        working = replaceMatches(in: working, pattern: #"(?is)</p>"#) { _, _ in "\n\n" }
        working = replaceMatches(in: working, pattern: #"(?is)</div>"#) { _, _ in "\n" }
        working = replaceMatches(in: working, pattern: #"(?is)<li\b[^>]*>"#) { _, _ in "\n• " }
        working = replaceMatches(in: working, pattern: #"(?is)</li>"#) { _, _ in "\n" }
        working = replaceMatches(in: working, regex: imageTagRegex) { _, _ in "" }
        working = stripTags(working)
        working = decodeHTMLEntities(working)
        working = compactBareURLs(in: working)
        working = normalizeWhitespacePreservingNewlines(working)

        let blocks = buildBlocks(from: working, linkTokens: linkTokens, boldTokens: boldTokens)
        let plainText = blocks
            .map { block in
                block.tokens.map {
                    switch $0 {
                    case .text(let value):
                        return value
                    case .emphasis(let value):
                        return value
                    case .link(let title, _):
                        return title
                    }
                }.joined()
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (blocks, dedupeLinks(links), plainText)
    }

    private func buildBlocks(
        from content: String,
        linkTokens: [Int: AboutLinkModel],
        boldTokens: [Int: String]
    ) -> [AboutRichTextBlock] {
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.enumerated().compactMap { index, line in
            let nsLine = line as NSString
            let matches = tokenRegex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            var cursor = 0
            var tokens: [AboutInlineToken] = []

            for match in matches {
                let beforeRange = NSRange(location: cursor, length: max(0, match.range.location - cursor))
                if beforeRange.length > 0 {
                    let text = cleanedText(nsLine.substring(with: beforeRange))
                    if !text.isEmpty {
                        tokens.append(.text(text))
                    }
                }

                let kind = nsLine.substring(with: match.range(at: 1))
                let rawIndex = nsLine.substring(with: match.range(at: 2))
                let tokenIndex = Int(rawIndex) ?? -1

                if kind == "LINK", let link = linkTokens[tokenIndex] {
                    tokens.append(.link(title: link.title, url: link.url))
                } else if kind == "BOLD", let value = boldTokens[tokenIndex], !value.isEmpty {
                    tokens.append(.emphasis(value))
                }

                cursor = match.range.location + match.range.length
            }

            if cursor < nsLine.length {
                let remainder = cleanedText(nsLine.substring(with: NSRange(location: cursor, length: nsLine.length - cursor)))
                if !remainder.isEmpty {
                    tokens.append(.text(remainder))
                }
            }

            guard !tokens.isEmpty else { return nil }
            return AboutRichTextBlock(
                id: AboutHash.signature([String(index), tokens.map { "\($0)" }.joined(separator: "|")]),
                tokens: tokens
            )
        }
    }

    private func extractImages(from html: String) -> [AboutImageModel] {
        let nsHTML = html as NSString
        var images: [AboutImageModel] = []
        var seen = Set<String>()
        var imageOccurrence = 0

        // First capture linked images (<a><img/></a>)
        let anchorMatches = anchorRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        for match in anchorMatches {
            let hrefRaw = nsHTML.substring(with: match.range(at: 2))
            let innerHTML = nsHTML.substring(with: match.range(at: 3))
            guard innerHTML.range(of: "<img", options: [.caseInsensitive, .regularExpression]) != nil else {
                continue
            }
            guard let linkedURL = normalizedURL(from: hrefRaw) else {
                continue
            }

            let innerNSString = innerHTML as NSString
            let imageMatches = imageTagRegex.matches(in: innerHTML, range: NSRange(location: 0, length: innerNSString.length))
            for imageMatch in imageMatches {
                let attrs = innerNSString.substring(with: imageMatch.range(at: 1))
                guard let source = imageSource(fromAttributes: attrs), let imageURL = normalizedURL(from: source) else {
                    continue
                }
                let key = imageURL.absoluteString.lowercased()
                guard seen.insert(key).inserted else { continue }
                let caption = cleanedText(imageAttribute("alt", from: attrs))
                let aspect = imageAspect(from: attrs)
                images.append(
                    AboutImageModel(
                        id: AboutHash.signature([imageURL.absoluteString, linkedURL.absoluteString, String(imageOccurrence)]),
                        url: imageURL,
                        linkedURL: linkedURL,
                        caption: caption.isEmpty ? nil : caption,
                        aspectHint: aspect
                    )
                )
                imageOccurrence += 1
            }
        }

        // Then standalone images
        let imageMatches = imageTagRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        for imageMatch in imageMatches {
            let attrs = nsHTML.substring(with: imageMatch.range(at: 1))
            guard let source = imageSource(fromAttributes: attrs), let imageURL = normalizedURL(from: source) else {
                continue
            }
            let key = imageURL.absoluteString.lowercased()
            guard seen.insert(key).inserted else { continue }
            let caption = cleanedText(imageAttribute("alt", from: attrs))
            let aspect = imageAspect(from: attrs)
            images.append(
                AboutImageModel(
                    id: AboutHash.signature([imageURL.absoluteString, "standalone", String(imageOccurrence)]),
                    url: imageURL,
                    linkedURL: nil,
                    caption: caption.isEmpty ? nil : caption,
                    aspectHint: aspect
                )
            )
            imageOccurrence += 1
        }

        return images
    }

    private func extractPanelTitle(from html: String) -> String {
        let nsHTML = html as NSString
        if let match = headingRegex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            let inner = nsHTML.substring(with: match.range(at: 1))
            let title = cleanedText(stripTags(inner))
            if !title.isEmpty {
                return title
            }
        }

        // Fallback: first non-empty line of plain text
        let plain = cleanedText(stripTags(html))
        if let firstLine = plain
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return firstLine
        }

        return ""
    }

    private func dedupeLinks(_ links: [AboutLinkModel]) -> [AboutLinkModel] {
        var seen = Set<String>()
        var deduped: [AboutLinkModel] = []
        for link in links {
            let key = "\(link.url.absoluteString.lowercased())|\(link.isImageLink ? "image" : "text")"
            if seen.insert(key).inserted {
                deduped.append(link)
            }
        }
        return deduped
    }

    private func dedupePanels(_ panels: [AboutPanelModel]) -> [AboutPanelModel] {
        var seen = Set<String>()
        var deduped: [AboutPanelModel] = []
        for panel in panels {
            let key = AboutHash.signature([
                panel.title.lowercased(),
                panel.bodyText.lowercased(),
                panel.images.map { $0.url.absoluteString }.joined(separator: ",")
            ])
            if seen.insert(key).inserted {
                deduped.append(panel)
            }
        }
        return deduped
    }

    private func sanitizeHTML(_ html: String) -> String {
        var value = html
        value = replaceMatches(in: value, regex: styleRegex) { _, _ in "" }
        value = replaceMatches(in: value, regex: chromeTagRegex) { _, _ in "" }
        value = replaceMatches(in: value, regex: selfClosingChromeRegex) { _, _ in "" }
        value = replaceMatches(in: value, regex: chromeLabelRegex) { _, _ in "" }
        value = value.replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
        return value
    }

    private func replaceMatches(
        in source: String,
        regex: NSRegularExpression,
        transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        guard !matches.isEmpty else { return source }

        var output = source
        for match in matches.reversed() {
            let replacement = transform(match, nsSource)
            if let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: replacement)
            }
        }
        return output
    }

    private func replaceMatches(
        in source: String,
        pattern: String,
        transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        return replaceMatches(in: source, regex: regex, transform: transform)
    }

    private func stripTags(_ html: String) -> String {
        replaceMatches(in: html, regex: tagRegex) { _, _ in " " }
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        guard let data = value.data(using: .utf8) else {
            return value
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string
        }

        return value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private func normalizeWhitespacePreservingNewlines(_ value: String) -> String {
        var output = value
        output = replaceMatches(in: output, regex: whitespaceRegex) { _, _ in " " }
        output = output.replacingOccurrences(of: " \n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "\n")
        output = replaceMatches(in: output, regex: newlinesRegex) { _, _ in "\n\n" }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compactBareURLs(in value: String) -> String {
        var output = replaceMatches(in: value, regex: bareURLRegex) { [weak self] match, source in
            guard let self else { return "" }
            let raw = source.substring(with: match.range)
            guard let normalized = self.normalizedURL(from: raw) else {
                return raw
            }
            return self.normalizedDomain(for: normalized)
        }

        output = replaceMatches(in: output, regex: bareHostURLRegex) { [weak self] match, source in
            guard let self else { return "" }
            let raw = source.substring(with: match.range)
            guard raw.contains(".") else { return raw }
            guard let normalized = self.normalizedURL(from: raw) else {
                return raw
            }
            return self.normalizedDomain(for: normalized)
        }
        return output
    }

    private func cleanedText(_ value: String) -> String {
        normalizeWhitespacePreservingNewlines(decodeHTMLEntities(value))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func imageSource(fromAttributes attributes: String) -> String? {
        imageAttribute("src", from: attributes)
    }

    private func imageAttribute(_ name: String, from attributes: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)\b\#(name)\s*=\s*(["'])(.*?)\1"#
        ) else {
            return ""
        }
        let nsAttributes = attributes as NSString
        guard let match = regex.firstMatch(in: attributes, range: NSRange(location: 0, length: nsAttributes.length)) else {
            return ""
        }
        return nsAttributes.substring(with: match.range(at: 2))
    }

    private func imageAspect(from attributes: String) -> CGFloat? {
        let width = Double(imageAttribute("width", from: attributes)) ?? 0
        let height = Double(imageAttribute("height", from: attributes)) ?? 0
        guard width > 0, height > 0 else { return nil }
        return CGFloat(width / height)
    }

    private func normalizedURL(from raw: String) -> URL? {
        let decoded = decodeHTMLEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }

        let candidate: String
        if decoded.hasPrefix("//") {
            candidate = "https:\(decoded)"
        } else if decoded.hasPrefix("/") {
            candidate = "https://www.twitch.tv\(decoded)"
        } else if decoded.lowercased().hasPrefix("http://") || decoded.lowercased().hasPrefix("https://") {
            candidate = decoded
        } else {
            candidate = "https://\(decoded)"
        }

        guard var components = URLComponents(string: candidate) else {
            return nil
        }

        if var items = components.queryItems, !items.isEmpty {
            items.removeAll(where: {
                let key = $0.name.lowercased()
                return key.hasPrefix("utm_") ||
                    key == "fbclid" ||
                    key == "gclid" ||
                    key == "ref" ||
                    key == "tt_medium" ||
                    key == "tt_content" ||
                    key == "tt_campaign"
            })
            components.queryItems = items.isEmpty ? nil : items
        }

        return components.url
    }

    private func normalizedDomain(for url: URL) -> String {
        let host = (url.host ?? "link").lowercased()
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    private func upgradedTwitchAvatarURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let raw = url.absoluteString

        if raw.contains("-profile_image-") {
            let upgraded = raw.replacingOccurrences(
                of: #"-profile_image-\d+x\d+"#,
                with: "-profile_image-300x300",
                options: .regularExpression
            )
            return URL(string: upgraded) ?? url
        }

        if raw.contains("static-cdn.jtvnw.net") {
            let upgraded = raw.replacingOccurrences(
                of: #"(\d+)x(\d+)"#,
                with: "300x300",
                options: [.regularExpression]
            )
            return URL(string: upgraded) ?? url
        }

        return url
    }
}

// MARK: - Cache

actor AboutModelCache {
    static let shared = AboutModelCache()

    private struct Entry {
        let signature: String
        let model: AboutModel
        let lastUpdated: Date
    }

    private var byChannel: [String: Entry] = [:]

    func model(channelName: String, signature: String) -> AboutModel? {
        let key = channelName.lowercased()
        guard let entry = byChannel[key], entry.signature == signature else {
            return nil
        }
        return entry.model
    }

    func latestModel(channelName: String) -> AboutModel? {
        byChannel[channelName.lowercased()]?.model
    }

    func set(_ model: AboutModel, channelName: String, signature: String, lastUpdated: Date) {
        byChannel[channelName.lowercased()] = Entry(
            signature: signature,
            model: model,
            lastUpdated: lastUpdated
        )
    }
}

// MARK: - Store

@MainActor
final class AboutTabStore: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published private(set) var model: AboutModel?
    @Published var isLoading = false
    @Published var lastError: String?
    @Published private(set) var instrumentation = AboutInstrumentation()

    private var webView: WKWebView?
    private var currentChannel: String?
    private var loadingDeadlineWorkItem: DispatchWorkItem?
    private var parseTask: Task<Void, Never>?
    private let parser = AboutHTMLParser()
    private var currentPayloadSignature: String?
    private var loadStartedAt: CFAbsoluteTime = 0
    private var firstRenderTracked = false

    override init() {
        super.init()
        webView = makeWebView()
    }

    deinit {
        loadingDeadlineWorkItem?.cancel()
        parseTask?.cancel()
        if let webView {
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "aboutPayload")
            webView.stopLoading()
        }
    }

    func attachWebView() -> WKWebView {
        if let webView { return webView }
        let created = makeWebView()
        webView = created
        return created
    }

    func load(channelName: String, force: Bool = false) {
        let normalized = channelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return }

        if !force, normalized == currentChannel {
            return
        }

        currentChannel = normalized
        currentPayloadSignature = nil
        parseTask?.cancel()
        parseTask = nil
        loadingDeadlineWorkItem?.cancel()

        if force {
            model = nil
        }

        isLoading = true
        lastError = nil
        loadStartedAt = CFAbsoluteTimeGetCurrent()
        firstRenderTracked = false
        instrumentation = AboutInstrumentation()

        scheduleLoadingDeadline(for: normalized)
        let url = URL(string: "https://www.twitch.tv/\(normalized)/about")!
        webView?.load(URLRequest(url: url))

        Task {
            if let cached = await AboutModelCache.shared.latestModel(channelName: normalized) {
                if self.currentChannel == normalized, self.model == nil {
                    self.model = cached
                    self.instrumentation.usedCache = true
                }
            }
        }
    }

    func reload() {
        guard let currentChannel else { return }
        load(channelName: currentChannel, force: true)
    }

    func recordImageLoaded(source: AboutImageDataSource) {
        instrumentation.imageLoadCount += 1
        if instrumentation.imageLoadCount == 1 || instrumentation.imageLoadCount % 10 == 0 {
            GlitchoTelemetry.track(
                "about_image_load_count",
                metadata: [
                    "channel": currentChannel ?? "",
                    "count": "\(instrumentation.imageLoadCount)",
                    "source": source.rawValue
                ]
            )
        }
    }

    private func scheduleLoadingDeadline(for channel: String) {
        loadingDeadlineWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.currentChannel == channel else { return }
            if self.isLoading {
                self.isLoading = false
                if self.model == nil {
                    self.lastError = "Unable to load channel panels right now."
                }
            }
        }
        loadingDeadlineWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0, execute: work)
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        config.userContentController = contentController
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio, .video]

        contentController.add(self, name: "aboutPayload")
        contentController.addUserScript(Self.scrapePayloadScript)

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            view.underPageBackgroundColor = .clear
        }
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        return view
    }

    private static let scrapePayloadScript = WKUserScript(
        source: #"""
        (function() {
          if (window.__glitcho_about_payload_v2) { return; }
          window.__glitcho_about_payload_v2 = true;

          function trim(s) {
            return (s || '').replace(/\s+/g, ' ').trim();
          }

          function findContainer() {
            return document.querySelector('[data-test-selector="channel-info-content"]') ||
              document.querySelector('[data-a-target="channel-info-content"]') ||
              document.querySelector('[data-test-selector="channel-panels"]') ||
              document.querySelector('[data-a-target="channel-panels"]') ||
              document.querySelector('section[aria-label*="About"]') ||
              document.querySelector('section[aria-label*="À propos"]') ||
              document.querySelector('section[aria-label*="A propos"]') ||
              document.querySelector('main') ||
              document.querySelector('[role="main"]');
          }

          function collectPanelNodes(container) {
            const selectors = [
              '[data-test-selector="channel-panel"]',
              '[data-a-target="channel-panel"]',
              '[data-test-selector*="channel-panel"]',
              '[data-a-target*="channel-panel"]'
            ];

            let nodes = [];
            selectors.forEach(sel => {
              nodes = nodes.concat(Array.from(container.querySelectorAll(sel)));
            });

            if (!nodes.length) {
              nodes = Array.from(container.querySelectorAll('section,article')).filter(node => {
                const txt = trim(node.textContent || '');
                const hasImage = !!node.querySelector('img[src]');
                return txt.length > 0 || hasImage;
              });
            }

            const deduped = [];
            const seen = new Set();
            nodes.forEach(node => {
              const key = trim((node.outerHTML || node.innerHTML || '').slice(0, 1500));
              if (!key || seen.has(key)) { return; }
              seen.add(key);
              deduped.push(node);
            });

            return deduped.slice(0, 120);
          }

          function collectAvatarCandidates() {
            const candidates = [];
            const seen = new Set();
            const headerSelector = [
              '[data-a-target="channel-header"]',
              '[data-test-selector="channel-header"]',
              '[data-a-target="channel-info-bar"]',
              '[data-test-selector="channel-info-bar"]',
              '[data-a-target="channel-info-content"]',
              '[data-test-selector="channel-info-content"]'
            ].join(',');

            const avatarNodes = Array.from(document.querySelectorAll('img[src*="profile_image-"], img[src*="profile-image"]'));
            avatarNodes.forEach(node => {
              const url = trim(node.getAttribute('src') || '');
              if (!url || seen.has(url)) { return; }
              seen.add(url);

              const link = node.closest('a[href]');
              const linkHref = link ? (link.getAttribute('href') || '') : '';
              const inUserMenu = !!node.closest('[data-a-target="user-menu-toggle"], [data-test-selector="user-menu-toggle"], [aria-label*="user menu" i]');
              const inNavigation = !!node.closest('nav, [role="navigation"], [data-a-target*="top-nav"], [data-test-selector*="top-nav"], [data-a-target*="side-nav"], [data-test-selector*="side-nav"]');
              const inChannelHeader = !!node.closest(headerSelector);

              candidates.push({
                url: url,
                alt: trim(node.getAttribute('alt') || ''),
                linkHref: trim(linkHref),
                isInUserMenu: inUserMenu,
                isInNavigation: inNavigation,
                isInChannelHeader: inChannelHeader
              });
            });

            return candidates.slice(0, 32);
          }

          function collectPayload() {
            const container = findContainer();
            if (!container) { return null; }

            const panelNodes = collectPanelNodes(container);
            const panelHTML = panelNodes
              .map(node => node.outerHTML || node.innerHTML || '')
              .filter(Boolean);

            const clone = container.cloneNode(true);
            [
              '[data-test-selector="channel-panel"]',
              '[data-a-target="channel-panel"]',
              '[data-test-selector*="channel-panel"]',
              '[data-a-target*="channel-panel"]'
            ].forEach(sel => {
              Array.from(clone.querySelectorAll(sel)).forEach(node => node.remove());
            });


            const displayName = trim(
              (document.querySelector('h1') && document.querySelector('h1').textContent) ||
              (document.querySelector('[data-a-target="stream-title"]') && document.querySelector('[data-a-target="stream-title"]').textContent) ||
              ''
            );

            const avatarCandidates = collectAvatarCandidates();
            let avatarURL = '';
            const preferredAvatar =
              avatarCandidates.find(item => item.isInChannelHeader && !item.isInUserMenu && !item.isInNavigation) ||
              avatarCandidates.find(item => !item.isInUserMenu && !item.isInNavigation) ||
              avatarCandidates[0];
            if (preferredAvatar && preferredAvatar.url) {
              avatarURL = preferredAvatar.url;
            } else {
              const metaAvatar = document.querySelector('meta[property="og:image"]');
              if (metaAvatar) {
                avatarURL = metaAvatar.getAttribute('content') || '';
              }
            }

            return {
              displayName: displayName,
              avatarURL: avatarURL,
              avatarCandidates: avatarCandidates,
              bioHTML: clone.innerHTML || '',
              panelHTML: panelHTML
            };
          }

          let lastSerialized = '';
          let pending = false;

          function postIfChanged() {
            const payload = collectPayload();
            if (!payload) { return; }

            let serialized = '';
            try { serialized = JSON.stringify(payload); } catch (_) { serialized = ''; }
            if (!serialized || serialized === lastSerialized) { return; }
            lastSerialized = serialized;

            try {
              window.webkit.messageHandlers.aboutPayload.postMessage({ payload: payload });
            } catch (_) {}
          }

          function schedule() {
            if (pending) { return; }
            pending = true;
            setTimeout(function() {
              pending = false;
              postIfChanged();
            }, 240);
          }

          postIfChanged();
          const observer = new MutationObserver(schedule);
          observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true });

          setTimeout(postIfChanged, 600);
          setTimeout(postIfChanged, 1300);
          setTimeout(postIfChanged, 2200);
          setTimeout(postIfChanged, 4200);
        })();
        """#,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.__glitcho_about_payload_v2 && true;", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "aboutPayload" else { return }
        guard let body = message.body as? [String: Any] else { return }
        guard let payload = body["payload"] as? [String: Any] else { return }
        guard let currentChannel else { return }

        let displayName = (payload["displayName"] as? String) ?? ""
        let payloadAvatarURL = (payload["avatarURL"] as? String) ?? ""
        let avatarCandidates = (payload["avatarCandidates"] as? [[String: Any]] ?? [])
            .compactMap(AboutAvatarCandidate.init(payload:))
        let avatarURL = AboutAvatarSelector.selectURL(
            channelName: currentChannel,
            payloadAvatarURL: payloadAvatarURL,
            candidates: avatarCandidates
        )
        let bioHTML = (payload["bioHTML"] as? String) ?? ""
        let panelHTML = payload["panelHTML"] as? [String] ?? []
        let signature = AboutHash.signature([currentChannel, displayName, avatarURL, bioHTML] + panelHTML)

        if currentPayloadSignature == signature {
            return
        }
        currentPayloadSignature = signature

        let raw = AboutRawPayload(
            channelName: currentChannel,
            displayName: displayName,
            avatarURL: avatarURL,
            bioHTML: bioHTML,
            panelHTML: panelHTML,
            signature: signature,
            fetchedAt: Date()
        )

        parseTask?.cancel()
        let parser = self.parser
        parseTask = Task.detached(priority: .utility) { [weak self] in
            if let cached = await AboutModelCache.shared.model(channelName: raw.channelName, signature: raw.signature) {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.currentChannel == raw.channelName else { return }
                    self.model = cached
                    self.isLoading = false
                    self.loadingDeadlineWorkItem?.cancel()
                    self.loadingDeadlineWorkItem = nil
                    self.instrumentation.usedCache = true
                    self.trackFirstRenderIfNeeded()
                }
                return
            }

            let parsed = parser.parse(payload: raw)
            if Task.isCancelled { return }

            await AboutModelCache.shared.set(
                parsed.model,
                channelName: raw.channelName,
                signature: raw.signature,
                lastUpdated: parsed.model.lastUpdated
            )

            await MainActor.run {
                guard let self, self.currentChannel == raw.channelName else { return }
                self.model = parsed.model
                self.isLoading = false
                self.lastError = nil
                self.loadingDeadlineWorkItem?.cancel()
                self.loadingDeadlineWorkItem = nil
                self.instrumentation.parseDurationMs = parsed.parseDurationMs
                self.trackFirstRenderIfNeeded()

                GlitchoTelemetry.track(
                    "about_parse_complete",
                    metadata: [
                        "channel": raw.channelName,
                        "parse_ms": String(format: "%.1f", parsed.parseDurationMs),
                        "panels": "\(parsed.model.panels.count)",
                        "social_links": "\(parsed.model.socialLinks.count)"
                    ]
                )
            }
        }
    }

    private func trackFirstRenderIfNeeded() {
        guard !firstRenderTracked else { return }
        guard model != nil else { return }
        firstRenderTracked = true
        let ttfrMs = max(0, (CFAbsoluteTimeGetCurrent() - loadStartedAt) * 1000)
        instrumentation.timeToFirstRenderMs = ttfrMs
        GlitchoTelemetry.track(
            "about_first_render",
            metadata: [
                "channel": currentChannel ?? "",
                "ttfr_ms": String(format: "%.1f", ttfrMs),
                "cache": instrumentation.usedCache ? "true" : "false"
            ]
        )
    }
}

// MARK: - Image Data Cache

enum AboutImageDataSource: String {
    case memory
    case disk
    case network
}

private struct AboutImageDataResult {
    let data: Data
    let source: AboutImageDataSource
}

actor AboutImageDataCache {
    static let shared = AboutImageDataCache()

    private let memory = NSCache<NSURL, NSData>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    init() {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base
            .appendingPathComponent("Glitcho", isDirectory: true)
            .appendingPathComponent("AboutImageCache", isDirectory: true)
        cacheDirectory = dir
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.countLimit = 240
    }

    fileprivate func data(for url: URL) async throws -> AboutImageDataResult {
        let key = url as NSURL
        if let cached = memory.object(forKey: key) {
            return AboutImageDataResult(data: cached as Data, source: .memory)
        }

        let diskURL = cacheDirectory.appendingPathComponent(AboutHash.sha256(url.absoluteString))
        if let diskData = try? Data(contentsOf: diskURL), !diskData.isEmpty {
            memory.setObject(diskData as NSData, forKey: key)
            return AboutImageDataResult(data: diskData, source: .disk)
        }

        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 16)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode), !data.isEmpty else {
            throw NSError(
                domain: "AboutImageDataCache",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load image \(url.absoluteString)"]
            )
        }

        memory.setObject(data as NSData, forKey: key)
        try? data.write(to: diskURL, options: .atomic)
        return AboutImageDataResult(data: data, source: .network)
    }
}

// MARK: - About UI

private struct AboutScraperBridgeView: NSViewRepresentable {
    @ObservedObject var store: AboutTabStore

    func makeNSView(context: Context) -> WKWebView {
        let view = store.attachWebView()
        view.isHidden = false
        view.alphaValue = 0.01
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.isHidden = false
        nsView.alphaValue = 0.01
    }
}

struct AboutTabView: View {
    let channelName: String
    @ObservedObject var store: AboutTabStore

    @State private var lightboxImage: AboutImageModel?

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width - 48)

            ScrollView {
                if let model = store.model {
                    aboutContent(model: model, availableWidth: availableWidth)
                } else if store.isLoading {
                    AboutLoadingStateView()
                        .padding(24)
                } else if let error = store.lastError {
                    AboutErrorStateView(message: error) { store.reload() }
                        .padding(24)
                } else {
                    AboutEmptyStateView { store.reload() }
                        .padding(24)
                }
            }
            .background(
                AboutScraperBridgeView(store: store)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .opacity(0.001)
            )
            .sheet(item: $lightboxImage) { image in
                ImageLightbox(image: image)
            }
        }
        .onAppear {
            store.load(channelName: channelName)
        }
        .onChange(of: channelName) { next in
            store.load(channelName: next)
        }
    }

    @ViewBuilder
    private func aboutContent(model: AboutModel, availableWidth: CGFloat) -> some View {
        let imagePanels = model.panels.filter { !$0.images.isEmpty }
        let textPanels = model.panels.filter { $0.images.isEmpty && !$0.bodyText.isEmpty }

        VStack(alignment: .leading, spacing: 0) {
            // ── Profile header ──
            AboutProfileHeader(
                displayName: model.displayName,
                avatarURL: model.avatarURL,
                bioBlocks: model.bioBlocks,
                socialLinks: model.socialLinks,
                onAvatarLoaded: { source in store.recordImageLoaded(source: source) }
            )
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 28)

            // ── Panel images as full-width banner row ──
            if !imagePanels.isEmpty {
                AboutPanelBannerRow(
                    panels: imagePanels,
                    availableWidth: availableWidth,
                    onImageTap: { lightboxImage = $0 },
                    onImageLoaded: { source in store.recordImageLoaded(source: source) }
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }

            // ── Text panels in horizontal flowing grid ──
            if !textPanels.isEmpty {
                AboutTextPanelsGrid(
                    panels: textPanels,
                    availableWidth: availableWidth
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Profile Header (avatar + bio + links in one horizontal section)

private struct AboutProfileHeader: View {
    let displayName: String
    let avatarURL: URL?
    let bioBlocks: [AboutRichTextBlock]
    let socialLinks: [AboutLinkModel]
    let onAvatarLoaded: (AboutImageDataSource) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            // Avatar
            AboutAvatarView(
                avatarURL: avatarURL,
                size: 88,
                onAvatarLoaded: onAvatarLoaded
            )

            // Name + Bio
            VStack(alignment: .leading, spacing: 8) {
                Text(displayName)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))

                if !bioBlocks.isEmpty {
                    RichTextRenderer(blocks: bioBlocks)
                }
            }
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .topLeading)

            // Social links (compact column on the right)
            if !socialLinks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LINKS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .tracking(1)

                    ForEach(socialLinks.prefix(8)) { link in
                        AboutCompactLinkRow(link: link)
                    }
                }
                .frame(width: 220, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Compact Link Row (for header)

private struct AboutCompactLinkRow: View {
    @Environment(\.openURL) private var openURL
    let link: AboutLinkModel
    @State private var isHovered = false

    var body: some View {
        Button {
            openURL(link.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: link.domain))
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                    .foregroundStyle(.purple.opacity(0.85))

                Text(link.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHovered ? .white.opacity(0.95) : .white.opacity(0.72))
                    .lineLimit(1)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(isHovered ? 0.6 : 0.3))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open Link") { openURL(link.url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            }
        }
    }

    private func icon(for domain: String) -> String {
        let value = domain.lowercased()
        if value.contains("discord") { return "message.fill" }
        if value.contains("youtube") { return "play.rectangle.fill" }
        if value.contains("twitter") || value.contains("x.com") { return "bubble.left.and.bubble.right.fill" }
        if value.contains("instagram") { return "camera.fill" }
        if value.contains("tiktok") { return "music.note" }
        if value.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if value.contains("twitch.tv") { return "tv.fill" }
        return "link.circle.fill"
    }
}

// MARK: - Panel Banners (image panels as horizontal scrolling row)

private struct AboutPanelBannerRow: View {
    let panels: [AboutPanelModel]
    let availableWidth: CGFloat
    let onImageTap: (AboutImageModel) -> Void
    let onImageLoaded: (AboutImageDataSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let allImages = panels.flatMap { $0.images }
            let bannerHeight: CGFloat = 200
            let singleRow = allImages.count <= 3

            if singleRow {
                HStack(spacing: 12) {
                    ForEach(allImages) { image in
                        AboutBannerImageCard(
                            image: image,
                            height: bannerHeight,
                            onTap: { onImageTap(image) },
                            onImageLoaded: onImageLoaded
                        )
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(allImages) { image in
                            AboutBannerImageCard(
                                image: image,
                                height: bannerHeight,
                                onTap: { onImageTap(image) },
                                onImageLoaded: onImageLoaded
                            )
                            .frame(width: min(360, availableWidth * 0.45))
                        }
                    }
                }
            }
        }
    }
}

private struct AboutBannerImageCard: View {
    @Environment(\.openURL) private var openURL
    let image: AboutImageModel
    let height: CGFloat
    let onTap: () -> Void
    let onImageLoaded: (AboutImageDataSource) -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            if let linked = image.linkedURL {
                openURL(linked)
            } else {
                onTap()
            }
        }) {
            ZStack(alignment: .bottomLeading) {
                AboutRemoteImage(
                    url: image.url,
                    aspectRatio: image.aspectHint ?? (16.0 / 9.0),
                    maxHeight: height,
                    onImageLoaded: onImageLoaded
                )

                if let caption = image.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(8)
                }

                if image.linkedURL != nil {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(6)
                                .background(.black.opacity(0.5))
                                .clipShape(Circle())
                                .padding(8)
                        }
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.2 : 0.08), lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open Image") { openURL(image.url) }
            if let linked = image.linkedURL {
                Button("Open Link Target") { openURL(linked) }
            }
            Button("Copy Image URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(image.url.absoluteString, forType: .string)
            }
        }
    }
}

// MARK: - Text Panels Grid (horizontal flowing cards)

private struct AboutTextPanelsGrid: View {
    let panels: [AboutPanelModel]
    let availableWidth: CGFloat

    var body: some View {
        let columns = availableWidth >= 700
            ? [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 16, alignment: .top)]
            : [GridItem(.flexible(minimum: 240), spacing: 16, alignment: .top)]

        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(panels) { panel in
                AboutTextPanelCard(panel: panel)
            }
        }
    }
}

private struct AboutTextPanelCard: View {
    let panel: AboutPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !panel.title.isEmpty {
                Text(panel.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(2)
            }

            if !panel.bodyBlocks.isEmpty {
                RichTextRenderer(blocks: panel.bodyBlocks)
            }

            let textLinks = panel.linkTargets.filter { !$0.isImageLink }
            if !textLinks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(textLinks) { link in
                        AboutCompactLinkRow(link: link)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// AboutHeaderView kept for backward compatibility with tests
struct AboutHeaderView: View {
    let displayName: String
    let avatarURL: URL?
    let bioText: String
    let panelCount: Int
    let lastUpdated: Date
    let onAvatarLoaded: (AboutImageDataSource) -> Void

    var body: some View {
        EmptyView()
    }
}

private struct AboutAvatarView: View {
    let avatarURL: URL?
    let size: CGFloat
    let onAvatarLoaded: (AboutImageDataSource) -> Void

    var body: some View {
        Group {
            if let avatarURL {
                AboutRemoteImage(
                    url: avatarURL,
                    aspectRatio: 1,
                    maxHeight: size,
                    onImageLoaded: onAvatarLoaded
                )
            } else {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                    Image(systemName: "person.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 2)
        .drawingGroup(opaque: false, colorMode: .extendedLinear)
    }
}

// Legacy types kept as stubs for backward compatibility
struct AboutInfoSidebar: View {
    let bioBlocks: [AboutRichTextBlock]
    let socialLinks: [AboutLinkModel]
    var body: some View { EmptyView() }
}

struct PanelCardView: View {
    let panel: AboutPanelModel
    let onImageTap: (AboutImageModel) -> Void
    let onImageLoaded: (AboutImageDataSource) -> Void
    var body: some View { EmptyView() }
}

struct RichTextRenderer: View {
    let blocks: [AboutRichTextBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                Text(attributed(block))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.78))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func attributed(_ block: AboutRichTextBlock) -> AttributedString {
        var output = AttributedString()
        for token in block.tokens {
            switch token {
            case .text(let value):
                var segment = AttributedString(value)
                segment.foregroundColor = .white.opacity(0.78)
                output.append(segment)
            case .emphasis(let value):
                var segment = AttributedString(value)
                segment.inlinePresentationIntent = .stronglyEmphasized
                segment.foregroundColor = .white.opacity(0.9)
                output.append(segment)
            case .link(let title, let url):
                var segment = AttributedString(title)
                segment.link = url
                segment.foregroundColor = .purple.opacity(0.95)
                output.append(segment)
            }
        }
        return output
    }
}

struct AboutRemoteImage: View {
    let url: URL
    let aspectRatio: CGFloat
    let maxHeight: CGFloat
    let onImageLoaded: (AboutImageDataSource) -> Void

    @State private var phase: Phase = .idle

    enum Phase {
        case idle
        case loading
        case success(NSImage)
        case failed
    }

    init(
        url: URL,
        aspectRatio: CGFloat,
        maxHeight: CGFloat,
        onImageLoaded: @escaping (AboutImageDataSource) -> Void
    ) {
        self.url = url
        self.aspectRatio = aspectRatio
        self.maxHeight = maxHeight
        self.onImageLoaded = onImageLoaded
    }

    var body: some View {
        ZStack {
            switch phase {
            case .idle, .loading:
                AboutShimmerPlaceholder()
            case .success(let image):
                Image(nsImage: image)
                    .interpolation(.high)
                    .resizable()
                    .scaledToFit()
            case .failed:
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Image unavailable")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.52))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.05))
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: maxHeight)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        if case .success = phase {
            return
        }
        phase = .loading
        do {
            let result = try await AboutImageDataCache.shared.data(for: url)
            guard let image = NSImage(data: result.data) else {
                phase = .failed
                return
            }
            phase = .success(image)
            onImageLoaded(result.source)
        } catch {
            phase = .failed
        }
    }
}

private struct AboutShimmerPlaceholder: View {
    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.02),
                            Color.white.opacity(0.14),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: animate ? geo.size.width : -geo.size.width)
                    .animation(
                        .linear(duration: 1.1).repeatForever(autoreverses: false),
                        value: animate
                    )
                )
                .onAppear {
                    animate = true
                }
        }
    }
}

struct ImageLightbox: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let image: AboutImageModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.95)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                AboutRemoteImage(
                    url: image.url,
                    aspectRatio: image.aspectHint ?? (16.0 / 9.0),
                    maxHeight: 820,
                    onImageLoaded: { _ in }
                )
                .padding(.horizontal, 22)
                .padding(.top, 50)

                HStack(spacing: 10) {
                    Button("Open Image") {
                        openURL(image.url)
                    }
                    .buttonStyle(.borderedProminent)

                    if let target = image.linkedURL {
                        Button("Open Link Target") {
                            openURL(target)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)

                Spacer(minLength: 20)
            }
        }
    }
}

private struct AboutLoadingStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading About panels…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }

            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 160)
                    .overlay(AboutShimmerPlaceholder().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
            }
        }
    }
}

private struct AboutErrorStateView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Could not load About", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.68))

            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AboutEmptyStateView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No About content available.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
            Text("This channel has no panels or the layout could not be parsed.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.58))
            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

#endif
