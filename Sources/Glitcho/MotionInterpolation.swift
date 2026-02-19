#if canImport(SwiftUI)
import Foundation
import AppKit
import AVFoundation
import AVKit
import CoreImage
import Darwin
import Metal
import MetalKit
import QuartzCore
import Vision

extension Notification.Name {
    static let motionInterpolationRuntimeUpdated = Notification.Name("glitcho.motionInterpolation.runtimeUpdated")
}

struct MotionInterpolationRuntimeStatus {
    let method: String
    let fallbackReason: String
    let cpuLoadPercent: Double?
    let gpuRenderMs: Double?
    let interpolationMs: Double
    let motionMagnitude: Float
    let renderedFrames: Int
    let interpolatedFrames: Int
    let fallbackFrames: Int
    let sourceFPS: Double
    let generatedFPS: Double
    let effectiveFPS: Double
}

enum MotionAIInterpolationSupport {
    static func isAvailable() -> Bool {
        if #available(macOS 11.0, *) {
            return true
        }
        return false
    }
}

final class MotionInterpolationController {
    private weak var hostView: NSView?
    private var interpolationView: MotionInterpolationMetalView?

    func enable(
        on playerView: AVPlayerView,
        player: AVPlayer,
        capability: MotionSmootheningCapability,
        configuration: MotionInterpolationConfiguration,
        interpolationEnabled: Bool,
        imageOptimizeEnabled: Bool = false,
        imageOptimizationConfiguration: ImageOptimizationConfiguration = .productionDefault,
        allowWithoutAISupport: Bool = false
    ) {
        if !capability.supported && !allowWithoutAISupport {
            disable()
            return
        }

        let host = playerView.contentOverlayView ?? playerView
        let interpolationView: MotionInterpolationMetalView

        if let existing = self.interpolationView {
            interpolationView = existing
            if existing.superview !== host {
                existing.removeFromSuperview()
            }
        } else {
            interpolationView = MotionInterpolationMetalView()
            self.interpolationView = interpolationView
        }

        if interpolationView.superview == nil {
            interpolationView.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(interpolationView, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                interpolationView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                interpolationView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                interpolationView.topAnchor.constraint(equalTo: host.topAnchor),
                interpolationView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
            hostView = host
        }

        interpolationView.isHidden = false
        interpolationView.configure(
            player: player,
            maxRefreshRate: capability.maxRefreshRate,
            configuration: configuration,
            interpolationEnabled: interpolationEnabled,
            imageOptimizeEnabled: imageOptimizeEnabled,
            imageOptimizationConfiguration: imageOptimizationConfiguration
        )
        interpolationView.setEnabled(true)
    }

    func disable() {
        interpolationView?.setEnabled(false)
        interpolationView?.isHidden = true
    }

    func teardown() {
        interpolationView?.setEnabled(false)
        interpolationView?.removeFromSuperview()
        interpolationView = nil
        hostView = nil
    }

    func updateViewport(zoom: CGFloat, pan: CGSize) {
        interpolationView?.updateViewport(
            zoom: zoom,
            pan: pan,
            aspectMode: .source,
            upscaler4KEnabled: false,
            imageOptimizeEnabled: false,
            imageOptimizationConfiguration: .productionDefault
        )
    }

    func updateViewport(
        zoom: CGFloat,
        pan: CGSize,
        aspectMode: VideoAspectCropMode,
        upscaler4KEnabled: Bool,
        imageOptimizeEnabled: Bool,
        imageOptimizationConfiguration: ImageOptimizationConfiguration = .productionDefault
    ) {
        interpolationView?.updateViewport(
            zoom: zoom,
            pan: pan,
            aspectMode: aspectMode,
            upscaler4KEnabled: upscaler4KEnabled,
            imageOptimizeEnabled: imageOptimizeEnabled,
            imageOptimizationConfiguration: imageOptimizationConfiguration
        )
    }

    func refreshOutput() {
        interpolationView?.refreshOutput()
    }
}

private struct MotionInterpolationResult {
    let image: CIImage
    let method: String
    let fallbackReason: String?
    let elapsedMs: Double
    let motionMagnitude: Float?
}

struct MotionInterpolationDecision: Equatable {
    let usesOpticalFlowWarp: Bool
    let blendTime: Double
    let blendReason: String?
}

enum MotionInterpolationHeuristics {
    // Mixed multi-direction vectors (low coherence) often produce ghosting/artifacts.
    private static let minimumCoherenceForOpticalFlow: Float = 0.24

    static func decision(
        motionMagnitude: Float,
        coherence: Float,
        configuration: MotionInterpolationConfiguration
    ) -> MotionInterpolationDecision {
        let magnitude = motionMagnitude.isFinite ? max(0, motionMagnitude) : 0
        let normalizedCoherence = coherence.isFinite ? max(0, min(1, coherence)) : 0

        if normalizedCoherence < minimumCoherenceForOpticalFlow {
            return MotionInterpolationDecision(
                usesOpticalFlowWarp: false,
                blendTime: 0.5,
                blendReason: "low_coherence"
            )
        }

        if magnitude >= configuration.extremeMotionThreshold {
            return MotionInterpolationDecision(
                usesOpticalFlowWarp: false,
                blendTime: 0.42,
                blendReason: "extreme_motion"
            )
        }

        if magnitude <= configuration.lowMotionThreshold {
            return MotionInterpolationDecision(
                usesOpticalFlowWarp: false,
                blendTime: 0.5,
                blendReason: "low_motion"
            )
        }

        if magnitude >= configuration.highMotionThreshold {
            return MotionInterpolationDecision(
                usesOpticalFlowWarp: false,
                blendTime: 0.4,
                blendReason: "high_motion"
            )
        }

        return MotionInterpolationDecision(
            usesOpticalFlowWarp: true,
            blendTime: 0.5,
            blendReason: nil
        )
    }
}

struct MotionInterpolationConfiguration: Equatable {
    // Average optical-flow magnitude in pixels.
    var lowMotionThreshold: Float
    var highMotionThreshold: Float
    var extremeMotionThreshold: Float

    // Scale for midpoint warp from estimated flow vector.
    var midpointShiftFactor: CGFloat
    var maxMidpointShiftPixels: CGFloat

    // Runtime guardrails.
    var maxInterpolationBudgetMs: Double
    var consecutiveSlowFramesForGuardrail: Int
    var overloadGuardrailDurationSeconds: Double
    var cpuPressurePercent: Double
    var guardrailsEnabled: Bool

    static let quality = MotionInterpolationConfiguration(
        lowMotionThreshold: 0.08,
        highMotionThreshold: 3.2,
        extremeMotionThreshold: 7.6,
        midpointShiftFactor: 0.48,
        maxMidpointShiftPixels: 16.0,
        maxInterpolationBudgetMs: 9.0,
        consecutiveSlowFramesForGuardrail: 4,
        overloadGuardrailDurationSeconds: 5.0,
        cpuPressurePercent: 84.0,
        guardrailsEnabled: true
    )

    static let balanced = MotionInterpolationConfiguration(
        lowMotionThreshold: 0.1,
        highMotionThreshold: 2.7,
        extremeMotionThreshold: 6.8,
        midpointShiftFactor: 0.42,
        maxMidpointShiftPixels: 14.0,
        maxInterpolationBudgetMs: 7.4,
        consecutiveSlowFramesForGuardrail: 3,
        overloadGuardrailDurationSeconds: 6.0,
        cpuPressurePercent: 78.0,
        guardrailsEnabled: true
    )

    static let performance = MotionInterpolationConfiguration(
        lowMotionThreshold: 0.14,
        highMotionThreshold: 2.1,
        extremeMotionThreshold: 5.8,
        midpointShiftFactor: 0.36,
        maxMidpointShiftPixels: 12.0,
        maxInterpolationBudgetMs: 6.2,
        consecutiveSlowFramesForGuardrail: 2,
        overloadGuardrailDurationSeconds: 8.0,
        cpuPressurePercent: 70.0,
        guardrailsEnabled: true
    )

    static let productionDefault = MotionInterpolationConfiguration.balanced
}

struct ImageOptimizationConfiguration: Equatable {
    var contrast: Double
    var lighting: Double
    var denoiser: Double
    var neuralClarity: Double

    static let productionDefault = ImageOptimizationConfiguration(
        contrast: 1.12,
        lighting: 0.01,
        denoiser: 0.5,
        neuralClarity: 0.45
    )

    var clamped: ImageOptimizationConfiguration {
        ImageOptimizationConfiguration(
            contrast: max(0.8, min(1.5, contrast)),
            lighting: max(-0.15, min(0.15, lighting)),
            denoiser: max(0.0, min(1.0, denoiser)),
            neuralClarity: max(0.0, min(1.0, neuralClarity))
        )
    }
}

private final class MotionInterpolator {
    enum InterpolationError: Error {
        case missingResult
    }

    func generateIntermediateFrame(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        configuration: MotionInterpolationConfiguration
    ) -> MotionInterpolationResult {
        let start = CACurrentMediaTime()

        guard MotionAIInterpolationSupport.isAvailable() else {
            return MotionInterpolationResult(
                image: dissolve(
                    previous: CIImage(cvPixelBuffer: previous),
                    current: CIImage(cvPixelBuffer: current),
                    time: 0.5
                ),
                method: "blend_fallback",
                fallbackReason: "optical_flow_unavailable",
                elapsedMs: (CACurrentMediaTime() - start) * 1000,
                motionMagnitude: nil
            )
        }

        do {
            let strategy = try opticalFlowGuidedFrame(
                previous: previous,
                current: current,
                configuration: configuration
            )
            return MotionInterpolationResult(
                image: strategy.image,
                method: strategy.method,
                fallbackReason: strategy.reason,
                elapsedMs: (CACurrentMediaTime() - start) * 1000,
                motionMagnitude: strategy.magnitude
            )
        } catch {
            return MotionInterpolationResult(
                image: dissolve(
                    previous: CIImage(cvPixelBuffer: previous),
                    current: CIImage(cvPixelBuffer: current),
                    time: 0.5
                ),
                method: "blend_fallback",
                fallbackReason: "optical_flow_error",
                elapsedMs: (CACurrentMediaTime() - start) * 1000,
                motionMagnitude: nil
            )
        }
    }

    func generateGuardrailBlendFrame(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        guardrailReason: String
    ) -> MotionInterpolationResult {
        let start = CACurrentMediaTime()
        let image = dissolve(
            previous: CIImage(cvPixelBuffer: previous),
            current: CIImage(cvPixelBuffer: current),
            time: 0.5
        )
        return MotionInterpolationResult(
            image: image,
            method: "blend_guardrail",
            fallbackReason: guardrailReason,
            elapsedMs: (CACurrentMediaTime() - start) * 1000,
            motionMagnitude: nil
        )
    }

    private func opticalFlowGuidedFrame(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        configuration: MotionInterpolationConfiguration
    ) throws -> (image: CIImage, magnitude: Float, method: String, reason: String?) {
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: current, options: [:])
        request.computationAccuracy = .low
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float

        let handler = VNImageRequestHandler(cvPixelBuffer: previous, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNPixelBufferObservation else {
            throw InterpolationError.missingResult
        }

        let stats = averageFlowStats(from: observation.pixelBuffer)
        let previousImage = CIImage(cvPixelBuffer: previous)
        let currentImage = CIImage(cvPixelBuffer: current)
        let extent = currentImage.extent

        let maxComponent = max(abs(stats.avgX), abs(stats.avgY))
        guard maxComponent.isFinite else {
            throw InterpolationError.missingResult
        }

        let decision = MotionInterpolationHeuristics.decision(
            motionMagnitude: stats.magnitude,
            coherence: stats.coherence,
            configuration: configuration
        )
        if !decision.usesOpticalFlowWarp {
            let blended = dissolve(previous: previousImage, current: currentImage, time: decision.blendTime)
            return (blended, stats.magnitude, "blend_policy", decision.blendReason)
        }

        // Translate both source frames toward the midpoint using optical-flow direction.
        // This approximates a generated in-between frame without distorting geometry.
        let maxShift = min(configuration.maxMidpointShiftPixels, max(4.0, extent.width * 0.016))
        let shiftX = max(
            -maxShift,
            min(maxShift, CGFloat(stats.avgX) * configuration.midpointShiftFactor)
        )
        let shiftY = max(
            -maxShift,
            min(maxShift, CGFloat(stats.avgY) * configuration.midpointShiftFactor)
        )
        let previousShifted = previousImage
            .transformed(by: CGAffineTransform(translationX: shiftX, y: shiftY))
            .cropped(to: extent)
        let currentShifted = currentImage
            .transformed(by: CGAffineTransform(translationX: -shiftX, y: -shiftY))
            .cropped(to: extent)

        let radius = max(0.6, min(4.8, CGFloat(stats.magnitude * 12.0)))
        let angle = stats.angle

        let previousMotionCompensated = previousShifted
            .clampedToExtent()
            .applyingFilter(
                "CIMotionBlur",
                parameters: [
                    kCIInputRadiusKey: radius,
                    kCIInputAngleKey: angle
                ]
            )
            .cropped(to: extent)

        let currentMotionCompensated = currentShifted
            .clampedToExtent()
            .applyingFilter(
                "CIMotionBlur",
                parameters: [
                    kCIInputRadiusKey: radius * 0.7,
                    kCIInputAngleKey: angle + .pi
                ]
            )
            .cropped(to: extent)

        let midpointBlend = dissolve(previous: previousMotionCompensated, current: currentMotionCompensated, time: 0.5)
        let sharpened = midpointBlend
            .applyingFilter(
                "CISharpenLuminance",
                parameters: [
                    kCIInputSharpnessKey: 0.1
                ]
            )
            .cropped(to: extent)

        return (sharpened, stats.magnitude, "optical_flow", nil)
    }

    private func dissolve(previous: CIImage, current: CIImage, time: Double) -> CIImage {
        let previous = previous.cropped(to: current.extent)
        guard let filter = CIFilter(name: "CIDissolveTransition") else {
            return previous.composited(over: current).cropped(to: current.extent)
        }

        filter.setValue(previous, forKey: kCIInputImageKey)
        filter.setValue(current, forKey: kCIInputTargetImageKey)
        filter.setValue(time, forKey: kCIInputTimeKey)

        return filter.outputImage?.cropped(to: current.extent) ?? previous.composited(over: current).cropped(to: current.extent)
    }

    private func averageFlowStats(from pixelBuffer: CVPixelBuffer) -> (
        avgX: Float,
        avgY: Float,
        magnitude: Float,
        angle: CGFloat,
        coherence: Float
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return (0, 0, 0, 0, 1)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let floatsPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<Float>.stride
        let pointer = baseAddress.assumingMemoryBound(to: Float.self)

        let step = max(2, min(width, height) / 48)
        var sumX: Float = 0
        var sumY: Float = 0
        var sumMagnitude: Float = 0
        var count: Float = 0

        for y in stride(from: 0, to: height, by: step) {
            let row = pointer.advanced(by: y * floatsPerRow)
            for x in stride(from: 0, to: width, by: step) {
                let index = x * 2
                let fx = row[index]
                let fy = row[index + 1]
                guard fx.isFinite, fy.isFinite else { continue }
                sumX += fx
                sumY += fy
                sumMagnitude += hypotf(fx, fy)
                count += 1
            }
        }

        guard count > 0 else {
            return (0, 0, 0, 0, 1)
        }

        let avgX = sumX / count
        let avgY = sumY / count
        let avgMagnitude = sumMagnitude / count
        let avgVectorMagnitude = hypotf(avgX, avgY)
        let coherence: Float
        if avgMagnitude > .ulpOfOne {
            coherence = max(0, min(1, avgVectorMagnitude / avgMagnitude))
        } else {
            coherence = 1
        }

        let angle: CGFloat = avgVectorMagnitude > .ulpOfOne ? CGFloat(atan2(avgY, avgX)) : 0
        return (avgX, avgY, avgMagnitude, angle, coherence)
    }
}

private struct MotionInterpolationTelemetry {
    var renderedFrames: Int = 0
    var interpolatedFrames: Int = 0
    var fallbackFrames: Int = 0
    var droppedFrames: Int = 0
    var lastMethod: String = "none"
    var lastFallbackReason: String = "none"
    var lastInterpolationMs: Double = 0
    var lastMotionMagnitude: Float = 0
    var lastCPULoadPercent: Double = 0
    var lastGPURenderMs: Double = 0
}

private final class CPUUsageSampler {
    private var lastSample: (timestamp: CFTimeInterval, usage: rusage)?

    func currentProcessCPUPercent() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let now = CACurrentMediaTime()
        defer { lastSample = (now, usage) }

        guard let previous = lastSample else { return nil }
        let wallDelta = max(0.0001, now - previous.timestamp)
        let userDelta = timeInterval(from: usage.ru_utime) - timeInterval(from: previous.usage.ru_utime)
        let systemDelta = timeInterval(from: usage.ru_stime) - timeInterval(from: previous.usage.ru_stime)
        let cpuDelta = max(0, userDelta + systemDelta)
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

        let normalized = (cpuDelta / (wallDelta * cores)) * 100.0
        return max(0, min(100, normalized))
    }

    private func timeInterval(from value: timeval) -> Double {
        Double(value.tv_sec) + (Double(value.tv_usec) / 1_000_000.0)
    }
}

private final class PassthroughMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class MotionInterpolationMetalView: NSView, MTKViewDelegate {
    private let metalDevice: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext?
    private let metalView: PassthroughMTKView
    private let interpolator = MotionInterpolator()
    private let interpolationQueue = DispatchQueue(label: "glitcho.motion.interpolation", qos: .userInitiated)
    private let stateLock = NSLock()

    private weak var player: AVPlayer?
    private weak var attachedItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?

    private var latestFrame: CVPixelBuffer?
    private var pendingInterpolatedFrame: CIImage?
    private var interpolationInFlight = false

    private var zoom: CGFloat = 1.0
    private var pan: CGSize = .zero
    private var aspectMode: VideoAspectCropMode = .source
    private var motionInterpolationEnabled = true
    private var upscaler4KEnabled = false
    private var imageOptimizeEnabled = false
    private var imageOptimizationConfiguration = ImageOptimizationConfiguration.productionDefault
    private var configuration = MotionInterpolationConfiguration.productionDefault
    private var isEnabled = false
    private var telemetry = MotionInterpolationTelemetry()
    private var lastTelemetryTimestamp: CFTimeInterval = 0
    private var lastGuardrailCheckTimestamp: CFTimeInterval = 0
    private var interpolationGuardrailReason: String?
    private var overloadGuardrailUntil: CFTimeInterval = 0
    private var consecutiveSlowInterpolations: Int = 0
    private var consecutiveDroppedFrames: Int = 0
    private var latestGPURenderMs: Double = 0
    private var lastPublishedRuntimeSample: (timestamp: CFTimeInterval, rendered: Int, interpolated: Int)?

    private let cpuUsageSampler = CPUUsageSampler()

    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    override init(frame frameRect: NSRect) {
        let device = MTLCreateSystemDefaultDevice()
        metalDevice = device
        commandQueue = device?.makeCommandQueue()
        ciContext = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }

        metalView = PassthroughMTKView(frame: .zero, device: device)
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = true
        metalView.preferredFramesPerSecond = 60
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = false

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.delegate = self
        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        detachOutput()
    }

    func configure(
        player: AVPlayer,
        maxRefreshRate: Int,
        configuration: MotionInterpolationConfiguration,
        interpolationEnabled: Bool,
        imageOptimizeEnabled: Bool,
        imageOptimizationConfiguration: ImageOptimizationConfiguration
    ) {
        self.player = player
        stateLock.lock()
        self.configuration = configuration
        self.motionInterpolationEnabled = interpolationEnabled
        self.imageOptimizeEnabled = imageOptimizeEnabled
        self.imageOptimizationConfiguration = imageOptimizationConfiguration.clamped
        stateLock.unlock()
        metalView.preferredFramesPerSecond = max(60, min(maxRefreshRate, 120))
        attachOutputIfNeeded(force: false)
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else {
            if enabled {
                attachOutputIfNeeded(force: false)
            }
            return
        }

        isEnabled = enabled
        metalView.isPaused = !enabled
        if enabled {
            attachOutputIfNeeded(force: true)
        } else {
            detachOutput()
            stateLock.lock()
            latestFrame = nil
            pendingInterpolatedFrame = nil
            interpolationInFlight = false
            interpolationGuardrailReason = nil
            overloadGuardrailUntil = 0
            consecutiveSlowInterpolations = 0
            consecutiveDroppedFrames = 0
            lastPublishedRuntimeSample = nil
            stateLock.unlock()
        }
    }

    func updateViewport(
        zoom: CGFloat,
        pan: CGSize,
        aspectMode: VideoAspectCropMode,
        upscaler4KEnabled: Bool,
        imageOptimizeEnabled: Bool,
        imageOptimizationConfiguration: ImageOptimizationConfiguration
    ) {
        stateLock.lock()
        self.zoom = zoom
        self.pan = pan
        self.aspectMode = aspectMode
        self.upscaler4KEnabled = upscaler4KEnabled
        self.imageOptimizeEnabled = imageOptimizeEnabled
        self.imageOptimizationConfiguration = imageOptimizationConfiguration.clamped
        stateLock.unlock()
    }

    func refreshOutput() {
        guard isEnabled else { return }
        attachOutputIfNeeded(force: true)
        videoOutput?.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
    }

    private func attachOutputIfNeeded(force: Bool) {
        guard isEnabled, let player, let item = player.currentItem else {
            detachOutput()
            return
        }

        if !force, attachedItem === item, videoOutput != nil {
            return
        }

        detachOutput()

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])

        output.suppressesPlayerRendering = true
        item.add(output)
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)

        attachedItem = item
        videoOutput = output
        stateLock.lock()
        latestFrame = nil
        pendingInterpolatedFrame = nil
        interpolationInFlight = false
        consecutiveDroppedFrames = 0
        lastPublishedRuntimeSample = nil
        let currentTime = item.currentTime()
        if currentTime.isValid,
           let seed = output.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) {
            latestFrame = seed
        }
        stateLock.unlock()
    }

    private func detachOutput() {
        if let output = videoOutput {
            output.suppressesPlayerRendering = false
            attachedItem?.remove(output)
        }
        attachedItem = nil
        videoOutput = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard isEnabled else { return }
        refreshGuardrailsIfNeeded(now: CACurrentMediaTime())

        let currentPlayer = player
        if let currentPlayer, attachedItem !== currentPlayer.currentItem {
            DispatchQueue.main.async { [weak self] in
                self?.attachOutputIfNeeded(force: true)
            }
        }

        guard let output = videoOutput else {
            renderBlackFrame(in: view)
            return
        }

        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let newFrame = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            consumeNewFrame(newFrame)
        } else if latestFrame == nil {
            var seededFrame: CVPixelBuffer?
            if itemTime.isValid {
                seededFrame = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
            }
            if seededFrame == nil,
               let itemTimeNow = currentPlayer?.currentItem?.currentTime(),
               itemTimeNow.isValid {
                seededFrame = output.copyPixelBuffer(forItemTime: itemTimeNow, itemTimeForDisplay: nil)
            }
            if let seededFrame {
                stateLock.lock()
                latestFrame = seededFrame
                stateLock.unlock()
            }
        }

        let image = nextImageForDisplay()
        render(image: image, in: view)
        emitTelemetryIfNeeded()
    }

    private func consumeNewFrame(_ frame: CVPixelBuffer) {
        var previousFrame: CVPixelBuffer?
        var shouldScheduleInterpolation = false
        var scheduleGuardrailBlend = false
        var guardrailReason: String?
        var configuration = MotionInterpolationConfiguration.productionDefault
        var interpolationEnabled = false

        stateLock.lock()
        previousFrame = latestFrame
        latestFrame = frame
        configuration = self.configuration
        interpolationEnabled = motionInterpolationEnabled
        guardrailReason = configuration.guardrailsEnabled ? interpolationGuardrailReason : nil
        telemetry.renderedFrames += 1
        if interpolationEnabled, let guardrailReason, previousFrame != nil, !interpolationInFlight {
            interpolationInFlight = true
            shouldScheduleInterpolation = true
            scheduleGuardrailBlend = true
            telemetry.lastMethod = "blend_guardrail"
            telemetry.lastFallbackReason = guardrailReason
        } else if interpolationEnabled, previousFrame != nil, !interpolationInFlight {
            interpolationInFlight = true
            shouldScheduleInterpolation = true
        }
        stateLock.unlock()

        guard shouldScheduleInterpolation, let previousFrame else { return }

        interpolationQueue.async { [weak self] in
            guard let self else { return }
            let result: MotionInterpolationResult
            if scheduleGuardrailBlend {
                result = self.interpolator.generateGuardrailBlendFrame(
                    previous: previousFrame,
                    current: frame,
                    guardrailReason: guardrailReason ?? "guardrail"
                )
            } else {
                result = self.interpolator.generateIntermediateFrame(
                    previous: previousFrame,
                    current: frame,
                    configuration: configuration
                )
            }
            let timestamp = CACurrentMediaTime()

            self.stateLock.lock()
            self.pendingInterpolatedFrame = result.image
            self.interpolationInFlight = false
            self.telemetry.lastMethod = result.method
            self.telemetry.lastInterpolationMs = result.elapsedMs
            self.telemetry.lastMotionMagnitude = result.motionMagnitude ?? 0
            if scheduleGuardrailBlend {
                self.consecutiveSlowInterpolations = 0
            } else if configuration.guardrailsEnabled, result.elapsedMs > configuration.maxInterpolationBudgetMs {
                self.consecutiveSlowInterpolations += 1
                if self.consecutiveSlowInterpolations >= configuration.consecutiveSlowFramesForGuardrail {
                    self.overloadGuardrailUntil = timestamp + configuration.overloadGuardrailDurationSeconds
                    self.interpolationGuardrailReason = "interpolation_over_budget"
                }
            } else {
                self.consecutiveSlowInterpolations = 0
            }
            if result.method == "optical_flow" || result.method == "blend_policy" || result.method == "blend_guardrail" {
                self.telemetry.interpolatedFrames += 1
            }
            if let reason = result.fallbackReason, !reason.isEmpty, reason != "none" {
                self.telemetry.fallbackFrames += 1
                self.telemetry.lastFallbackReason = reason
            } else {
                self.telemetry.lastFallbackReason = "none"
            }
            self.stateLock.unlock()
        }
    }

    private func nextImageForDisplay() -> CIImage? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let pending = pendingInterpolatedFrame {
            pendingInterpolatedFrame = nil
            consecutiveDroppedFrames = 0
            return pending
        }

        guard let latestFrame else {
            telemetry.droppedFrames += 1
            consecutiveDroppedFrames += 1
            if configuration.guardrailsEnabled, consecutiveDroppedFrames >= 4 {
                overloadGuardrailUntil = CACurrentMediaTime() + configuration.overloadGuardrailDurationSeconds
                interpolationGuardrailReason = "dropped_frames"
            }
            return nil
        }
        consecutiveDroppedFrames = 0
        return CIImage(cvPixelBuffer: latestFrame)
    }

    private func renderBlackFrame(in view: MTKView) {
        let black = CIImage(color: CIColor.black).cropped(to: CGRect(origin: .zero, size: CGSize(width: view.drawableSize.width, height: view.drawableSize.height)))
        render(image: black, in: view)
    }

    private func render(image: CIImage?, in view: MTKView) {
        guard let image,
              let drawable = view.currentDrawable,
              let commandQueue,
              let ciContext,
              view.drawableSize.width > 0,
              view.drawableSize.height > 0,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let drawableBounds = CGRect(origin: .zero, size: CGSize(width: view.drawableSize.width, height: view.drawableSize.height))
        let composed = compose(image: image, in: drawableBounds)

        ciContext.render(
            composed,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: drawableBounds,
            colorSpace: colorSpace
        )
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            let start = buffer.gpuStartTime
            let end = buffer.gpuEndTime
            guard end > start, start > 0 else { return }
            let elapsedMs = (end - start) * 1000.0
            self.stateLock.lock()
            self.latestGPURenderMs = elapsedMs
            self.stateLock.unlock()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func compose(image: CIImage, in bounds: CGRect) -> CIImage {
        stateLock.lock()
        let currentZoom = max(1.0, zoom)
        let currentPan = pan
        let currentAspectMode = aspectMode
        let imageOptimizeEnabled = self.imageOptimizeEnabled
        let imageOptimizationConfiguration = self.imageOptimizationConfiguration
        let upscalerEnabled = upscaler4KEnabled
        stateLock.unlock()

        var workingImage = image
        if imageOptimizeEnabled {
            workingImage = optimizeImageQualityIfNeeded(
                image: workingImage,
                configuration: imageOptimizationConfiguration
            )
        }
        if upscalerEnabled {
            workingImage = upscaleTo4KIfNeeded(image: workingImage)
        }

        let imageExtent = workingImage.extent.integral
        guard imageExtent.width > 0, imageExtent.height > 0 else {
            return CIImage(color: CIColor.black).cropped(to: bounds)
        }

        let baseScale = min(bounds.width / imageExtent.width, bounds.height / imageExtent.height)
        let sourceAspect = imageExtent.width / imageExtent.height
        let cropMultiplier: CGFloat = {
            guard let target = currentAspectMode.targetAspectRatio, target > sourceAspect else {
                return 1.0
            }
            return target / sourceAspect
        }()
        let effectiveZoom = currentZoom * cropMultiplier

        let scaledWidth = imageExtent.width * baseScale * effectiveZoom
        let scaledHeight = imageExtent.height * baseScale * effectiveZoom

        let originX = ((bounds.width - scaledWidth) / 2.0) + currentPan.width
        let originY = ((bounds.height - scaledHeight) / 2.0) + currentPan.height

        var transformed = workingImage.transformed(by: CGAffineTransform(translationX: -imageExtent.origin.x, y: -imageExtent.origin.y))
        transformed = transformed.transformed(by: CGAffineTransform(scaleX: scaledWidth / imageExtent.width, y: scaledHeight / imageExtent.height))
        transformed = transformed.transformed(by: CGAffineTransform(translationX: originX, y: originY))

        let background = CIImage(color: CIColor.black).cropped(to: bounds)
        return transformed.composited(over: background).cropped(to: bounds)
    }

    private func upscaleTo4KIfNeeded(image: CIImage) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }

        let targetWidth: CGFloat = 3840
        let targetHeight: CGFloat = 2160
        let scale = min(3.0, max(targetWidth / extent.width, targetHeight / extent.height))
        guard scale > 1.01 else { return image }

        let upscaled = image.applyingFilter(
            "CILanczosScaleTransform",
            parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1.0
            ]
        )

        return upscaled
            .applyingFilter(
                "CISharpenLuminance",
                parameters: [kCIInputSharpnessKey: 0.28]
            )
            .cropped(to: upscaled.extent)
    }

    private func optimizeImageQualityIfNeeded(
        image: CIImage,
        configuration: ImageOptimizationConfiguration
    ) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }
        let config = configuration.clamped

        let denoised = image
            .clampedToExtent()
            .applyingFilter(
                "CINoiseReduction",
                parameters: [
                    "inputNoiseLevel": (0.008 + (config.denoiser * 0.05)),
                    "inputSharpness": (0.18 + (config.denoiser * 0.56))
                ]
            )
            .cropped(to: extent)

        let tuned = denoised
            .applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: 1.04 + (config.neuralClarity * 0.1),
                    kCIInputContrastKey: config.contrast,
                    kCIInputBrightnessKey: config.lighting
                ]
            )
            .cropped(to: extent)

        return tuned
            .applyingFilter(
                "CIUnsharpMask",
                parameters: [
                    kCIInputRadiusKey: 1.0 + (config.neuralClarity * 1.8),
                    kCIInputIntensityKey: 0.18 + (config.neuralClarity * 0.9)
                ]
            )
            .cropped(to: extent)
    }

    private func refreshGuardrailsIfNeeded(now: CFTimeInterval) {
        guard now - lastGuardrailCheckTimestamp >= 1 else { return }
        lastGuardrailCheckTimestamp = now

        let cpuLoad = cpuUsageSampler.currentProcessCPUPercent()
        stateLock.lock()
        let overloadUntil = overloadGuardrailUntil
        let configuration = self.configuration
        stateLock.unlock()

        let reason: String?
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            reason = configuration.guardrailsEnabled ? "low_power_mode" : nil
        } else {
            let thermal = ProcessInfo.processInfo.thermalState
            if configuration.guardrailsEnabled, (thermal == .serious || thermal == .critical) {
                reason = "thermal_\(thermalStateReason(thermal))"
            } else if configuration.guardrailsEnabled, overloadUntil > now {
                reason = "interpolation_over_budget"
            } else if configuration.guardrailsEnabled, let cpuLoad, cpuLoad >= configuration.cpuPressurePercent {
                reason = "cpu_pressure"
            } else {
                reason = nil
            }
        }

        stateLock.lock()
        interpolationGuardrailReason = reason
        if let cpuLoad {
            telemetry.lastCPULoadPercent = cpuLoad
        }
        if let reason {
            telemetry.lastFallbackReason = reason
            pendingInterpolatedFrame = nil
            consecutiveSlowInterpolations = 0
        }
        stateLock.unlock()
    }

    private func thermalStateReason(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    private func emitTelemetryIfNeeded() {
        let now = CACurrentMediaTime()

        stateLock.lock()
        guard now - lastTelemetryTimestamp >= 1 else {
            stateLock.unlock()
            return
        }
        lastTelemetryTimestamp = now
        var snapshot = telemetry
        snapshot.lastGPURenderMs = latestGPURenderMs
        let configuration = self.configuration
        stateLock.unlock()

        let cpuLoad = snapshot.lastCPULoadPercent > 0 ? snapshot.lastCPULoadPercent : cpuUsageSampler.currentProcessCPUPercent()
        let gpuLoadMs = snapshot.lastGPURenderMs > 0 ? snapshot.lastGPURenderMs : nil
        let rates = computeFPSRates(
            now: now,
            rendered: snapshot.renderedFrames,
            interpolated: snapshot.interpolatedFrames
        )

        GlitchoTelemetry.track(
            "motion_interpolation_runtime",
            metadata: [
                "gpu": metalDevice?.name ?? "unknown",
                "rendered_frames": "\(snapshot.renderedFrames)",
                "ai_frames": "\(snapshot.interpolatedFrames)",
                "fallback_frames": "\(snapshot.fallbackFrames)",
                "dropped_frames": "\(snapshot.droppedFrames)",
                "last_method": snapshot.lastMethod,
                "fallback_reason": snapshot.lastFallbackReason,
                "last_interpolation_ms": String(format: "%.2f", snapshot.lastInterpolationMs),
                "motion_magnitude": String(format: "%.4f", snapshot.lastMotionMagnitude),
                "budget_ms": String(format: "%.2f", configuration.maxInterpolationBudgetMs),
                "guardrails_enabled": configuration.guardrailsEnabled ? "true" : "false",
                "interpolation_enabled": motionInterpolationEnabled ? "true" : "false",
                "image_optimize_enabled": imageOptimizeEnabled ? "true" : "false",
                "upscaler_4k_enabled": upscaler4KEnabled ? "true" : "false",
                "source_fps": String(format: "%.1f", rates.sourceFPS),
                "generated_fps": String(format: "%.1f", rates.generatedFPS),
                "effective_fps": String(format: "%.1f", rates.effectiveFPS),
                "cpu_load": cpuLoad.map { String(format: "%.2f", $0) } ?? "unavailable",
                "gpu_load": gpuLoadMs.map { String(format: "%.2fms", $0) } ?? "unavailable"
            ]
        )

        let status = MotionInterpolationRuntimeStatus(
            method: snapshot.lastMethod,
            fallbackReason: snapshot.lastFallbackReason,
            cpuLoadPercent: cpuLoad,
            gpuRenderMs: gpuLoadMs,
            interpolationMs: snapshot.lastInterpolationMs,
            motionMagnitude: snapshot.lastMotionMagnitude,
            renderedFrames: snapshot.renderedFrames,
            interpolatedFrames: snapshot.interpolatedFrames,
            fallbackFrames: snapshot.fallbackFrames,
            sourceFPS: rates.sourceFPS,
            generatedFPS: rates.generatedFPS,
            effectiveFPS: rates.effectiveFPS
        )
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .motionInterpolationRuntimeUpdated,
                object: status
            )
        }
    }

    private func computeFPSRates(
        now: CFTimeInterval,
        rendered: Int,
        interpolated: Int
    ) -> (sourceFPS: Double, generatedFPS: Double, effectiveFPS: Double) {
        guard let previous = lastPublishedRuntimeSample else {
            lastPublishedRuntimeSample = (now, rendered, interpolated)
            return (0, 0, 0)
        }

        let deltaTime = max(0.001, now - previous.timestamp)
        let deltaRendered = max(0, rendered - previous.rendered)
        let deltaInterpolated = max(0, interpolated - previous.interpolated)

        lastPublishedRuntimeSample = (now, rendered, interpolated)

        let sourceFPS = Double(deltaRendered) / deltaTime
        let generatedFPS = Double(deltaInterpolated) / deltaTime
        return (sourceFPS, generatedFPS, sourceFPS + generatedFPS)
    }
}
#endif
