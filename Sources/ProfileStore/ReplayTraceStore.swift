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
    public let scrollDeltas: [TraceScrollDelta]
    public let scrollIntervalsMs: [Double]
    public let doubleClickIntervalMs: [Double]
    public let modifierFlags: [UInt64]
    public let flagsChangedKeyCodes: [UInt16]
    public let comboKeyCodes: [UInt16]
    public let repeatCount: Int
    public let eventTimeline: [String]
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
        scrollDeltas: [TraceScrollDelta] = [],
        scrollIntervalsMs: [Double] = [],
        doubleClickIntervalMs: [Double] = [],
        modifierFlags: [UInt64] = [],
        flagsChangedKeyCodes: [UInt16] = [],
        comboKeyCodes: [UInt16] = [],
        repeatCount: Int = 0,
        eventTimeline: [String] = [],
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
        self.scrollDeltas = scrollDeltas
        self.scrollIntervalsMs = scrollIntervalsMs
        self.doubleClickIntervalMs = doubleClickIntervalMs
        self.modifierFlags = modifierFlags
        self.flagsChangedKeyCodes = flagsChangedKeyCodes
        self.comboKeyCodes = comboKeyCodes
        self.repeatCount = max(0, repeatCount)
        self.eventTimeline = eventTimeline
        self.behaviorMode = behaviorMode
        self.flavor = flavor
        self.landingErrorPx = landingErrorPx
        self.durationMs = durationMs
        self.quality = quality
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case ts
        case source
        case pathSkeleton
        case segmentMs
        case hesitationMs
        case clickHoldMs
        case interClickMs
        case dwellMs
        case interKeyMs
        case scrollDeltas
        case scrollIntervalsMs
        case doubleClickIntervalMs
        case modifierFlags
        case flagsChangedKeyCodes
        case comboKeyCodes
        case repeatCount
        case eventTimeline
        case behaviorMode
        case flavor
        case landingErrorPx
        case durationMs
        case quality
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(ReplayTraceKey.self, forKey: .key)
        ts = try container.decode(Int64.self, forKey: .ts)
        source = try container.decode(String.self, forKey: .source)
        pathSkeleton = try container.decodeIfPresent([TracePoint].self, forKey: .pathSkeleton) ?? []
        segmentMs = try container.decodeIfPresent([Double].self, forKey: .segmentMs) ?? []
        hesitationMs = try container.decodeIfPresent([Double].self, forKey: .hesitationMs) ?? []
        clickHoldMs = try container.decodeIfPresent([Double].self, forKey: .clickHoldMs) ?? []
        interClickMs = try container.decodeIfPresent([Double].self, forKey: .interClickMs) ?? []
        dwellMs = try container.decodeIfPresent([Double].self, forKey: .dwellMs) ?? []
        interKeyMs = try container.decodeIfPresent([Double].self, forKey: .interKeyMs) ?? []
        scrollDeltas = try container.decodeIfPresent([TraceScrollDelta].self, forKey: .scrollDeltas) ?? []
        scrollIntervalsMs = try container.decodeIfPresent([Double].self, forKey: .scrollIntervalsMs) ?? []
        doubleClickIntervalMs = try container.decodeIfPresent([Double].self, forKey: .doubleClickIntervalMs) ?? []
        modifierFlags = try container.decodeIfPresent([UInt64].self, forKey: .modifierFlags) ?? []
        flagsChangedKeyCodes = try container.decodeIfPresent([UInt16].self, forKey: .flagsChangedKeyCodes) ?? []
        comboKeyCodes = try container.decodeIfPresent([UInt16].self, forKey: .comboKeyCodes) ?? []
        repeatCount = try container.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 0
        eventTimeline = try container.decodeIfPresent([String].self, forKey: .eventTimeline) ?? []
        behaviorMode = try container.decodeIfPresent(HumanBehaviorMode.self, forKey: .behaviorMode)
        flavor = try container.decodeIfPresent(MotionFlavor.self, forKey: .flavor)
        landingErrorPx = try container.decodeIfPresent(Double.self, forKey: .landingErrorPx)
        durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
        quality = try container.decode(Double.self, forKey: .quality)
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
            scrollDeltas: compactDeltas(input.payload.scrollDeltas),
            scrollIntervalsMs: compact(input.payload.scrollIntervalsMs),
            doubleClickIntervalMs: compact(input.payload.doubleClickIntervalMs),
            modifierFlags: sortedUnique(input.payload.modifierFlags),
            flagsChangedKeyCodes: sortedUnique(input.payload.flagsChangedKeyCodes),
            comboKeyCodes: sortedUnique(input.payload.comboKeyCodes),
            repeatCount: input.payload.repeatCount,
            eventTimeline: compactTimeline(input.payload.eventTimeline),
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
    if !payload.scrollDeltas.isEmpty || !payload.doubleClickIntervalMs.isEmpty || payload.repeatCount > 0 { score += 0.08 }
    if !payload.modifierFlags.isEmpty || !payload.flagsChangedKeyCodes.isEmpty || !payload.comboKeyCodes.isEmpty { score += 0.06 }
    if payload.landingErrorPx != nil { score += 0.10 }
    if payload.behaviorMode != nil { score += 0.08 }
    if payload.flavor != nil { score += 0.08 }
    return min(1, score)
}

private func compactDeltas(_ values: [TraceScrollDelta], limit: Int = 32) -> [TraceScrollDelta] {
    downsample(values.enumerated().map { index, value in TracePoint(x: Double(index), y: 0) }, limit: limit)
        .compactMap { point in
            let index = Int(point.x)
            return values.indices.contains(index) ? values[index] : nil
        }
}

private func compactTimeline(_ values: [String], limit: Int = 32) -> [String] {
    guard values.count > limit else {
        return values
    }
    guard limit > 1 else {
        return values.last.map { [$0] } ?? []
    }
    return (0..<limit).compactMap { index in
        let raw = Double(index) * Double(values.count - 1) / Double(limit - 1)
        return values[Int(raw.rounded())]
    }
}

private func sortedUnique<T: Comparable & Hashable>(_ values: [T]) -> [T] {
    Array(Set(values)).sorted()
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
