import Foundation

#if canImport(AVFoundation) && os(iOS)
import AVFoundation

@MainActor
public final class AudioReactiveEngine {
    public enum Permission: String, Sendable { case unknown, granted, denied }
    public private(set) var permission: Permission = .unknown
    public private(set) var isRunning = false
    public var sensitivity: Double = 1
    public var onLevel: (@Sendable (Double, Double, Double) -> Void)?

    private let engine = AVAudioEngine()
    private var tapInstalled = false

    public init() {}

    public func requestPermission() async -> Permission {
        let granted = await AVAudioApplication.requestRecordPermission()
        permission = granted ? .granted : .denied
        return permission
    }

    public func start() async throws {
        if permission != .granted { _ = await requestPermission() }
        guard permission == .granted else { throw NSError(domain: "LEDUnionAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission was denied"]) }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.mixWithOthers])
        try session.setActive(true)
        if !tapInstalled {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let sensitivity = self.sensitivity
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let channel = buffer.floatChannelData?[0] else { return }
                let count = Int(buffer.frameLength)
                guard count > 0 else { return }
                var sum: Float = 0
                var bass: Float = 0
                for index in 0..<count {
                    let sample = channel[index]
                    sum += sample * sample
                    if index < count / 4 { bass += abs(sample) }
                }
                let rms = min(1, sqrt(sum / Float(count)) * Float(sensitivity) * 8)
                let bassLevel = min(1, bass / Float(max(1, count / 4)) * Float(sensitivity) * 2)
                let beat = rms > 0.55 ? 1.0 : 0.0
                Task { @MainActor in self?.onLevel?(Double(rms), Double(bassLevel), beat) }
            }
            tapInstalled = true
        }
        try engine.start()
        isRunning = true
    }

    public func stop() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }

}
#else
/// Audio capture is an iOS-only feature. The host implementation makes the core
/// package testable on macOS/Linux without pretending that system audio is available.
@MainActor
public final class AudioReactiveEngine {
    public enum Permission: String, Sendable { case unknown, granted, denied }
    public private(set) var permission: Permission = .unknown
    public private(set) var isRunning = false
    public var sensitivity: Double = 1
    public var onLevel: (@Sendable (Double, Double, Double) -> Void)?
    public init() {}
    public func requestPermission() async -> Permission { permission = .denied; return permission }
    public func start() async throws { throw NSError(domain: "LEDUnionAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio reactive mode is available in the iOS target"]) }
    public func stop() { isRunning = false }
}
#endif
