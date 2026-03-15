#if canImport(SwiftUI)
import AVFoundation

// MARK: - ClipExtractor

/// Extracts a time-range sub-clip from a video file using AVAssetExportSession.
///
/// All work is performed off the main thread. Call ``extractClip(from:startTime:endTime:outputURL:)``
/// from any async context; it returns when the export finishes or throws on failure.
///
/// Example:
/// ```swift
/// let extractor = ClipExtractor()
/// try await extractor.extractClip(
///     from: sourceURL,
///     startTime: CMTime(seconds: 30, preferredTimescale: 600),
///     endTime:   CMTime(seconds: 90, preferredTimescale: 600),
///     outputURL: destinationURL
/// )
/// ```
final class ClipExtractor: Sendable {

    // MARK: - Errors

    /// Errors that ``extractClip(from:startTime:endTime:outputURL:)`` can throw.
    enum ExtractionError: LocalizedError {
        case unableToCreateExportSession
        case exportFailed(AVAssetExportSession.Status, String?)
        case invalidTimeRange

        var errorDescription: String? {
            switch self {
            case .unableToCreateExportSession:
                return "Unable to create an export session for this file. The format may not be supported."
            case .exportFailed(let status, let detail):
                let suffix = detail.map { ": \($0)" } ?? ""
                return "Export failed with status \(status.rawValue)\(suffix)."
            case .invalidTimeRange:
                return "The start time must be earlier than the end time."
            }
        }
    }

    // MARK: - Init

    init() {}

    // MARK: - Public API

    /// Extracts the time range [startTime, endTime] from the video at `sourceURL` and writes
    /// the result to `outputURL`.
    ///
    /// - Parameters:
    ///   - sourceURL:  URL of the source video file.
    ///   - startTime:  Inclusive start of the range to extract.
    ///   - endTime:    Exclusive end of the range to extract.
    ///   - outputURL:  Destination file URL. The file must **not** already exist; the caller is
    ///                 responsible for removing any pre-existing file beforehand.
    ///   - preset:     AVAssetExportPreset string. Defaults to `AVAssetExportPresetPassthrough`
    ///                 for maximum speed and lossless quality. Pass
    ///                 `AVAssetExportPresetHighestQuality` if the source format requires
    ///                 transcoding (e.g. HEVC to H.264).
    func extractClip(
        from sourceURL: URL,
        startTime: CMTime,
        endTime: CMTime,
        outputURL: URL,
        preset: String = AVAssetExportPresetPassthrough
    ) async throws {
        guard CMTimeCompare(startTime, endTime) < 0 else {
            throw ExtractionError.invalidTimeRange
        }

        let asset = AVURLAsset(url: sourceURL)

        // Derive a file type that matches the output extension, falling back to MP4.
        let fileType = outputFileType(for: outputURL)

        // Prefer passthrough; fall back to the caller-supplied preset if passthrough is
        // not compatible with the target file type.
        let resolvedPreset: String
        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        if compatiblePresets.contains(preset) {
            resolvedPreset = preset
        } else if compatiblePresets.contains(AVAssetExportPresetHighestQuality) {
            resolvedPreset = AVAssetExportPresetHighestQuality
        } else {
            resolvedPreset = compatiblePresets.first ?? AVAssetExportPresetHighestQuality
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: resolvedPreset) else {
            throw ExtractionError.unableToCreateExportSession
        }

        session.outputURL = outputURL
        session.outputFileType = fileType
        session.timeRange = CMTimeRange(start: startTime, end: endTime)
        session.shouldOptimizeForNetworkUse = true

        await session.export()

        let status = session.status
        switch status {
        case .completed:
            return
        case .cancelled:
            throw ExtractionError.exportFailed(.cancelled, "Export was cancelled.")
        default:
            let detail = session.error?.localizedDescription
            throw ExtractionError.exportFailed(status, detail)
        }
    }

    // MARK: - Private helpers

    private func outputFileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mov":
            return .mov
        case "m4v":
            return .m4v
        case "m4a":
            return .m4a
        default:
            return .mp4
        }
    }
}
#endif
