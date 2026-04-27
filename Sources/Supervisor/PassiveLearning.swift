import Foundation

public enum PassiveLearningMode: String, Codable, Equatable, CaseIterable {
    case off
    case passive
    case training
}

public struct PassiveLearningSettings: Codable, Equatable {
    public var enabled: Bool
    public var mode: PassiveLearningMode
    public var minGesturePoints: Int
    public var maxSkeletonPoints: Int

    public init(
        enabled: Bool = false,
        mode: PassiveLearningMode = .off,
        minGesturePoints: Int = 3,
        maxSkeletonPoints: Int = 16
    ) {
        self.enabled = enabled
        self.mode = mode
        self.minGesturePoints = max(1, minGesturePoints)
        self.maxSkeletonPoints = max(2, maxSkeletonPoints)
    }
}

public struct PassiveLearningSession: Codable, Equatable {
    public let id: String
    public let label: String?
    public let host: String?
    public let targetAction: String?
    public let startedAt: Int64
    public var endedAt: Int64?
    public var status: String
    public var sampleCount: Int
    public var discardedCount: Int

    public init(
        id: String,
        label: String?,
        host: String?,
        targetAction: String?,
        startedAt: Int64,
        endedAt: Int64? = nil,
        status: String = "active",
        sampleCount: Int = 0,
        discardedCount: Int = 0
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.targetAction = targetAction
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.sampleCount = sampleCount
        self.discardedCount = discardedCount
    }
}

public struct PassiveGestureSample: Codable, Equatable {
    public let id: String
    public let ts: Int64
    public let source: String
    public let host: String
    public let taskId: String?
    public let stage: String?
    public let sessionId: String?
    public let sessionLabel: String?
    public let actionType: String
    public let eventType: String
    public let point: ObservedPoint?
    public let pathSkeleton: [ObservedPoint]
    public let pointCount: Int
    public let durationMs: Double?
    public let segmentMs: [Double]
    public let hesitationMs: [Double]
    public let clickHoldMs: [Double]
    public let interClickMs: [Double]
    public let pathLengthPx: Double?
    public let speedPxS: Double?
    public let straightness: Double?
    public let turnJitter: Double?
    public let quality: Double

    public init(
        id: String,
        ts: Int64,
        source: String,
        host: String,
        taskId: String?,
        stage: String?,
        sessionId: String?,
        sessionLabel: String?,
        actionType: String,
        eventType: String,
        point: ObservedPoint?,
        pathSkeleton: [ObservedPoint],
        pointCount: Int,
        durationMs: Double?,
        segmentMs: [Double],
        hesitationMs: [Double],
        clickHoldMs: [Double],
        interClickMs: [Double],
        pathLengthPx: Double?,
        speedPxS: Double?,
        straightness: Double?,
        turnJitter: Double?,
        quality: Double
    ) {
        self.id = id
        self.ts = ts
        self.source = source
        self.host = host
        self.taskId = taskId
        self.stage = stage
        self.sessionId = sessionId
        self.sessionLabel = sessionLabel
        self.actionType = actionType
        self.eventType = eventType
        self.point = point
        self.pathSkeleton = pathSkeleton
        self.pointCount = pointCount
        self.durationMs = durationMs
        self.segmentMs = segmentMs
        self.hesitationMs = hesitationMs
        self.clickHoldMs = clickHoldMs
        self.interClickMs = interClickMs
        self.pathLengthPx = pathLengthPx
        self.speedPxS = speedPxS
        self.straightness = straightness
        self.turnJitter = turnJitter
        self.quality = quality
    }
}

public struct PassiveLearningState: Codable, Equatable {
    public let settings: PassiveLearningSettings
    public let activeSession: PassiveLearningSession?
    public let producedSamples: Int
    public let pendingTrainingSamples: Int
    public let recentSamples: [PassiveGestureSample]
    public let lastSampleAt: Int64?

    public init(
        settings: PassiveLearningSettings,
        activeSession: PassiveLearningSession?,
        producedSamples: Int,
        pendingTrainingSamples: Int,
        recentSamples: [PassiveGestureSample] = [],
        lastSampleAt: Int64?
    ) {
        self.settings = settings
        self.activeSession = activeSession
        self.producedSamples = producedSamples
        self.pendingTrainingSamples = pendingTrainingSamples
        self.recentSamples = recentSamples
        self.lastSampleAt = lastSampleAt
    }
}

public struct PassiveLearningStopResult: Codable, Equatable {
    public let state: PassiveLearningState
    public let committedSamples: [PassiveGestureSample]
    public let discardedSamples: Int

    public init(state: PassiveLearningState, committedSamples: [PassiveGestureSample], discardedSamples: Int) {
        self.state = state
        self.committedSamples = committedSamples
        self.discardedSamples = discardedSamples
    }
}

fileprivate struct PassiveLearningTimedPoint: Equatable {
    let point: ObservedPoint
    let ts: Int64
}

final class PassiveLearningRecorder {
    private struct ButtonDown {
        let type: String
        let point: ObservedPoint?
        let ts: Int64
        let prelude: [PassiveLearningTimedPoint]
    }

    private static let globalHost = "__global__"

    private var settings = PassiveLearningSettings()
    private var activeSession: PassiveLearningSession?
    private var pendingTrainingSamples = [PassiveGestureSample]()
    private var moveBuffer = [PassiveLearningTimedPoint]()
    private var dragBuffer = [PassiveLearningTimedPoint]()
    private var buttonDown: ButtonDown?
    private var lastClickUpAt: Int64?
    private var producedSamples = 0
    private var recentSamples = [PassiveGestureSample]()
    private var lastSampleAt: Int64?

    var state: PassiveLearningState {
        PassiveLearningState(
            settings: settings,
            activeSession: activeSession,
            producedSamples: producedSamples,
            pendingTrainingSamples: pendingTrainingSamples.count,
            recentSamples: recentSamples,
            lastSampleAt: lastSampleAt
        )
    }

    func configure(enabled: Bool?, mode: PassiveLearningMode?) -> PassiveLearningState {
        if let enabled {
            settings.enabled = enabled
        }
        if let mode {
            settings.mode = mode
            if mode != .training {
                activeSession = nil
                pendingTrainingSamples.removeAll()
            }
        }
        if !settings.enabled {
            settings.mode = .off
            activeSession = nil
            pendingTrainingSamples.removeAll()
            resetGestureBuffers()
        } else if settings.mode == .off {
            settings.mode = .passive
        }
        return state
    }

    func startSession(label: String?, host: String?, targetAction: String?) -> PassiveLearningState {
        let now = currentTimeMs()
        pendingTrainingSamples.removeAll()
        activeSession = PassiveLearningSession(
            id: "training-\(now)-\(UUID().uuidString.prefix(8))",
            label: normalized(label),
            host: normalized(host),
            targetAction: normalized(targetAction),
            startedAt: now
        )
        settings.enabled = true
        settings.mode = .training
        resetGestureBuffers()
        return state
    }

    func stopSession(commit: Bool) -> PassiveLearningStopResult {
        let samples = commit ? pendingTrainingSamples : []
        let discarded = commit ? 0 : pendingTrainingSamples.count
        if var session = activeSession {
            session.endedAt = currentTimeMs()
            session.status = commit ? "committed" : "discarded"
            session.discardedCount += discarded
            activeSession = session
        }
        pendingTrainingSamples.removeAll()
        settings.mode = settings.enabled ? .passive : .off
        let result = PassiveLearningStopResult(
            state: state,
            committedSamples: samples,
            discardedSamples: discarded
        )
        activeSession = nil
        resetGestureBuffers()
        return result
    }

    func record(event: ObservedEvent, host: String?, taskId: String?) -> [PassiveGestureSample] {
        guard settings.enabled, settings.mode != .off else {
            resetGestureBuffers()
            return []
        }

        var samples = [PassiveGestureSample]()
        switch event.type {
        case "mouseMoved":
            appendMovePoint(event)
        case "leftMouseDown", "rightMouseDown", "otherMouseDown":
            buttonDown = ButtonDown(type: event.type, point: event.point, ts: event.ts, prelude: moveBuffer)
            dragBuffer.removeAll()
            appendMovePoint(event)
        case "leftMouseDragged", "rightMouseDragged", "otherMouseDragged":
            appendDragPoint(event)
        case "leftMouseUp", "rightMouseUp", "otherMouseUp":
            if let sample = completeButtonGesture(event: event, host: host, taskId: taskId) {
                samples.append(sample)
            }
        case "scrollWheel":
            if let sample = scrollSample(event: event, host: host, taskId: taskId) {
                samples.append(sample)
            }
        default:
            break
        }

        return publish(samples)
    }

    private func completeButtonGesture(event: ObservedEvent, host: String?, taskId: String?) -> PassiveGestureSample? {
        guard let down = buttonDown else {
            appendMovePoint(event)
            return nil
        }
        defer {
            buttonDown = nil
            dragBuffer.removeAll()
            moveBuffer = event.point.map { [PassiveLearningTimedPoint(point: $0, ts: event.ts)] } ?? []
        }

        let isDrag = !dragBuffer.isEmpty
        let actionType = isDrag ? "drag" : "click"
        let downPoint = down.point.map { [PassiveLearningTimedPoint(point: $0, ts: down.ts)] } ?? []
        let upPoint = event.point.map { [PassiveLearningTimedPoint(point: $0, ts: event.ts)] } ?? []
        let path = compactPath(
            Array(down.prelude.suffix(24))
                + downPoint
                + dragBuffer
                + upPoint
        )
        let clickHold = max(0, Double(event.ts - down.ts))
        let interClick: [Double]
        if actionType == "click", let lastClickUpAt {
            interClick = [max(0, Double(event.ts - lastClickUpAt))]
        } else {
            interClick = []
        }
        if actionType == "click" {
            lastClickUpAt = event.ts
        }
        return makeSample(
            ts: event.ts,
            source: sampleSource,
            host: resolvedHost(host),
            taskId: nil,
            stage: taskId,
            actionType: actionType,
            eventType: event.type,
            point: event.point ?? down.point,
            path: path,
            clickHoldMs: [clickHold],
            interClickMs: interClick
        )
    }

    private func scrollSample(event: ObservedEvent, host: String?, taskId: String?) -> PassiveGestureSample? {
        guard let point = event.point else {
            return nil
        }
        return makeSample(
            ts: event.ts,
            source: sampleSource,
            host: resolvedHost(host),
            taskId: nil,
            stage: taskId,
            actionType: "scroll",
            eventType: event.type,
            point: point,
            path: [PassiveLearningTimedPoint(point: point, ts: event.ts)],
            clickHoldMs: [],
            interClickMs: []
        )
    }

    private var sampleSource: String {
        settings.mode == .training ? "user-training" : "user-passive"
    }

    private func publish(_ samples: [PassiveGestureSample]) -> [PassiveGestureSample] {
        guard !samples.isEmpty else {
            return []
        }
        producedSamples += samples.count
        lastSampleAt = samples.last?.ts
        recentSamples.append(contentsOf: samples)
        if recentSamples.count > 24 {
            recentSamples.removeFirst(recentSamples.count - 24)
        }
        if var session = activeSession, settings.mode == .training {
            session.sampleCount += samples.count
            activeSession = session
            pendingTrainingSamples.append(contentsOf: samples)
            return []
        }
        return samples
    }

    private func makeSample(
        ts: Int64,
        source: String,
        host: String,
        taskId: String?,
        stage: String?,
        actionType: String,
        eventType: String,
        point: ObservedPoint?,
        path: [PassiveLearningTimedPoint],
        clickHoldMs: [Double],
        interClickMs: [Double]
    ) -> PassiveGestureSample? {
        let compact = compactPath(path)
        guard compact.count >= settings.minGesturePoints || actionType == "click" || actionType == "scroll" else {
            return nil
        }
        let skeleton = downsample(compact, limit: settings.maxSkeletonPoints)
        let durationMs = gestureDuration(compact)
        let pathLength = computePathLength(compact.map(\.point))
        let speed: Double?
        if let durationMs, durationMs > 0, pathLength > 0 {
            speed = pathLength / durationMs * 1000
        } else {
            speed = nil
        }
        let segmentMs = adjacentDurations(skeleton)
        return PassiveGestureSample(
            id: "sample-\(ts)-\(UUID().uuidString.prefix(8))",
            ts: ts,
            source: source,
            host: host,
            taskId: taskId,
            stage: stage,
            sessionId: activeSession?.id,
            sessionLabel: activeSession?.label,
            actionType: activeSession?.targetAction ?? actionType,
            eventType: eventType,
            point: point ?? compact.last?.point,
            pathSkeleton: skeleton.map(\.point),
            pointCount: compact.count,
            durationMs: durationMs,
            segmentMs: segmentMs,
            hesitationMs: hesitationDurations(segmentMs),
            clickHoldMs: clickHoldMs.filter { $0 > 0 },
            interClickMs: interClickMs.filter { $0 > 0 },
            pathLengthPx: pathLength > 0 ? pathLength : nil,
            speedPxS: speed,
            straightness: computeStraightness(compact.map(\.point)),
            turnJitter: computeTurnJitter(compact.map(\.point)),
            quality: quality(pointCount: compact.count, durationMs: durationMs, pathLengthPx: pathLength)
        )
    }

    private func appendMovePoint(_ event: ObservedEvent) {
        guard let point = event.point else {
            return
        }
        append(PassiveLearningTimedPoint(point: point, ts: event.ts), to: &moveBuffer, maxCount: 96)
    }

    private func appendDragPoint(_ event: ObservedEvent) {
        guard let point = event.point else {
            return
        }
        let timed = PassiveLearningTimedPoint(point: point, ts: event.ts)
        append(timed, to: &dragBuffer, maxCount: 128)
        append(timed, to: &moveBuffer, maxCount: 96)
    }

    private func append(_ timed: PassiveLearningTimedPoint, to buffer: inout [PassiveLearningTimedPoint], maxCount: Int) {
        if let last = buffer.last,
           last.ts == timed.ts || distance(last.point, timed.point) < 0.5 {
            return
        }
        buffer.append(timed)
        if buffer.count > maxCount {
            buffer.removeFirst(buffer.count - maxCount)
        }
    }

    private func resetGestureBuffers() {
        moveBuffer.removeAll()
        dragBuffer.removeAll()
        buttonDown = nil
        lastClickUpAt = nil
    }

    private func resolvedHost(_ host: String?) -> String {
        activeSession?.host ?? normalized(host) ?? Self.globalHost
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func currentTimeMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

private func compactPath(_ path: [PassiveLearningTimedPoint]) -> [PassiveLearningTimedPoint] {
    var result = [PassiveLearningTimedPoint]()
    for point in path.sorted(by: { $0.ts < $1.ts }) {
        if let last = result.last, last.ts == point.ts || distance(last.point, point.point) < 0.5 {
            continue
        }
        result.append(point)
    }
    return result
}

private func downsample(_ points: [PassiveLearningTimedPoint], limit: Int) -> [PassiveLearningTimedPoint] {
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

private func gestureDuration(_ points: [PassiveLearningTimedPoint]) -> Double? {
    guard let first = points.first, let last = points.last, last.ts >= first.ts else {
        return nil
    }
    return Double(last.ts - first.ts)
}

private func adjacentDurations(_ points: [PassiveLearningTimedPoint]) -> [Double] {
    guard points.count > 1 else {
        return []
    }
    return zip(points.dropFirst(), points).map { next, previous in
        max(0, Double(next.ts - previous.ts))
    }
}

private func hesitationDurations(_ segmentMs: [Double]) -> [Double] {
    guard segmentMs.count >= 3 else {
        return []
    }
    let sorted = segmentMs.sorted()
    let median = sorted[sorted.count / 2]
    return segmentMs.filter { $0 >= max(80, median * 2.2) }
}

private func computePathLength(_ points: [ObservedPoint]) -> Double {
    guard points.count > 1 else {
        return 0
    }
    return zip(points.dropFirst(), points).reduce(0) { total, pair in
        total + distance(pair.0, pair.1)
    }
}

private func computeStraightness(_ points: [ObservedPoint]) -> Double? {
    guard let first = points.first, let last = points.last else {
        return nil
    }
    let pathLength = computePathLength(points)
    guard pathLength > 0 else {
        return nil
    }
    return min(1, max(0, distance(first, last) / pathLength))
}

private func computeTurnJitter(_ points: [ObservedPoint]) -> Double? {
    guard points.count > 2 else {
        return nil
    }
    var turns = [Double]()
    for index in 1..<(points.count - 1) {
        let previous = points[index - 1]
        let current = points[index]
        let next = points[index + 1]
        let a1 = atan2(current.y - previous.y, current.x - previous.x)
        let a2 = atan2(next.y - current.y, next.x - current.x)
        turns.append(abs(normalizeAngle(a2 - a1)) / Double.pi)
    }
    guard !turns.isEmpty else {
        return nil
    }
    return min(1, max(0, turns.reduce(0, +) / Double(turns.count)))
}

private func quality(pointCount: Int, durationMs: Double?, pathLengthPx: Double) -> Double {
    var score = 0.2
    if pointCount >= 3 { score += 0.25 }
    if pointCount >= 8 { score += 0.15 }
    if (durationMs ?? 0) > 40 { score += 0.15 }
    if pathLengthPx > 12 { score += 0.15 }
    if pathLengthPx > 80 { score += 0.10 }
    return min(1, score)
}

private func distance(_ left: ObservedPoint, _ right: ObservedPoint) -> Double {
    hypot(left.x - right.x, left.y - right.y)
}

private func normalizeAngle(_ value: Double) -> Double {
    var result = value
    while result > Double.pi {
        result -= Double.pi * 2
    }
    while result < -Double.pi {
        result += Double.pi * 2
    }
    return result
}
