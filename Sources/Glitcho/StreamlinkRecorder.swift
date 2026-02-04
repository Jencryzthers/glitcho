import Foundation

#if canImport(SwiftUI)
import SwiftUI

@MainActor
final class StreamlinkRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var activeChannel: String?
    @Published var outputURL: URL?
    @Published var errorMessage: String?

    private let streamlinkURL = URL(fileURLWithPath: "/opt/homebrew/bin/streamlink")
    private let fileManager = FileManager.default
    private var process: Process?
    private var stopRequested = false

    func startRecording(channel: String, recordingsFolderPath: String) {
        guard !isRecording else {
            errorMessage = "A recording is already in progress."
            return
        }

        guard fileManager.isExecutableFile(atPath: streamlinkURL.path) else {
            errorMessage = "Streamlink binary not found at \(streamlinkURL.path)."
            return
        }

        guard !recordingsFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Choose a recordings folder in Settings before recording."
            return
        }

        let recordingsDirectory = URL(fileURLWithPath: recordingsFolderPath, isDirectory: true)
        do {
            try ensureWritableDirectory(recordingsDirectory)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let safeChannel = sanitizeChannelName(channel)
        let timestamp = Self.timestampString()
        let filename = "\(safeChannel)_\(timestamp).mp4"
        let outputURL = recordingsDirectory.appendingPathComponent(filename)

        let process = Process()
        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = streamlinkURL
        process.arguments = [
            "twitch.tv/\(channel)",
            "best",
            "--output",
            outputURL.path
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        stopRequested = false
        do {
            try process.run()
        } catch {
            errorMessage = "Failed to launch recorder: \(error.localizedDescription)"
            return
        }

        self.process = process
        isRecording = true
        activeChannel = channel
        self.outputURL = outputURL

        process.terminationHandler = { [weak self] task in
            let status = task.terminationStatus
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                self.process = nil
                self.activeChannel = nil
                self.outputURL = nil

                if self.stopRequested {
                    self.stopRequested = false
                    return
                }

                if status != 0 {
                    if let errorText, !errorText.isEmpty {
                        self.errorMessage = "Recording failed: \(errorText)"
                    } else {
                        self.errorMessage = "Recording stopped with exit status \(status)."
                    }
                }
            }
        }
    }

    func stopRecording() {
        guard let process else { return }
        stopRequested = true
        process.terminate()
    }

    private func ensureWritableDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw RecorderError.notDirectory(directory.path)
            }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw RecorderError.notWritable(directory.path)
        }
    }

    private func sanitizeChannelName(_ channel: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = channel.lowercased().map { character -> String in
            let scalar = String(character).unicodeScalars
            if scalar.allSatisfy({ allowed.contains($0) }) {
                return String(character)
            }
            return "_"
        }.joined()
        return cleaned.isEmpty ? "channel" : cleaned
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    enum RecorderError: LocalizedError {
        case notDirectory(String)
        case notWritable(String)

        var errorDescription: String? {
            switch self {
            case .notDirectory(let path):
                return "Recordings path is not a directory: \(path)"
            case .notWritable(let path):
                return "Recordings folder is not writable: \(path)"
            }
        }
    }
}

#endif
