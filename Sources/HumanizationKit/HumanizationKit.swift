import Foundation

public struct HumanPoint: Codable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct HumanModifiers: OptionSet, Codable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = HumanModifiers(rawValue: 1 << 0)
    public static let command = HumanModifiers(rawValue: 1 << 1)
}

public struct HumanKey: Equatable {
    public let keyCode: UInt16
    public let modifiers: HumanModifiers

    public init(keyCode: UInt16, modifiers: HumanModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct HumanizationProfile {
    public var windMouseParams: WindMouseParams
    public var bezierParams: BezierMouseParams
    public var keyRhythmParams: KeyRhythmParams
    public var movePointCount: Int
    public var dragPointCount: Int

    public init(
        windMouseParams: WindMouseParams = WindMouseParams(),
        bezierParams: BezierMouseParams = BezierMouseParams(),
        keyRhythmParams: KeyRhythmParams = KeyRhythmParams(),
        movePointCount: Int = 20,
        dragPointCount: Int = 18
    ) {
        self.windMouseParams = windMouseParams
        self.bezierParams = bezierParams
        self.keyRhythmParams = keyRhythmParams
        self.movePointCount = movePointCount
        self.dragPointCount = dragPointCount
    }
}

public enum MotionFlavor: String, Codable, CaseIterable {
    case smooth
    case gentle
    case hurried
    case idle
}

public enum HumanBehaviorMode: String, Codable, CaseIterable {
    case idle
    case normal
    case flow
    case lowEfficiency = "low-efficiency"
}

public struct BehaviorBlend: Codable, Hashable {
    public var idle: Double
    public var normal: Double
    public var flow: Double
    public var lowEfficiency: Double

    public init(
        idle: Double = 0,
        normal: Double = 1,
        flow: Double = 0,
        lowEfficiency: Double = 0
    ) {
        self.idle = idle
        self.normal = normal
        self.flow = flow
        self.lowEfficiency = lowEfficiency
    }
}

public struct IntRange: Codable, Hashable {
    public let min: Int
    public let max: Int

    public init(min: Int, max: Int) {
        self.min = min
        self.max = max
    }
}

public struct DoubleRange: Codable, Hashable {
    public let min: Double
    public let max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }
}

public struct LearnedPathPoint: Codable, Hashable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct MotionProfile: Codable, Hashable {
    public var flavor: MotionFlavor?
    public var behaviorBlend: BehaviorBlend?
    public var moveSpeedPxS: DoubleRange?
    public var dragSpeedPxS: DoubleRange?
    public var pointCount: IntRange?
    public var overshootProbability: Double?
    public var wind: Double?
    public var gravity: Double?
    public var maxStep: Double?
    public var jitter: Double?
    public var controlSpread: Double?
    public var targetSpreadPx: Double?
    public var hesitationProbability: Double?
    public var hesitationMs: IntRange?
    public var settleMs: IntRange?
    public var detourProbability: Double?
    public var clickHoldMs: IntRange?
    public var interClickMs: IntRange?
    public var doubleClickHoldMs: IntRange?
    public var doubleClickInterClickMs: IntRange?
    public var doubleClickSecondOffsetPx: DoubleRange?
    public var scrollDeltaX: DoubleRange?
    public var scrollDeltaY: DoubleRange?
    public var scrollStepCount: IntRange?
    public var scrollStepDelayMs: IntRange?
    public var scrollInertiaDecay: DoubleRange?
    public var dwellMs: IntRange?
    public var interKeyMs: IntRange?
    public var modifierHoldMs: IntRange?
    public var keyRepeatDelayMs: IntRange?
    public var keyRepeatIntervalMs: IntRange?
    public var pathSkeleton: [LearnedPathPoint]?
    public var segmentMs: [IntRange]?
    public var dwellMsMean: Double?
    public var interKeyMsMean: Double?
    public var straightnessMean: Double?
    public var turnJitterMean: Double?

    public init(
        flavor: MotionFlavor? = nil,
        behaviorBlend: BehaviorBlend? = nil,
        moveSpeedPxS: DoubleRange? = nil,
        dragSpeedPxS: DoubleRange? = nil,
        pointCount: IntRange? = nil,
        overshootProbability: Double? = nil,
        wind: Double? = nil,
        gravity: Double? = nil,
        maxStep: Double? = nil,
        jitter: Double? = nil,
        controlSpread: Double? = nil,
        targetSpreadPx: Double? = nil,
        hesitationProbability: Double? = nil,
        hesitationMs: IntRange? = nil,
        settleMs: IntRange? = nil,
        detourProbability: Double? = nil,
        clickHoldMs: IntRange? = nil,
        interClickMs: IntRange? = nil,
        doubleClickHoldMs: IntRange? = nil,
        doubleClickInterClickMs: IntRange? = nil,
        doubleClickSecondOffsetPx: DoubleRange? = nil,
        scrollDeltaX: DoubleRange? = nil,
        scrollDeltaY: DoubleRange? = nil,
        scrollStepCount: IntRange? = nil,
        scrollStepDelayMs: IntRange? = nil,
        scrollInertiaDecay: DoubleRange? = nil,
        dwellMs: IntRange? = nil,
        interKeyMs: IntRange? = nil,
        modifierHoldMs: IntRange? = nil,
        keyRepeatDelayMs: IntRange? = nil,
        keyRepeatIntervalMs: IntRange? = nil,
        pathSkeleton: [LearnedPathPoint]? = nil,
        segmentMs: [IntRange]? = nil,
        dwellMsMean: Double? = nil,
        interKeyMsMean: Double? = nil,
        straightnessMean: Double? = nil,
        turnJitterMean: Double? = nil
    ) {
        self.flavor = flavor
        self.behaviorBlend = behaviorBlend
        self.moveSpeedPxS = moveSpeedPxS
        self.dragSpeedPxS = dragSpeedPxS
        self.pointCount = pointCount
        self.overshootProbability = overshootProbability
        self.wind = wind
        self.gravity = gravity
        self.maxStep = maxStep
        self.jitter = jitter
        self.controlSpread = controlSpread
        self.targetSpreadPx = targetSpreadPx
        self.hesitationProbability = hesitationProbability
        self.hesitationMs = hesitationMs
        self.settleMs = settleMs
        self.detourProbability = detourProbability
        self.clickHoldMs = clickHoldMs
        self.interClickMs = interClickMs
        self.doubleClickHoldMs = doubleClickHoldMs
        self.doubleClickInterClickMs = doubleClickInterClickMs
        self.doubleClickSecondOffsetPx = doubleClickSecondOffsetPx
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.scrollStepCount = scrollStepCount
        self.scrollStepDelayMs = scrollStepDelayMs
        self.scrollInertiaDecay = scrollInertiaDecay
        self.dwellMs = dwellMs
        self.interKeyMs = interKeyMs
        self.modifierHoldMs = modifierHoldMs
        self.keyRepeatDelayMs = keyRepeatDelayMs
        self.keyRepeatIntervalMs = keyRepeatIntervalMs
        self.pathSkeleton = pathSkeleton
        self.segmentMs = segmentMs
        self.dwellMsMean = dwellMsMean
        self.interKeyMsMean = interKeyMsMean
        self.straightnessMean = straightnessMean
        self.turnJitterMean = turnJitterMean
    }
}

public struct LearnedMotionTemplate: Codable, Hashable {
    public var version: Int
    public var strategy: String
    public var actionType: String
    public var sampleSize: Int
    public var motion: MotionProfile

    public init(
        version: Int = 2,
        strategy: String = "profile",
        actionType: String,
        sampleSize: Int,
        motion: MotionProfile
    ) {
        self.version = version
        self.strategy = strategy
        self.actionType = actionType
        self.sampleSize = sampleSize
        self.motion = motion
    }
}

public struct HumanTimingPlan: Hashable {
    public let delaysMs: [Int]
    public let totalDurationMs: Int
    public let behaviorMode: HumanBehaviorMode

    public init(delaysMs: [Int], totalDurationMs: Int, behaviorMode: HumanBehaviorMode) {
        self.delaysMs = delaysMs
        self.totalDurationMs = totalDurationMs
        self.behaviorMode = behaviorMode
    }
}

public enum HumanTimingCurve {
    public static func plan<R: RandomNumberGenerator>(
        path: [HumanPoint],
        requestedDurationMs: Int?,
        profile: MotionProfile?,
        isDrag: Bool = false,
        rng: inout R
    ) -> HumanTimingPlan {
        guard path.count > 1 else {
            return HumanTimingPlan(delaysMs: [0], totalDurationMs: 0, behaviorMode: .normal)
        }

        let behaviorMode = profile?.sampleBehaviorMode(rng: &rng) ?? .normal
        let segmentLengths = zip(path.dropFirst(), path).map { next, previous in
            previous.distance(to: next)
        }
        let totalDistance = max(segmentLengths.reduce(0, +), 1)
        let speedRange = profile?.resolvedSpeedRange(isDrag: isDrag, behaviorMode: behaviorMode) ?? defaultSpeedRange(for: behaviorMode, isDrag: isDrag)
        let sampledSpeed = speedRange.sample(rng: &rng)
        let settleMs = profile?.settleMs?.sample(rng: &rng) ?? defaultSettleMs(for: behaviorMode, isDrag: isDrag)
        let autoDurationMs = Int((totalDistance / max(sampledSpeed, 80)) * 1000.0) + settleMs
        let totalDurationMs = max(requestedDurationMs ?? autoDurationMs, segmentLengths.count)

        var weights = [Double]()
        weights.reserveCapacity(segmentLengths.count)
        let turns = turnMagnitudes(path)
        for index in segmentLengths.indices {
            let progress = Double(index + 1) / Double(segmentLengths.count)
            let curveSpeed = max(0.24, 0.42 + 0.88 * pow(sin(progress * .pi), 1.12))
            let startBrake = progress < 0.12 ? 1.12 + (0.12 - progress) * 1.6 : 1.0
            let endBrake = progress > 0.80 ? 1.08 + (progress - 0.80) * 1.8 : 1.0
            let turnBoost = 1 + min(turns[index] / Double.pi, 0.9) * 0.48
            let noise = 1 + rng.nextDouble(in: -0.10..<0.10)
            let behaviorBoost = behaviorWeight(for: behaviorMode, progress: progress)
            weights.append(max(0.001, segmentLengths[index] / curveSpeed * startBrake * endBrake * turnBoost * noise * behaviorBoost))
        }

        let hesitationProbability = profile?.hesitationProbability ?? defaultHesitationProbability(for: behaviorMode, isDrag: isDrag)
        if segmentLengths.count > 2, rng.nextDouble(in: 0..<1) < hesitationProbability {
            let hesitation = profile?.hesitationMs?.sample(rng: &rng) ?? defaultHesitationMs(for: behaviorMode)
            let startIndex = max(0, Int(Double(segmentLengths.count) * 0.55))
            let extraIndex = min(segmentLengths.count - 1, startIndex + Int(rng.nextDouble(in: 0..<Double(max(1, segmentLengths.count - startIndex)))))
            weights[extraIndex] += Double(hesitation)
        }

        if let learnedSegmentMs = profile?.segmentMs, learnedSegmentMs.isEmpty == false {
            let learnedWeights = sampledSegmentWeights(learnedSegmentMs, count: segmentLengths.count, rng: &rng)
            if learnedWeights.count == weights.count {
                weights = zip(weights, learnedWeights).map { generated, learned in
                    max(0.001, generated * 0.35 + learned * 0.65)
                }
            }
        }

        let weightSum = max(weights.reduce(0, +), 1)
        var delays = [Int](repeating: 0, count: path.count)
        var allocated = 0
        for index in weights.indices {
            let raw = Double(totalDurationMs) * (weights[index] / weightSum)
            let delay = index == weights.indices.last ? max(1, totalDurationMs - allocated) : max(1, Int(raw.rounded()))
            delays[index] = delay
            allocated += delay
        }
        return HumanTimingPlan(delaysMs: delays, totalDurationMs: totalDurationMs, behaviorMode: behaviorMode)
    }

    private static func sampledSegmentWeights<R: RandomNumberGenerator>(
        _ ranges: [IntRange],
        count: Int,
        rng: inout R
    ) -> [Double] {
        guard count > 0, ranges.isEmpty == false else {
            return []
        }
        let sampled = ranges.map { max(1, $0.sample(rng: &rng)) }
        guard sampled.count != count else {
            return sampled.map(Double.init)
        }
        guard sampled.count > 1 else {
            return Array(repeating: Double(sampled[0]), count: count)
        }
        return (0..<count).map { outputIndex in
            let raw = Double(outputIndex) * Double(sampled.count - 1) / Double(max(count - 1, 1))
            let lower = Int(floor(raw))
            let upper = min(sampled.count - 1, lower + 1)
            let progress = raw - Double(lower)
            return Double(sampled[lower]) * (1 - progress) + Double(sampled[upper]) * progress
        }
    }

    private static func turnMagnitudes(_ path: [HumanPoint]) -> [Double] {
        guard path.count > 2 else {
            return Array(repeating: 0, count: max(0, path.count - 1))
        }

        var turns = [Double](repeating: 0, count: path.count - 1)
        for index in 1..<(path.count - 1) {
            let previous = path[index - 1]
            let current = path[index]
            let next = path[index + 1]
            let a1 = atan2(current.y - previous.y, current.x - previous.x)
            let a2 = atan2(next.y - current.y, next.x - current.x)
            turns[index] = abs(normalizeAngle(a2 - a1))
        }
        return turns
    }

    private static func behaviorWeight(for mode: HumanBehaviorMode, progress: Double) -> Double {
        switch mode {
        case .idle:
            return progress > 0.65 ? 1.18 : 1.06
        case .normal:
            return 1.0
        case .flow:
            return progress < 0.15 ? 0.96 : 0.88
        case .lowEfficiency:
            return progress > 0.35 && progress < 0.75 ? 1.14 : 1.08
        }
    }

    private static func defaultSpeedRange(for mode: HumanBehaviorMode, isDrag: Bool) -> DoubleRange {
        switch (mode, isDrag) {
        case (.idle, false):
            return DoubleRange(min: 100, max: 260)
        case (.idle, true):
            return DoubleRange(min: 90, max: 210)
        case (.normal, false):
            return DoubleRange(min: 260, max: 620)
        case (.normal, true):
            return DoubleRange(min: 180, max: 420)
        case (.flow, false):
            return DoubleRange(min: 520, max: 980)
        case (.flow, true):
            return DoubleRange(min: 320, max: 760)
        case (.lowEfficiency, false):
            return DoubleRange(min: 140, max: 360)
        case (.lowEfficiency, true):
            return DoubleRange(min: 110, max: 260)
        }
    }

    private static func defaultSettleMs(for mode: HumanBehaviorMode, isDrag: Bool) -> Int {
        switch (mode, isDrag) {
        case (.idle, _):
            return 90
        case (.normal, _):
            return 56
        case (.flow, _):
            return 36
        case (.lowEfficiency, _):
            return 110
        }
    }

    private static func defaultHesitationProbability(for mode: HumanBehaviorMode, isDrag: Bool) -> Double {
        switch (mode, isDrag) {
        case (.idle, _):
            return 0.34
        case (.normal, false):
            return 0.18
        case (.normal, true):
            return 0.24
        case (.flow, _):
            return 0.08
        case (.lowEfficiency, _):
            return 0.42
        }
    }

    private static func defaultHesitationMs(for mode: HumanBehaviorMode) -> Int {
        switch mode {
        case .idle:
            return 140
        case .normal:
            return 88
        case .flow:
            return 40
        case .lowEfficiency:
            return 180
        }
    }

    private static func normalizeAngle(_ value: Double) -> Double {
        var result = value
        while result > Double.pi {
            result -= Double.pi * 2
        }
        while result < -Double.pi {
            result += Double.pi * 2
        }
        return result
    }
}

public enum HumanKeyboard {
    private static let mapping: [UnicodeScalar: HumanKey] = [
        "a": HumanKey(keyCode: 0), "b": HumanKey(keyCode: 11),
        "c": HumanKey(keyCode: 8), "d": HumanKey(keyCode: 2),
        "e": HumanKey(keyCode: 14), "f": HumanKey(keyCode: 3),
        "g": HumanKey(keyCode: 5), "h": HumanKey(keyCode: 4),
        "i": HumanKey(keyCode: 34), "j": HumanKey(keyCode: 38),
        "k": HumanKey(keyCode: 40), "l": HumanKey(keyCode: 37),
        "m": HumanKey(keyCode: 46), "n": HumanKey(keyCode: 45),
        "o": HumanKey(keyCode: 31), "p": HumanKey(keyCode: 35),
        "q": HumanKey(keyCode: 12), "r": HumanKey(keyCode: 15),
        "s": HumanKey(keyCode: 1), "t": HumanKey(keyCode: 17),
        "u": HumanKey(keyCode: 32), "v": HumanKey(keyCode: 9),
        "w": HumanKey(keyCode: 13), "x": HumanKey(keyCode: 7),
        "y": HumanKey(keyCode: 16), "z": HumanKey(keyCode: 6),
        "1": HumanKey(keyCode: 18), "2": HumanKey(keyCode: 19),
        "3": HumanKey(keyCode: 20), "4": HumanKey(keyCode: 21),
        "5": HumanKey(keyCode: 23), "6": HumanKey(keyCode: 22),
        "7": HumanKey(keyCode: 26), "8": HumanKey(keyCode: 28),
        "9": HumanKey(keyCode: 25), "0": HumanKey(keyCode: 29),
        " ": HumanKey(keyCode: 49),
        "\t": HumanKey(keyCode: 48),
        "\n": HumanKey(keyCode: 36)
    ]

    public static func key(for scalar: UnicodeScalar) -> HumanKey? {
        if let direct = mapping[scalar] {
            return direct
        }

        let lowercase = scalar.properties.lowercaseMapping.unicodeScalars
        if lowercase.count == 1,
           let lowered = lowercase.first,
           let base = mapping[lowered],
           scalar.properties.isUppercase {
            return HumanKey(keyCode: base.keyCode, modifiers: [.shift])
        }

        return nil
    }
}

public struct WindMouseParams {
    public var gravity: Double
    public var wind: Double
    public var maxStep: Double
    public var distanceDecay: Double
    public var targetArea: Double
    public var overshootProbability: Double

    public init(
        gravity: Double = 9.0,
        wind: Double = 3.0,
        maxStep: Double = 15.0,
        distanceDecay: Double = 12.0,
        targetArea: Double = 4.0,
        overshootProbability: Double = 0.5
    ) {
        self.gravity = gravity
        self.wind = wind
        self.maxStep = maxStep
        self.distanceDecay = distanceDecay
        self.targetArea = targetArea
        self.overshootProbability = overshootProbability
    }
}

public enum WindMouse {
    public static func path<R: RandomNumberGenerator>(
        from start: HumanPoint,
        to target: HumanPoint,
        params: WindMouseParams = WindMouseParams(),
        rng: inout R
    ) -> [HumanPoint] {
        let distance = start.distance(to: target)
        guard distance > 0 else {
            return [start]
        }

        let shouldOvershoot = rng.nextDouble(in: 0..<1) < params.overshootProbability && distance > params.targetArea * 4
        if shouldOvershoot {
            let overshootDistance = min(max(distance * rng.nextDouble(in: 0.04..<0.10), 4), 32)
            let dx = (target.x - start.x) / distance
            let dy = (target.y - start.y) / distance
            let overshoot = HumanPoint(
                x: target.x + dx * overshootDistance,
                y: target.y + dy * overshootDistance
            )
            var firstLeg = segment(from: start, to: overshoot, params: params, rng: &rng)
            var correctionParams = params
            correctionParams.wind = max(0.8, params.wind * 0.55)
            correctionParams.maxStep = max(4, params.maxStep * 0.55)
            correctionParams.overshootProbability = 0
            let correction = segment(from: firstLeg.last ?? overshoot, to: target, params: correctionParams, rng: &rng)
            firstLeg.append(contentsOf: correction.dropFirst())
            return firstLeg
        }

        return segment(from: start, to: target, params: params, rng: &rng)
    }

    public static func resampledPath<R: RandomNumberGenerator>(
        from start: HumanPoint,
        to target: HumanPoint,
        count: Int,
        params: WindMouseParams = WindMouseParams(),
        rng: inout R
    ) -> [HumanPoint] {
        guard count > 0 else {
            return []
        }
        guard count > 1 else {
            return [target]
        }

        let rawPath = path(from: start, to: target, params: params, rng: &rng)
        var sampled = rawPath.resampled(count: count)
        sampled.ensureTerminalCorrection(from: start, to: target, rng: &rng)
        return sampled
    }

    private static func segment<R: RandomNumberGenerator>(
        from start: HumanPoint,
        to target: HumanPoint,
        params: WindMouseParams,
        rng: inout R
    ) -> [HumanPoint] {
        let sqrt3 = sqrt(3.0)
        let sqrt5 = sqrt(5.0)
        var current = start
        var velocityX = 0.0
        var velocityY = 0.0
        var windX = 0.0
        var windY = 0.0
        var points = [start]

        for _ in 0..<10_000 {
            let distance = current.distance(to: target)
            if distance <= params.targetArea {
                break
            }

            let windMagnitude = min(params.wind, distance)
            if distance >= params.distanceDecay {
                windX = windX / sqrt3 + rng.nextDouble(in: -windMagnitude..<windMagnitude) / sqrt5
                windY = windY / sqrt3 + rng.nextDouble(in: -windMagnitude..<windMagnitude) / sqrt5
            } else {
                windX /= sqrt3
                windY /= sqrt3
            }

            velocityX += windX + params.gravity * (target.x - current.x) / distance
            velocityY += windY + params.gravity * (target.y - current.y) / distance

            let velocityMagnitude = hypot(velocityX, velocityY)
            let localMaxStep = distance < params.distanceDecay
                ? max(3, params.maxStep * distance / params.distanceDecay)
                : params.maxStep
            if velocityMagnitude > localMaxStep {
                let clipped = rng.nextDouble(in: localMaxStep * 0.55..<localMaxStep)
                velocityX = velocityX / velocityMagnitude * clipped
                velocityY = velocityY / velocityMagnitude * clipped
            }

            current = HumanPoint(x: current.x + velocityX, y: current.y + velocityY)
            points.append(current)
        }

        if points.last != target {
            points.append(target)
        }
        return points
    }
}

public struct BezierMouseParams {
    public var controlSpread: Double
    public var jitter: Double

    public init(controlSpread: Double = 0.25, jitter: Double = 1.5) {
        self.controlSpread = controlSpread
        self.jitter = jitter
    }
}

public enum BezierMouse {
    public static func path<R: RandomNumberGenerator>(
        from start: HumanPoint,
        to target: HumanPoint,
        count: Int,
        params: BezierMouseParams = BezierMouseParams(),
        rng: inout R
    ) -> [HumanPoint] {
        guard count > 1 else {
            return [target]
        }

        let dx = target.x - start.x
        let dy = target.y - start.y
        let distance = max(hypot(dx, dy), 1)
        let normalX = -dy / distance
        let normalY = dx / distance
        let spread = distance * params.controlSpread
        let control1 = HumanPoint(
            x: start.x + dx * rng.nextDouble(in: 0.20..<0.40) + normalX * rng.nextDouble(in: -spread..<spread),
            y: start.y + dy * rng.nextDouble(in: 0.20..<0.40) + normalY * rng.nextDouble(in: -spread..<spread)
        )
        let control2 = HumanPoint(
            x: start.x + dx * rng.nextDouble(in: 0.60..<0.85) + normalX * rng.nextDouble(in: -spread..<spread),
            y: start.y + dy * rng.nextDouble(in: 0.60..<0.85) + normalY * rng.nextDouble(in: -spread..<spread)
        )

        return (0..<count).map { index in
            let t = Double(index) / Double(count - 1)
            let oneMinusT = 1 - t
            var point = HumanPoint(
                x: oneMinusT * oneMinusT * oneMinusT * start.x
                    + 3 * oneMinusT * oneMinusT * t * control1.x
                    + 3 * oneMinusT * t * t * control2.x
                    + t * t * t * target.x,
                y: oneMinusT * oneMinusT * oneMinusT * start.y
                    + 3 * oneMinusT * oneMinusT * t * control1.y
                    + 3 * oneMinusT * t * t * control2.y
                    + t * t * t * target.y
            )
            if index != 0 && index != count - 1 {
                point.x += rng.nextDouble(in: -params.jitter..<params.jitter)
                point.y += rng.nextDouble(in: -params.jitter..<params.jitter)
            }
            return point
        }
    }
}

public struct KeyRhythmParams {
    public var dwellMsRange: ClosedRange<Int>
    public var dwellShape: (alpha: Double, beta: Double)
    public var intraWordMu: Double
    public var intraWordSigma: Double
    public var interWordMu: Double
    public var interWordSigma: Double

    public init(
        dwellMsRange: ClosedRange<Int> = 40...180,
        dwellShape: (alpha: Double, beta: Double) = (2.0, 5.0),
        intraWordMu: Double = log(110),
        intraWordSigma: Double = 0.35,
        interWordMu: Double = log(180),
        interWordSigma: Double = 0.40
    ) {
        self.dwellMsRange = dwellMsRange
        self.dwellShape = dwellShape
        self.intraWordMu = intraWordMu
        self.intraWordSigma = intraWordSigma
        self.interWordMu = interWordMu
        self.interWordSigma = interWordSigma
    }
}

public struct KeystrokeEvent: Equatable {
    public let char: Character
    public let keyCode: UInt16
    public let modifiers: HumanModifiers
    public let dwellMs: Int
    public let delayBeforeMs: Int

    public init(char: Character, keyCode: UInt16, modifiers: HumanModifiers, dwellMs: Int, delayBeforeMs: Int) {
        self.char = char
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.dwellMs = dwellMs
        self.delayBeforeMs = delayBeforeMs
    }
}

public enum KeystrokeRhythm {
    public static func schedule<R: RandomNumberGenerator>(
        for text: String,
        params: KeyRhythmParams = KeyRhythmParams(),
        rng: inout R
    ) -> [KeystrokeEvent] {
        var events = [KeystrokeEvent]()
        var previousWasWhitespace = false

        for scalar in text.unicodeScalars {
            guard let key = HumanKeyboard.key(for: scalar) else {
                continue
            }

            let normalized = Swift.min(Swift.max(sampleBeta(alpha: params.dwellShape.alpha, beta: params.dwellShape.beta, rng: &rng), 0), 1)
            let dwellSpan = params.dwellMsRange.upperBound - params.dwellMsRange.lowerBound
            let dwellMs = params.dwellMsRange.lowerBound + Int((Double(dwellSpan) * normalized).rounded())

            let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            let delayBeforeMs: Int
            if events.isEmpty {
                delayBeforeMs = 0
            } else if previousWasWhitespace || isWhitespace {
                delayBeforeMs = Int(sampleLogNormal(mu: params.interWordMu, sigma: params.interWordSigma, rng: &rng).rounded())
            } else {
                delayBeforeMs = Int(sampleLogNormal(mu: params.intraWordMu, sigma: params.intraWordSigma, rng: &rng).rounded())
            }

            events.append(
                KeystrokeEvent(
                    char: Character(String(scalar)),
                    keyCode: key.keyCode,
                    modifiers: key.modifiers,
                    dwellMs: dwellMs,
                    delayBeforeMs: max(0, delayBeforeMs)
                )
            )
            previousWasWhitespace = isWhitespace
        }

        return events
    }

    private static func sampleLogNormal<R: RandomNumberGenerator>(mu: Double, sigma: Double, rng: inout R) -> Double {
        exp(mu + sigma * rng.nextNormal())
    }

    private static func sampleBeta<R: RandomNumberGenerator>(alpha: Double, beta: Double, rng: inout R) -> Double {
        let a = max(alpha, 0.001)
        let b = max(beta, 0.001)
        let x = sampleGamma(shape: a, rng: &rng)
        let y = sampleGamma(shape: b, rng: &rng)
        return x / (x + y)
    }

    private static func sampleGamma<R: RandomNumberGenerator>(shape: Double, rng: inout R) -> Double {
        if shape < 1 {
            let u = rng.nextDouble(in: 0..<1)
            return sampleGamma(shape: shape + 1, rng: &rng) * pow(u, 1 / shape)
        }

        let d = shape - 1 / 3
        let c = 1 / sqrt(9 * d)
        while true {
            let x = rng.nextNormal()
            let v = pow(1 + c * x, 3)
            if v <= 0 {
                continue
            }
            let u = rng.nextDouble(in: 0..<1)
            if u < 1 - 0.0331 * x * x * x * x {
                return d * v
            }
            if log(u) < 0.5 * x * x + d * (1 - v + log(v)) {
                return d * v
            }
        }
    }
}

public struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0x4d595df4d0f33173 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

private extension HumanPoint {
    func distance(to other: HumanPoint) -> Double {
        hypot(other.x - x, other.y - y)
    }
}

private extension Array where Element == HumanPoint {
    func resampled(count: Int) -> [HumanPoint] {
        guard count > 0 else {
            return []
        }
        guard count > 1, self.count > 1 else {
            return [last ?? HumanPoint(x: 0, y: 0)]
        }

        var distances = [Double](repeating: 0, count: self.count)
        for index in 1..<self.count {
            distances[index] = distances[index - 1] + self[index - 1].distance(to: self[index])
        }

        guard let totalDistance = distances.last, totalDistance > 0 else {
            return Array(repeating: last!, count: count)
        }

        return (0..<count).map { outputIndex in
            let targetDistance = totalDistance * Double(outputIndex) / Double(count - 1)
            var segmentIndex = 1
            while segmentIndex < distances.count && distances[segmentIndex] < targetDistance {
                segmentIndex += 1
            }
            if segmentIndex >= self.count {
                return self[self.count - 1]
            }

            let previousDistance = distances[segmentIndex - 1]
            let nextDistance = distances[segmentIndex]
            let span = Swift.max(nextDistance - previousDistance, Double.ulpOfOne)
            let progress = (targetDistance - previousDistance) / span
            let start = self[segmentIndex - 1]
            let end = self[segmentIndex]
            return HumanPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
        }
    }

    mutating func ensureTerminalCorrection<R: RandomNumberGenerator>(
        from start: HumanPoint,
        to target: HumanPoint,
        rng: inout R
    ) {
        guard count >= 4 else {
            return
        }
        guard isMonotonic(\.x) && isMonotonic(\.y) else {
            return
        }

        let dx = target.x - start.x
        let dy = target.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 12 else {
            return
        }

        let overshoot = Swift.min(Swift.max(distance * rng.nextDouble(in: 0.012..<0.026), 2), 9)
        let correctionIndex = count - 2
        self[correctionIndex] = HumanPoint(
            x: target.x + direction(dx) * overshoot,
            y: target.y + direction(dy) * overshoot
        )
        self[count - 1] = target
    }

    private func isMonotonic(_ keyPath: KeyPath<HumanPoint, Double>) -> Bool {
        guard count > 2 else {
            return true
        }
        var nonDecreasing = true
        var nonIncreasing = true
        for index in 1..<count {
            let previous = self[index - 1][keyPath: keyPath]
            let current = self[index][keyPath: keyPath]
            if current < previous {
                nonDecreasing = false
            }
            if current > previous {
                nonIncreasing = false
            }
        }
        return nonDecreasing || nonIncreasing
    }

    private func direction(_ value: Double) -> Double {
        if value > 0 {
            return 1
        }
        if value < 0 {
            return -1
        }
        return 0
    }
}

public extension IntRange {
    func sample<R: RandomNumberGenerator>(rng: inout R) -> Int {
        guard max > min else {
            return min
        }
        let span = Double(max - min + 1)
        return min + Int(floor(rng.nextDouble(in: 0..<span)))
    }
}

public extension DoubleRange {
    func sample<R: RandomNumberGenerator>(rng: inout R) -> Double {
        guard max > min else {
            return min
        }
        return rng.nextDouble(in: min..<max)
    }
}

public extension BehaviorBlend {
    func normalized() -> BehaviorBlend {
        let total = max(idle + normal + flow + lowEfficiency, Double.leastNonzeroMagnitude)
        return BehaviorBlend(
            idle: idle / total,
            normal: normal / total,
            flow: flow / total,
            lowEfficiency: lowEfficiency / total
        )
    }

    func sample<R: RandomNumberGenerator>(rng: inout R) -> HumanBehaviorMode {
        let weights = normalized()
        let threshold = rng.nextDouble(in: 0..<1)
        let idleCutoff = weights.idle
        let normalCutoff = idleCutoff + weights.normal
        let flowCutoff = normalCutoff + weights.flow
        switch threshold {
        case ..<idleCutoff:
            return .idle
        case ..<normalCutoff:
            return .normal
        case ..<flowCutoff:
            return .flow
        default:
            return .lowEfficiency
        }
    }
}

public extension MotionProfile {
    func merging(_ override: MotionProfile?) -> MotionProfile {
        guard let override else {
            return self
        }
        return MotionProfile(
            flavor: override.flavor ?? flavor,
            behaviorBlend: override.behaviorBlend ?? behaviorBlend,
            moveSpeedPxS: override.moveSpeedPxS ?? moveSpeedPxS,
            dragSpeedPxS: override.dragSpeedPxS ?? dragSpeedPxS,
            pointCount: override.pointCount ?? pointCount,
            overshootProbability: override.overshootProbability ?? overshootProbability,
            wind: override.wind ?? wind,
            gravity: override.gravity ?? gravity,
            maxStep: override.maxStep ?? maxStep,
            jitter: override.jitter ?? jitter,
            controlSpread: override.controlSpread ?? controlSpread,
            targetSpreadPx: override.targetSpreadPx ?? targetSpreadPx,
            hesitationProbability: override.hesitationProbability ?? hesitationProbability,
            hesitationMs: override.hesitationMs ?? hesitationMs,
            settleMs: override.settleMs ?? settleMs,
            detourProbability: override.detourProbability ?? detourProbability,
            clickHoldMs: override.clickHoldMs ?? clickHoldMs,
            interClickMs: override.interClickMs ?? interClickMs,
            doubleClickHoldMs: override.doubleClickHoldMs ?? doubleClickHoldMs,
            doubleClickInterClickMs: override.doubleClickInterClickMs ?? doubleClickInterClickMs,
            doubleClickSecondOffsetPx: override.doubleClickSecondOffsetPx ?? doubleClickSecondOffsetPx,
            scrollDeltaX: override.scrollDeltaX ?? scrollDeltaX,
            scrollDeltaY: override.scrollDeltaY ?? scrollDeltaY,
            scrollStepCount: override.scrollStepCount ?? scrollStepCount,
            scrollStepDelayMs: override.scrollStepDelayMs ?? scrollStepDelayMs,
            scrollInertiaDecay: override.scrollInertiaDecay ?? scrollInertiaDecay,
            dwellMs: override.dwellMs ?? dwellMs,
            interKeyMs: override.interKeyMs ?? interKeyMs,
            modifierHoldMs: override.modifierHoldMs ?? modifierHoldMs,
            keyRepeatDelayMs: override.keyRepeatDelayMs ?? keyRepeatDelayMs,
            keyRepeatIntervalMs: override.keyRepeatIntervalMs ?? keyRepeatIntervalMs,
            pathSkeleton: override.pathSkeleton ?? pathSkeleton,
            segmentMs: override.segmentMs ?? segmentMs,
            dwellMsMean: override.dwellMsMean ?? dwellMsMean,
            interKeyMsMean: override.interKeyMsMean ?? interKeyMsMean,
            straightnessMean: override.straightnessMean ?? straightnessMean,
            turnJitterMean: override.turnJitterMean ?? turnJitterMean
        )
    }

    func sampleBehaviorMode<R: RandomNumberGenerator>(rng: inout R) -> HumanBehaviorMode {
        if let behaviorBlend {
            return behaviorBlend.sample(rng: &rng)
        }
        switch flavor {
        case .hurried:
            return .flow
        case .idle:
            return .idle
        case .gentle:
            return .normal
        case .smooth:
            return .normal
        case nil:
            return .normal
        }
    }

    func resolvedSpeedRange(isDrag: Bool, behaviorMode: HumanBehaviorMode) -> DoubleRange {
        if isDrag, let dragSpeedPxS {
            return dragSpeedPxS
        }
        if let moveSpeedPxS {
            return moveSpeedPxS
        }
        switch behaviorMode {
        case .idle:
            return isDrag ? DoubleRange(min: 90, max: 210) : DoubleRange(min: 100, max: 260)
        case .normal:
            return isDrag ? DoubleRange(min: 180, max: 420) : DoubleRange(min: 260, max: 620)
        case .flow:
            return isDrag ? DoubleRange(min: 320, max: 760) : DoubleRange(min: 520, max: 980)
        case .lowEfficiency:
            return isDrag ? DoubleRange(min: 110, max: 260) : DoubleRange(min: 140, max: 360)
        }
    }

    func resolvedPointCount<R: RandomNumberGenerator>(fallback: Int, rng: inout R) -> Int {
        max(1, pointCount?.sample(rng: &rng) ?? fallback)
    }

    func resolvedWindParams(base: WindMouseParams) -> WindMouseParams {
        var params = base
        if let gravity {
            params.gravity = gravity
        }
        if let wind {
            params.wind = wind
        }
        if let maxStep {
            params.maxStep = maxStep
        }
        if let overshootProbability {
            params.overshootProbability = overshootProbability
        }
        if let targetSpreadPx {
            params.targetArea = max(1, targetSpreadPx)
        }
        return params
    }

    func resolvedBezierParams(base: BezierMouseParams) -> BezierMouseParams {
        var params = base
        if let controlSpread {
            params.controlSpread = controlSpread
        }
        if let jitter {
            params.jitter = jitter
        }
        return params
    }

    func resolvedClickHoldMs<R: RandomNumberGenerator>(defaultValue: Int, rng: inout R) -> Int {
        max(12, clickHoldMs?.sample(rng: &rng) ?? defaultValue)
    }

    func resolvedInterClickMs<R: RandomNumberGenerator>(defaultValue: Int, rng: inout R) -> Int {
        max(24, interClickMs?.sample(rng: &rng) ?? defaultValue)
    }

    func resolvedDoubleClickHoldMs<R: RandomNumberGenerator>(defaultValue: Int, rng: inout R) -> Int {
        max(12, doubleClickHoldMs?.sample(rng: &rng) ?? clickHoldMs?.sample(rng: &rng) ?? defaultValue)
    }

    func resolvedDoubleClickInterClickMs<R: RandomNumberGenerator>(defaultValue: Int, rng: inout R) -> Int {
        max(24, doubleClickInterClickMs?.sample(rng: &rng) ?? interClickMs?.sample(rng: &rng) ?? defaultValue)
    }

    func resolvedDoubleClickSecondOffset<R: RandomNumberGenerator>(rng: inout R) -> HumanPoint {
        guard let range = doubleClickSecondOffsetPx else {
            return HumanPoint(x: 0, y: 0)
        }
        let radius = max(0, range.sample(rng: &rng))
        guard radius > 0 else {
            return HumanPoint(x: 0, y: 0)
        }
        let angle = rng.nextDouble(in: 0..<(Double.pi * 2))
        return HumanPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    func resolvedScrollStepCount<R: RandomNumberGenerator>(fallback: Int, rng: inout R) -> Int {
        max(1, scrollStepCount?.sample(rng: &rng) ?? fallback)
    }

    func resolvedScrollDelayMs<R: RandomNumberGenerator>(fallback: Int, rng: inout R) -> Int {
        max(0, scrollStepDelayMs?.sample(rng: &rng) ?? fallback)
    }

    func resolvedScrollInertiaDecay<R: RandomNumberGenerator>(rng: inout R) -> Double {
        min(0.98, max(0.20, scrollInertiaDecay?.sample(rng: &rng) ?? 0.72))
    }

    func resolvedScrollDelta<R: RandomNumberGenerator>(requestedDx: Double, requestedDy: Double, rng: inout R) -> HumanPoint {
        let dx = signedSample(range: scrollDeltaX, requested: requestedDx, rng: &rng)
        let dy = signedSample(range: scrollDeltaY, requested: requestedDy, rng: &rng)
        return HumanPoint(x: dx, y: dy)
    }

    func resolvedDwellMs<R: RandomNumberGenerator>(defaultValue: Int, rng: inout R) -> Int {
        if let dwellMs {
            return max(12, dwellMs.sample(rng: &rng))
        }
        if let dwellMsMean {
            let lower = max(24, Int((dwellMsMean * 0.68).rounded()))
            let upper = max(lower + 8, Int((dwellMsMean * 1.36).rounded()))
            return IntRange(min: lower, max: upper).sample(rng: &rng)
        }
        return max(12, defaultValue)
    }

    func resolvedInterKeyMs<R: RandomNumberGenerator>(defaultValue: Int, rng: inout R) -> Int {
        if let interKeyMs {
            return max(0, interKeyMs.sample(rng: &rng))
        }
        if let interKeyMsMean {
            let lower = max(16, Int((interKeyMsMean * 0.65).rounded()))
            let upper = max(lower + 8, Int((interKeyMsMean * 1.45).rounded()))
            return IntRange(min: lower, max: upper).sample(rng: &rng)
        }
        return max(0, defaultValue)
    }

    func resolvedTargetOffset<R: RandomNumberGenerator>(rng: inout R) -> HumanPoint {
        let spread = max(targetSpreadPx ?? 0, 0)
        guard spread > 0 else {
            return HumanPoint(x: 0, y: 0)
        }
        let radius = rng.nextDouble(in: 0..<spread)
        let angle = rng.nextDouble(in: 0..<(Double.pi * 2))
        return HumanPoint(
            x: cos(angle) * radius,
            y: sin(angle) * radius
        )
    }

    private func signedSample<R: RandomNumberGenerator>(range: DoubleRange?, requested: Double, rng: inout R) -> Double {
        guard let range else {
            return requested
        }
        let magnitude = max(0, abs(range.sample(rng: &rng)))
        if requested < 0 {
            return -magnitude
        }
        if requested > 0 {
            return magnitude
        }
        return rng.nextDouble(in: 0..<1) < 0.5 ? -magnitude : magnitude
    }
}

private extension RandomNumberGenerator {
    mutating func nextDouble(in range: Range<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }

    mutating func nextNormal() -> Double {
        let u1 = max(nextDouble(in: 0..<1), Double.leastNonzeroMagnitude)
        let u2 = nextDouble(in: 0..<1)
        return sqrt(-2 * log(u1)) * cos(2 * Double.pi * u2)
    }
}
