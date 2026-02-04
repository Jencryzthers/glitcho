import Foundation

final class RecordingManager: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var currentTarget: String?
    @Published private(set) var currentOutputURL: URL?

    private var process: Process?

    enum RecordingError: LocalizedError {
        case alreadyRecording
        case missingExecutable

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "Recording is already in progress."
            case .missingExecutable:
                return "Streamlink executable not found."
            }
        }
    }

    func startRecording(target: String, quality: String, outputURL: URL) throws {
        guard !isRecording else { throw RecordingError.alreadyRecording }
        guard let executableURL = resolveStreamlinkExecutable() else {
            throw RecordingError.missingExecutable
        }

        let resolvedTarget: String = {
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
            return "https://\(trimmed)"
        }()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            resolvedTarget,
            quality,
            "--twitch-disable-ads",
            "--twitch-low-latency",
            "--output",
            outputURL.path
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.cleanupAfterTermination()
            }
        }

        try process.run()
        self.process = process
        isRecording = true
        currentTarget = resolvedTarget
        currentOutputURL = outputURL
    }

    func stopRecording() {
        guard let process else { return }
        process.terminate()
        cleanupAfterTermination()
    }

    private func cleanupAfterTermination() {
        process = nil
        isRecording = false
        currentTarget = nil
        currentOutputURL = nil
    }

    private func resolveStreamlinkExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/streamlink",
            "/usr/local/bin/streamlink"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
