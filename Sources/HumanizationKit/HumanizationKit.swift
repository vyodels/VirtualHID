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
