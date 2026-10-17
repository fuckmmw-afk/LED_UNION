import Foundation

public struct QueueSnapshot: Sendable, Codable {
    public let pending: Int
    public let sent: Int
    public let failed: Int
    public let lastCommandAt: Date?
    public init(pending: Int, sent: Int, failed: Int, lastCommandAt: Date?) {
        self.pending = pending; self.sent = sent; self.failed = failed; self.lastCommandAt = lastCommandAt
    }
}

/// One serial command stream per physical controller. RGB and brightness updates may
/// coalesce while scene uploads remain ordered and lossless.
public actor CommandQueue {
    public typealias Sink = @MainActor @Sendable (Data) async throws -> Void
    private struct Item: Sendable { let data: Data; let key: String? }

    private let minimumGap: Duration
    private let sink: Sink
    private var pending: [Item] = []
    private var worker: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var sent = 0
    private var failed = 0
    private var lastCommandAt: Date?

    public init(minimumGap: Duration, sink: @escaping Sink) {
        self.minimumGap = minimumGap; self.sink = sink
    }

    public func enqueue(_ data: Data, coalescingKey: String? = nil) {
        if let key = coalescingKey, let index = pending.lastIndex(where: { $0.key == key }) {
            pending[index] = Item(data: data, key: key)
        } else {
            pending.append(Item(data: data, key: coalescingKey))
        }
        if worker == nil {
            worker = Task { [weak self] in await self?.run() }
        }
    }

    public func cancel(coalescingKey: String) { pending.removeAll { $0.key == coalescingKey } }

    public func waitUntilIdle() async {
        guard worker != nil || !pending.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    public func snapshot() -> QueueSnapshot {
        QueueSnapshot(pending: pending.count, sent: sent, failed: failed, lastCommandAt: lastCommandAt)
    }

    private func run() async {
        while !pending.isEmpty {
            let item = pending.removeFirst()
            do { try await sink(item.data); sent += 1 } catch { failed += 1 }
            lastCommandAt = .now
            if !pending.isEmpty { try? await Task.sleep(for: minimumGap) }
        }
        worker = nil
        let waiters = idleWaiters; idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

public enum ColorEngine {
    public static func applyingBrightness(_ color: RGBColor, percent: Int) -> RGBColor {
        let factor = Double(max(0, min(100, percent))) / 100
        return RGBColor(red: Int(Double(color.red) * factor), green: Int(Double(color.green) * factor), blue: Int(Double(color.blue) * factor))
    }

    public static func interpolate(from: RGBColor, to: RGBColor, progress: Double) -> RGBColor {
        let t = max(0, min(1, progress))
        func blend(_ a: UInt8, _ b: UInt8) -> Int { Int((Double(a) + (Double(b) - Double(a)) * t).rounded()) }
        return RGBColor(red: blend(from.red, to.red), green: blend(from.green, to.green), blue: blend(from.blue, to.blue))
    }
}

public struct EffectFrame: Sendable, Hashable {
    public let color: RGBColor
    public let progress: Double
    public init(color: RGBColor, progress: Double) { self.color = color; self.progress = progress }
}

public enum SoftwareEffect: String, Codable, Sendable, CaseIterable {
    case smoothFade, colorCycle, rainbow, breathing, pulse, strobe, candle, sunset, ambient, randomColors, customGradient
}

public enum EffectsEngine {
    public static func frames(effect: SoftwareEffect, steps: Int = 60, seed: UInt64 = 0x4c4544) -> [EffectFrame] {
        let count = max(2, steps)
        return (0..<count).map { index in
            let phase = Double(index) / Double(count - 1)
            switch effect {
            case .rainbow, .colorCycle:
                return EffectFrame(color: hsv(hue: phase, saturation: 1, value: 1), progress: phase)
            case .breathing:
                let value = (sin(phase * .pi * 2) + 1) / 2
                return EffectFrame(color: RGBColor(red: Int(value * 255), green: Int(value * 90), blue: Int(value * 40)), progress: phase)
            case .pulse:
                let value = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                return EffectFrame(color: RGBColor(red: 255, green: Int(value * 180), blue: Int(value * 40)), progress: phase)
            case .strobe:
                return EffectFrame(color: index.isMultiple(of: 2) ? RGBColor(red: 255, green: 255, blue: 255) : RGBColor(red: 0, green: 0, blue: 0), progress: phase)
            case .candle:
                let flicker = pseudoRandom(index: index, seed: seed)
                return EffectFrame(color: RGBColor(red: 255, green: Int(80 + flicker * 100), blue: Int(10 + flicker * 25)), progress: phase)
            case .sunset:
                return EffectFrame(color: ColorEngine.interpolate(from: RGBColor(red: 255, green: 90, blue: 20), to: RGBColor(red: 40, green: 0, blue: 90), progress: phase), progress: phase)
            case .ambient:
                return EffectFrame(color: hsv(hue: 0.58 + phase * 0.08, saturation: 0.5, value: 0.45), progress: phase)
            case .randomColors:
                return EffectFrame(color: hsv(hue: pseudoRandom(index: index, seed: seed), saturation: 1, value: 1), progress: phase)
            case .smoothFade, .customGradient:
                return EffectFrame(color: ColorEngine.interpolate(from: RGBColor(red: 0, green: 40, blue: 255), to: RGBColor(red: 255, green: 20, blue: 0), progress: phase), progress: phase)
            }
        }
    }

    public static func frames(colors: [RGBColor], fade: Bool, stepsPerColor: Int = 8) -> [EffectFrame] {
        guard !colors.isEmpty else { return [] }
        guard fade, colors.count > 1 else { return colors.enumerated().map { EffectFrame(color: $0.element, progress: Double($0.offset) / Double(max(colors.count - 1, 1))) } }
        let steps = max(1, stepsPerColor)
        var result: [EffectFrame] = []
        for index in colors.indices {
            let next = colors[(index + 1) % colors.count]
            for step in 0..<steps {
                let p = Double(index * steps + step) / Double(colors.count * steps)
                result.append(EffectFrame(color: ColorEngine.interpolate(from: colors[index], to: next, progress: Double(step) / Double(steps)), progress: p))
            }
        }
        return result
    }

    private static func pseudoRandom(index: Int, seed: UInt64) -> Double {
        let value = (seed &* 1_664_525 &+ UInt64(index) &* 1_013_904_223) & 0xffff
        return Double(value) / 65_535
    }

    private static func hsv(hue: Double, saturation: Double, value: Double) -> RGBColor {
        let h = (hue - floor(hue)) * 6
        let i = Int(h); let f = h - Double(i)
        let p = value * (1 - saturation); let q = value * (1 - saturation * f); let t = value * (1 - saturation * (1 - f))
        let rgb: (Double, Double, Double)
        switch i % 6 {
        case 0: rgb = (value, t, p)
        case 1: rgb = (q, value, p)
        case 2: rgb = (p, value, t)
        case 3: rgb = (p, q, value)
        case 4: rgb = (t, p, value)
        default: rgb = (value, p, q)
        }
        return RGBColor(red: Int(rgb.0 * 255), green: Int(rgb.1 * 255), blue: Int(rgb.2 * 255))
    }
}

public actor EffectTaskController {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public func start(deviceID: UUID, effect: LEDCustomEffect, send: @escaping @Sendable (RGBColor) async -> Void) -> UUID {
        tasks[deviceID]?.cancel()
        let id = UUID()
        let frames = EffectsEngine.frames(colors: effect.colors, fade: effect.fade)
        let interval = UInt64(max(10, 1000 - effect.speed * 9)) * 1_000_000
        tasks[deviceID] = Task {
            for frame in frames {
                guard !Task.isCancelled else { return }
                await send(frame.color)
                try? await Task.sleep(nanoseconds: interval)
            }
        }
        return id
    }

    public func start(deviceID: UUID, effect: SoftwareEffect, send: @escaping @Sendable (RGBColor) async -> Void) -> UUID {
        tasks[deviceID]?.cancel()
        let id = UUID()
        let frames = EffectsEngine.frames(effect: effect)
        tasks[deviceID] = Task {
            for frame in frames {
                guard !Task.isCancelled else { return }
                await send(frame.color)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        return id
    }

    public func cancel(deviceID: UUID) { tasks.removeValue(forKey: deviceID)?.cancel() }
    public func cancelAll() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
}
