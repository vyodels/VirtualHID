import CoreGraphics
import Foundation

public enum CoordinateSpace: String, Codable {
    case screen
    case viewport
    case document
}

public struct TargetDescriptor: Codable, Equatable {
    public let bundleId: String?
    public let windowId: Int?
    public let windowTitle: String?
    public let tabId: Int?
    public let host: String?

    public init(bundleId: String? = nil, windowId: Int? = nil, windowTitle: String? = nil, tabId: Int? = nil, host: String? = nil) {
        self.bundleId = bundleId
        self.windowId = windowId
        self.windowTitle = windowTitle
        self.tabId = tabId
        self.host = host
    }
}

public struct TargetCandidate: Equatable {
    public let bundleId: String
    public let windowId: Int?
    public let windowTitle: String?
    public let tabId: Int?
    public let host: String?
    public let frontmost: Bool

    public init(bundleId: String, windowId: Int? = nil, windowTitle: String? = nil, tabId: Int? = nil, host: String? = nil, frontmost: Bool = false) {
        self.bundleId = bundleId
        self.windowId = windowId
        self.windowTitle = windowTitle
        self.tabId = tabId
        self.host = host
        self.frontmost = frontmost
    }
}

public struct TargetResolution: Equatable {
    public let descriptor: TargetDescriptor
    public let candidate: TargetCandidate
    public let confidence: Double
    public let activationRequired: Bool

    public init(descriptor: TargetDescriptor, candidate: TargetCandidate, confidence: Double, activationRequired: Bool) {
        self.descriptor = descriptor
        self.candidate = candidate
        self.confidence = confidence
        self.activationRequired = activationRequired
    }
}

public enum TargetResolverV2Error: Error, Equatable, LocalizedError {
    case noCandidate
    case ambiguous([TargetCandidate])

    public var errorDescription: String? {
        switch self {
        case .noCandidate:
            return "no target candidate matched descriptor"
        case .ambiguous:
            return "target descriptor matched multiple weak candidates"
        }
    }
}

public enum TargetResolverV2 {
    public static func resolve(descriptor: TargetDescriptor, candidates: [TargetCandidate]) throws -> TargetResolution {
        let resolutions = candidates
            .filter { matches(descriptor: descriptor, candidate: $0) }
            .map { candidate in
                TargetResolution(
                    descriptor: descriptor,
                    candidate: candidate,
                    confidence: confidence(descriptor: descriptor, candidate: candidate),
                    activationRequired: !candidate.frontmost
                )
            }
            .sorted { $0.confidence > $1.confidence }

        guard let best = resolutions.first else {
            throw TargetResolverV2Error.noCandidate
        }
        if resolutions.count > 1, best.confidence < 0.75, resolutions[1].confidence == best.confidence {
            throw TargetResolverV2Error.ambiguous(resolutions.map { $0.candidate })
        }
        return best
    }

    private static func matches(descriptor: TargetDescriptor, candidate: TargetCandidate) -> Bool {
        if let bundleId = descriptor.bundleId, bundleId != candidate.bundleId { return false }
        if let windowId = descriptor.windowId, windowId != candidate.windowId { return false }
        if let tabId = descriptor.tabId, tabId != candidate.tabId { return false }
        if let host = descriptor.host, host != candidate.host { return false }
        if let title = descriptor.windowTitle, candidate.windowTitle?.contains(title) != true { return false }
        return true
    }

    private static func confidence(descriptor: TargetDescriptor, candidate: TargetCandidate) -> Double {
        var score = 0.0
        if descriptor.bundleId != nil { score += 0.20 }
        if descriptor.windowId != nil { score += 0.26 }
        if descriptor.tabId != nil { score += 0.30 }
        if descriptor.host != nil { score += 0.16 }
        if descriptor.windowTitle != nil { score += 0.08 }
        if candidate.frontmost { score += 0.05 }
        return min(1, score)
    }
}

public struct ViewportGeometry: Codable, Equatable {
    public let coordSpace: CoordinateSpace
    public let viewportInScreen: CodableRect
    public let pageScale: Double
    public let scrollOffset: CodablePoint
    public let viewportSize: CodableRect?

    public init(
        coordSpace: CoordinateSpace = .viewport,
        viewportInScreen: CodableRect,
        pageScale: Double = 1,
        scrollOffset: CodablePoint = CodablePoint(x: 0, y: 0),
        viewportSize: CodableRect? = nil
    ) {
        self.coordSpace = coordSpace
        self.viewportInScreen = viewportInScreen
        self.pageScale = pageScale
        self.scrollOffset = scrollOffset
        self.viewportSize = viewportSize
    }
}

public struct ViewportGeometryRequest: Equatable {
    public let coordSpace: CoordinateSpace
    public let callerViewportInScreen: CodableRect?
    public let pageScale: Double
    public let scrollOffset: CodablePoint
    public let viewportSize: CodableRect?

    public init(
        coordSpace: CoordinateSpace,
        callerViewportInScreen: CodableRect? = nil,
        pageScale: Double = 1,
        scrollOffset: CodablePoint = CodablePoint(x: 0, y: 0),
        viewportSize: CodableRect? = nil
    ) {
        self.coordSpace = coordSpace
        self.callerViewportInScreen = callerViewportInScreen
        self.pageScale = pageScale
        self.scrollOffset = scrollOffset
        self.viewportSize = viewportSize
    }
}

public struct ViewportGeometryResolution: Equatable {
    public let geometry: ViewportGeometry
    public let viewportSource: String
    public let ignoredCallerViewportInScreen: Bool

    public init(geometry: ViewportGeometry, viewportSource: String, ignoredCallerViewportInScreen: Bool) {
        self.geometry = geometry
        self.viewportSource = viewportSource
        self.ignoredCallerViewportInScreen = ignoredCallerViewportInScreen
    }
}

public enum ViewportGeometryResolverError: Error, Equatable, LocalizedError {
    case unresolvedViewport(bundleIdentifier: String, windowTitle: String?)

    public var errorDescription: String? {
        switch self {
        case .unresolvedViewport(let bundleIdentifier, let windowTitle):
            let title = windowTitle.map { " title=\($0)" } ?? ""
            return "unable to resolve web content viewport for \(bundleIdentifier)\(title) using macOS AX/CG evidence"
        }
    }
}

public enum ViewportGeometryResolver {
    public static func resolve(request: ViewportGeometryRequest, target: BrowserTarget) throws -> ViewportGeometryResolution {
        if request.coordSpace == .screen {
            return ViewportGeometryResolution(
                geometry: ViewportGeometry(
                    coordSpace: .screen,
                    viewportInScreen: request.callerViewportInScreen ?? CodableRect(x: 0, y: 0, width: 0, height: 0),
                    pageScale: request.pageScale,
                    scrollOffset: request.scrollOffset,
                    viewportSize: request.viewportSize
                ),
                viewportSource: request.callerViewportInScreen == nil ? "screen-pass-through" : "caller-screen-origin",
                ignoredCallerViewportInScreen: false
            )
        }

        guard let resolvedViewport = target.viewportFrame else {
            throw ViewportGeometryResolverError.unresolvedViewport(
                bundleIdentifier: target.bundleIdentifier,
                windowTitle: target.windowTitle
            )
        }
        let resolvedRect = CodableRect(
            x: resolvedViewport.origin.x,
            y: resolvedViewport.origin.y,
            width: resolvedViewport.width,
            height: resolvedViewport.height
        )
        let scale = max(request.pageScale, 0.01)
        let viewportSize = request.viewportSize ?? CodableRect(
            x: 0,
            y: 0,
            width: resolvedRect.width / scale,
            height: resolvedRect.height / scale
        )
        return ViewportGeometryResolution(
            geometry: ViewportGeometry(
                coordSpace: request.coordSpace,
                viewportInScreen: resolvedRect,
                pageScale: request.pageScale,
                scrollOffset: request.scrollOffset,
                viewportSize: viewportSize
            ),
            viewportSource: target.viewportFrameSource ?? "target-window-frame",
            ignoredCallerViewportInScreen: request.callerViewportInScreen != nil
        )
    }
}

public struct ViewportMappingResult: Equatable {
    public let screenPoint: CGPoint
    public let viewportPoint: CGPoint
    public let scrollDelta: CGVector
    public let alreadyVisible: Bool

    public init(screenPoint: CGPoint, viewportPoint: CGPoint, scrollDelta: CGVector, alreadyVisible: Bool) {
        self.screenPoint = screenPoint
        self.viewportPoint = viewportPoint
        self.scrollDelta = scrollDelta
        self.alreadyVisible = alreadyVisible
    }
}

public enum ViewportMapper {
    public static func map(point: CGPoint, coordinateSpace: CoordinateSpace, geometry: ViewportGeometry) -> ViewportMappingResult {
        let scale = max(geometry.pageScale, 0.01)
        let viewportPoint: CGPoint
        switch coordinateSpace {
        case .screen:
            viewportPoint = CGPoint(
                x: (point.x - geometry.viewportInScreen.x) / scale,
                y: (point.y - geometry.viewportInScreen.y) / scale
            )
        case .viewport:
            viewportPoint = point
        case .document:
            viewportPoint = CGPoint(
                x: point.x - geometry.scrollOffset.x,
                y: point.y - geometry.scrollOffset.y
            )
        }

        let screenPoint = CGPoint(
            x: geometry.viewportInScreen.x + viewportPoint.x * scale,
            y: geometry.viewportInScreen.y + viewportPoint.y * scale
        )
        let visibleRect = geometry.viewportSize.map {
            CGRect(x: 0, y: 0, width: $0.width, height: $0.height)
        } ?? CGRect(x: 0, y: 0, width: geometry.viewportInScreen.width / scale, height: geometry.viewportInScreen.height / scale)
        let alreadyVisible = visibleRect.contains(viewportPoint)
        let scrollDelta = alreadyVisible
            ? CGVector(dx: 0, dy: 0)
            : CGVector(
                dx: viewportPoint.x < visibleRect.minX ? viewportPoint.x - visibleRect.minX : max(0, viewportPoint.x - visibleRect.maxX),
                dy: viewportPoint.y < visibleRect.minY ? viewportPoint.y - visibleRect.minY : max(0, viewportPoint.y - visibleRect.maxY)
            )

        return ViewportMappingResult(
            screenPoint: screenPoint,
            viewportPoint: viewportPoint,
            scrollDelta: scrollDelta,
            alreadyVisible: alreadyVisible
        )
    }

    public static func mapPrimitive(_ primitive: ActionPrimitive, geometry: ViewportGeometry?) -> (primitive: ActionPrimitive, scrollDelta: CGVector?) {
        guard let geometry, geometry.coordSpace != .screen else {
            return (primitive, nil)
        }

        switch primitive {
        case .move(let to, let via, let durationMs, let profile):
            let mapped = map(point: to, coordinateSpace: geometry.coordSpace, geometry: geometry)
            return (.move(to: mapped.screenPoint, via: via, durationMs: durationMs, profile: mapProfile(profile, geometry: geometry)), mapped.alreadyVisible ? nil : mapped.scrollDelta)
        case .click(let at, let button, let holdMs, let count, let profile):
            let mapped = map(point: at, coordinateSpace: geometry.coordSpace, geometry: geometry)
            return (.click(at: mapped.screenPoint, button: button, holdMs: holdMs, count: count, profile: mapProfile(profile, geometry: geometry)), mapped.alreadyVisible ? nil : mapped.scrollDelta)
        case .drag(let from, let to, let button, let via, let profile):
            let mappedFrom = map(point: from, coordinateSpace: geometry.coordSpace, geometry: geometry)
            let mappedTo = map(point: to, coordinateSpace: geometry.coordSpace, geometry: geometry)
            return (.drag(from: mappedFrom.screenPoint, to: mappedTo.screenPoint, button: button, via: via, profile: mapProfile(profile, geometry: geometry)), mappedTo.alreadyVisible ? nil : mappedTo.scrollDelta)
        case .scroll(let at, let dx, let dy, let style):
            let mapped = map(point: at, coordinateSpace: geometry.coordSpace, geometry: geometry)
            return (.scroll(at: mapped.screenPoint, dx: dx, dy: dy, style: style), nil)
        case .type, .key:
            return (primitive, nil)
        }
    }

    private static func mapProfile(_ profile: PrimitiveProfile?, geometry: ViewportGeometry) -> PrimitiveProfile? {
        guard let profile else {
            return nil
        }
        return PrimitiveProfile(
            origin: profile.origin.map { map(point: $0, coordinateSpace: geometry.coordSpace, geometry: geometry).screenPoint },
            landingZone: mapLandingZone(profile.landingZone, geometry: geometry),
            motionProfile: profile.motionProfile
        )
    }

    private static func mapLandingZone(_ zone: LandingZone?, geometry: ViewportGeometry) -> LandingZone? {
        guard let zone else {
            return nil
        }
        let scale = max(geometry.pageScale, 0.01)
        return LandingZone(
            center: zone.center.map { map(point: $0, coordinateSpace: geometry.coordSpace, geometry: geometry).screenPoint },
            width: zone.width.map { $0 * scale },
            height: zone.height.map { $0 * scale },
            radius: zone.radius.map { $0 * scale }
        )
    }
}

public enum ExecutionPlanStep: Codable, Equatable {
    case activateTarget(TargetDescriptor)
    case scroll(dx: Double, dy: Double)
    case requireViewportResample
    case emit(String)
}

public struct ExecutionPlanV2: Codable, Equatable {
    public let target: TargetDescriptor?
    public let geometryApplied: Bool
    public let requiresViewportResample: Bool
    public let steps: [ExecutionPlanStep]

    public init(
        target: TargetDescriptor?,
        geometryApplied: Bool,
        requiresViewportResample: Bool = false,
        steps: [ExecutionPlanStep]
    ) {
        self.target = target
        self.geometryApplied = geometryApplied
        self.requiresViewportResample = requiresViewportResample
        self.steps = steps
    }
}

public enum ExecutionPlanner {
    public static func plan(
        target: TargetDescriptor?,
        geometry: ViewportGeometry?,
        primitives: [ActionPrimitive]
    ) -> (primitives: [ActionPrimitive], plan: ExecutionPlanV2) {
        var mapped = [ActionPrimitive]()
        var steps = [ExecutionPlanStep]()
        var requiresViewportResample = false
        if let target {
            steps.append(.activateTarget(target))
        }

        for primitive in primitives {
            let result = ViewportMapper.mapPrimitive(primitive, geometry: geometry)
            if let scroll = result.scrollDelta, scroll.dx != 0 || scroll.dy != 0 {
                steps.append(.scroll(dx: scroll.dx, dy: scroll.dy))
                steps.append(.requireViewportResample)
                requiresViewportResample = true
            }
            steps.append(.emit(actionName(for: result.primitive)))
            mapped.append(result.primitive)
        }

        return (
            mapped,
            ExecutionPlanV2(
                target: target,
                geometryApplied: geometry != nil && geometry?.coordSpace != .screen,
                requiresViewportResample: requiresViewportResample,
                steps: steps
            )
        )
    }

    private static func actionName(for primitive: ActionPrimitive) -> String {
        switch primitive {
        case .move: return "move"
        case .click: return "click"
        case .drag: return "drag"
        case .scroll: return "scroll"
        case .type: return "type"
        case .key: return "key"
        }
    }
}

public struct OutcomeEvidence: Codable, Equatable {
    public struct Layer: Codable, Equatable {
        public let status: String
        public let detail: String?

        public init(status: String, detail: String? = nil) {
            self.status = status
            self.detail = detail
        }
    }

    public struct Observer: Codable, Equatable {
        public let status: String
        public let observedEvents: Int
        public let matchedEvents: Int
        public let sinceEventId: String?
        public let detail: String?

        public init(status: String, observedEvents: Int, matchedEvents: Int, sinceEventId: String? = nil, detail: String? = nil) {
            self.status = status
            self.observedEvents = observedEvents
            self.matchedEvents = matchedEvents
            self.sinceEventId = sinceEventId
            self.detail = detail
        }
    }

    public struct Semantic: Codable, Equatable {
        public let status: String
        public let verified: Bool?
        public let source: String?
        public let detail: String?

        public init(status: String, verified: Bool? = nil, source: String? = nil, detail: String? = nil) {
            self.status = status
            self.verified = verified
            self.source = source
            self.detail = detail
        }

        public static func notProvided() -> Semantic {
            Semantic(status: "notProvided", verified: nil, source: nil, detail: "semantic success must be supplied by Agent/browser")
        }
    }

    public let injectedEvents: Int
    public let finalPointer: CodablePoint?
    public let expectedPointer: CodablePoint?
    public let pointerWithinTolerance: Bool?
    public let focusConfirmed: Bool?
    public let observerEcho: Bool?
    public let semanticVerifiedByAgent: Bool?
    public let injection: Layer
    public let pointer: Layer
    public let focus: Layer
    public let observer: Observer
    public let semantic: Semantic

    public init(
        injectedEvents: Int,
        finalPointer: CodablePoint?,
        expectedPointer: CodablePoint?,
        pointerWithinTolerance: Bool?,
        focusConfirmed: Bool?,
        observerEcho: Bool?,
        semanticVerifiedByAgent: Bool? = nil,
        observer: Observer = Observer(status: "notProvided", observedEvents: 0, matchedEvents: 0),
        semantic: Semantic = Semantic.notProvided()
    ) {
        self.injectedEvents = injectedEvents
        self.finalPointer = finalPointer
        self.expectedPointer = expectedPointer
        self.pointerWithinTolerance = pointerWithinTolerance
        self.focusConfirmed = focusConfirmed
        self.observerEcho = observerEcho
        self.semanticVerifiedByAgent = semanticVerifiedByAgent
        self.injection = Layer(
            status: injectedEvents > 0 ? "emitted" : "noEvents",
            detail: injectedEvents > 0 ? nil : "action produced no injectable events"
        )
        self.pointer = Layer(
            status: pointerWithinTolerance.map { $0 ? "withinTolerance" : "outsideTolerance" } ?? "notApplicable",
            detail: pointerWithinTolerance == nil ? "no pointer-bearing final event" : nil
        )
        self.focus = Layer(
            status: focusConfirmed.map { $0 ? "confirmed" : "notConfirmed" } ?? "unknown",
            detail: focusConfirmed == nil ? "focus was not checked" : nil
        )
        self.observer = observer
        self.semantic = semantic
    }
}

public enum OutcomeVerifier {
    public static func evidence(
        result: ActionResult,
        expectedFinalPoint: CGPoint?,
        focusConfirmed: Bool?,
        observerEcho: Bool?,
        observer: OutcomeEvidence.Observer = OutcomeEvidence.Observer(status: "notProvided", observedEvents: 0, matchedEvents: 0),
        semantic: OutcomeEvidence.Semantic = OutcomeEvidence.Semantic.notProvided(),
        tolerancePx: Double = 2
    ) -> OutcomeEvidence {
        let final = result.events.reversed().compactMap(\.location).first
        let expected = expectedFinalPoint.map { CodablePoint(x: $0.x, y: $0.y) }
        let within: Bool?
        if let final, let expected {
            within = hypot(final.x - expected.x, final.y - expected.y) <= tolerancePx
        } else {
            within = nil
        }
        return OutcomeEvidence(
            injectedEvents: result.events.count,
            finalPointer: final,
            expectedPointer: expected,
            pointerWithinTolerance: within,
            focusConfirmed: focusConfirmed,
            observerEcho: observerEcho,
            semanticVerifiedByAgent: semantic.verified,
            observer: observer,
            semantic: semantic
        )
    }
}
