import Foundation
import HumanizationKit

public struct ReplayTraceKey: Codable, Hashable {
    public let host: String
    public let taskId: String?
    public let stage: String?
    public let instructionKey: String
    public let actionType: String

    public init(host: String, taskId: String? = nil, stage: String? = nil, instructionKey: String, actionType: String) {
        self.host = host
        self.taskId = taskId
        self.stage = stage
        self.instructionKey = instructionKey
        self.actionType = actionType
    }
}

public struct ReplayTraceFingerprint: Codable, Equatable {
    public let key: ReplayTraceKey
    public let ts: Int64
    public let source: String
    public let pathSkeleton: [TracePoint]
    public let segmentMs: [Double]
    public let hesitationMs: [Double]
    public let clickHoldMs: [Double]
    public let interClickMs: [Double]
    public let dwellMs: [Double]
    public let interKeyMs: [Double]
    public let behaviorMode: HumanBehaviorMode?
    public let flavor: MotionFlavor?
    public let landingErrorPx: Double?
    public let durationMs: Double?
    public let quality: Double

    public init(
        key: ReplayTraceKey,
        ts: Int64,
        source: String,
        pathSkeleton: [TracePoint],
        segmentMs: [Double],
        hesitationMs: [Double],
        clickHoldMs: [Double],
        interClickMs: [Double],
        dwellMs: [Double],
        interKeyMs: [Double],
        behaviorMode: HumanBehaviorMode?,
        flavor: MotionFlavor?,
        landingErrorPx: Double?,
        durationMs: Double?,
        quality: Double
    ) {
        self.key = key
        self.ts = ts
        self.source = source
        self.pathSkeleton = pathSkeleton
        self.segmentMs = segmentMs
        self.hesitationMs = hesitationMs
        self.clickHoldMs = clickHoldMs
        self.interClickMs = interClickMs
        self.dwellMs = dwellMs
        self.interKeyMs = interKeyMs
        self.behaviorMode = behaviorMode
        self.flavor = flavor
        self.landingErrorPx = landingErrorPx
        self.durationMs = durationMs
        self.quality = quality
    }
}

public struct ReplayTraceRetentionPolicy: Equatable {
    public let maxFingerprintsPerKey: Int
    public let maxAgeMs: Int64

    public init(maxFingerprintsPerKey: Int = 240, maxAgeMs: Int64 = 30 * 24 * 60 * 60 * 1000) {
        self.maxFingerprintsPerKey = maxFingerprintsPerKey
        self.maxAgeMs = maxAgeMs
    }
}

public struct ReplayTraceSummary: Codable, Equatable {
    public let key: ReplayTraceKey
    public let sampleSize: Int
    public let medianDurationMs: Double
    public let medianSegmentCount: Double
    public let medianQuality: Double
    public let behaviorBlend: BehaviorBlend
    public let preferredFingerprint: ReplayTraceFingerprint?

    public init(
        key: ReplayTraceKey,
        sampleSize: Int,
        medianDurationMs: Double,
        medianSegmentCount: Double,
        medianQuality: Double,
        behaviorBlend: BehaviorBlend,
        preferredFingerprint: ReplayTraceFingerprint?
    ) {
        self.key = key
        self.sampleSize = sampleSize
        self.medianDurationMs = medianDurationMs
        self.medianSegmentCount = medianSegmentCount
        self.medianQuality = medianQuality
        self.behaviorBlend = behaviorBlend
        self.preferredFingerprint = preferredFingerprint
    }
}

public final class ReplayTraceStore {
    private let lock = NSLock()
    private let retention: ReplayTraceRetentionPolicy
    private var fingerprintsByKey = [ReplayTraceKey: [ReplayTraceFingerprint]]()

    public init(retention: ReplayTraceRetentionPolicy = ReplayTraceRetentionPolicy()) {
        self.retention = retention
    }

    public func commit(_ fingerprint: ReplayTraceFingerprint) {
        lock.withLock {
            var items = fingerprintsByKey[fingerprint.key] ?? []
            items.append(fingerprint)
            fingerprintsByKey[fingerprint.key] = retained(items, nowMs: fingerprint.ts)
        }
    }

    public func list(key: ReplayTraceKey? = nil) -> [ReplayTraceFingerprint] {
        lock.withLock {
            if let key {
                return fingerprintsByKey[key] ?? []
            }
            return fingerprintsByKey.values.flatMap { $0 }
        }
    }

    public func summarize(key: ReplayTraceKey) -> ReplayTraceSummary? {
        lock.withLock {
            guard let items = fingerprintsByKey[key], !items.isEmpty else {
                return nil
            }
            return ReplayTraceSummary(
                key: key,
                sampleSize: items.count,
                medianDurationMs: median(items.compactMap(\.durationMs)),
                medianSegmentCount: median(items.map { Double($0.segmentMs.count) }),
                medianQuality: median(items.map(\.quality)),
                behaviorBlend: behaviorBlend(items),
                preferredFingerprint: items.max { lhs, rhs in lhs.quality < rhs.quality }
            )
        }
    }

    public static func fingerprint(
        input: TraceInput,
        instructionKey: String,
        maxSkeletonPoints: Int = 16
    ) -> ReplayTraceFingerprint {
        let key = ReplayTraceKey(
            host: input.host,
            taskId: input.taskId,
            stage: input.stage,
            instructionKey: instructionKey,
            actionType: input.actionType
        )
        let skeleton = downsample(input.payload.points, limit: maxSkeletonPoints)
        let quality = qualityScore(payload: input.payload, skeleton: skeleton)
        return ReplayTraceFingerprint(
            key: key,
            ts: input.ts,
            source: input.source,
            pathSkeleton: skeleton,
            segmentMs: compact(input.payload.segmentMs),
            hesitationMs: compact(input.payload.hesitationMs),
            clickHoldMs: compact(input.payload.clickHoldMs),
            interClickMs: compact(input.payload.interClickMs),
            dwellMs: compact(input.payload.dwellMs),
            interKeyMs: compact(input.payload.interKeyMs),
            behaviorMode: input.payload.behaviorMode,
            flavor: input.payload.flavor,
            landingErrorPx: input.payload.landingErrorPx,
            durationMs: input.payload.durationMs,
            quality: quality
        )
    }

    private func retained(_ items: [ReplayTraceFingerprint], nowMs: Int64) -> [ReplayTraceFingerprint] {
        let maxAgeMs = retention.maxAgeMs
        var retained = items
            .filter { maxAgeMs <= 0 || nowMs - $0.ts <= maxAgeMs }
            .sorted { $0.ts > $1.ts }
        if retention.maxFingerprintsPerKey > 0, retained.count > retention.maxFingerprintsPerKey {
            retained = Array(retained.prefix(retention.maxFingerprintsPerKey))
        }
        return retained.sorted { $0.ts < $1.ts }
    }
}

private func downsample(_ points: [TracePoint], limit: Int) -> [TracePoint] {
    guard limit > 0, points.count > limit else {
        return points
    }
    guard limit > 1 else {
        return [points.last].compactMap { $0 }
    }
    return (0..<limit).map { index in
        let raw = Double(index) * Double(points.count - 1) / Double(limit - 1)
        return points[Int(raw.rounded())]
    }
}

private func compact(_ values: [Double], limit: Int = 32) -> [Double] {
    downsample(values.map { TracePoint(x: $0, y: 0) }, limit: limit).map(\.x)
}

private func qualityScore(payload: TracePayload, skeleton: [TracePoint]) -> Double {
    var score = 0.25
    if skeleton.count >= 4 { score += 0.25 }
    if payload.durationMs != nil { score += 0.12 }
    if !payload.segmentMs.isEmpty { score += 0.12 }
    if payload.landingErrorPx != nil { score += 0.10 }
    if payload.behaviorMode != nil { score += 0.08 }
    if payload.flavor != nil { score += 0.08 }
    return min(1, score)
}

private func behaviorBlend(_ items: [ReplayTraceFingerprint]) -> BehaviorBlend {
    var idle = 0.0
    var normal = 0.0
    var flow = 0.0
    var lowEfficiency = 0.0
    for item in items {
        switch item.behaviorMode {
        case .idle:
            idle += 1
        case .flow:
            flow += 1
        case .lowEfficiency:
            lowEfficiency += 1
        case .normal, nil:
            normal += 1
        }
    }
    let total = max(1, idle + normal + flow + lowEfficiency)
    return BehaviorBlend(
        idle: idle / total,
        normal: normal / total,
        flow: flow / total,
        lowEfficiency: lowEfficiency / total
    )
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
