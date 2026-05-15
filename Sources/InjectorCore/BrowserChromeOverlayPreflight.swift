import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct BrowserChromeOverlayPolicy: Codable, Equatable {
    public let enabled: Bool
    public let mode: String
    public let dismissSafe: Bool
    public let minConfidence: Double

    public init(enabled: Bool = true, mode: String = "detectOnly", dismissSafe: Bool = false, minConfidence: Double = 0.65) {
        self.enabled = enabled
        self.mode = mode
        self.dismissSafe = dismissSafe
        self.minConfidence = minConfidence
    }
}

public struct BrowserChromeOverlayPreflight: Codable, Equatable {
    public let status: String
    public let overlayType: String?
    public let confidence: Double
    public let bounds: CodableRect?
    public let overlapsTarget: Bool
    public let action: String
    public let evidence: [String]

    public init(status: String, overlayType: String?, confidence: Double, bounds: CodableRect?, overlapsTarget: Bool, action: String, evidence: [String]) {
        self.status = status
        self.overlayType = overlayType
        self.confidence = confidence
        self.bounds = bounds
        self.overlapsTarget = overlapsTarget
        self.action = action
        self.evidence = evidence
    }

    public var blocksTargetAction: Bool {
        status == "blocked"
    }
}

public enum BrowserChromeOverlayDetector {
    public static func preflight(
        target: BrowserTarget,
        primitives: [ActionPrimitive],
        policy: BrowserChromeOverlayPolicy = BrowserChromeOverlayPolicy()
    ) -> BrowserChromeOverlayPreflight {
        guard policy.enabled else {
            return BrowserChromeOverlayPreflight(
                status: "disabled",
                overlayType: nil,
                confidence: 0,
                bounds: nil,
                overlapsTarget: false,
                action: "allow",
                evidence: ["policy.enabled=false"]
            )
        }
        guard isChromiumBrowser(bundleIdentifier: target.bundleIdentifier) else {
            return BrowserChromeOverlayPreflight(
                status: "notApplicable",
                overlayType: nil,
                confidence: 0,
                bounds: nil,
                overlapsTarget: false,
                action: "allow",
                evidence: ["bundleId=\(target.bundleIdentifier)"]
            )
        }
        guard let targetRect = targetActionRect(primitives: primitives) else {
            return BrowserChromeOverlayPreflight(
                status: "noTargetArea",
                overlayType: nil,
                confidence: 0,
                bounds: nil,
                overlapsTarget: false,
                action: "allow",
                evidence: ["no pointer target area in primitives"]
            )
        }

        let candidates = cgWindowCandidates(target: target, targetRect: targetRect)
            + axOverlayCandidates(target: target, targetRect: targetRect)
        guard let best = candidates.max(by: { $0.confidence < $1.confidence }) else {
            return BrowserChromeOverlayPreflight(
                status: "clear",
                overlayType: nil,
                confidence: 0,
                bounds: nil,
                overlapsTarget: false,
                action: "allow",
                evidence: ["targetArea=\(describe(targetRect))", "no overlapping Chrome shell overlay detected"]
            )
        }

        let blocked = best.confidence >= policy.minConfidence
        return BrowserChromeOverlayPreflight(
            status: blocked ? "blocked" : "clear",
            overlayType: best.overlayType,
            confidence: best.confidence,
            bounds: best.bounds.codable,
            overlapsTarget: true,
            action: blocked ? "blockTargetAction" : "allow",
            evidence: best.evidence + ["targetArea=\(describe(targetRect))", "policy.mode=\(policy.mode)", "policy.dismissSafe=\(policy.dismissSafe)"]
        )
    }

    private struct Candidate {
        let overlayType: String
        let confidence: Double
        let bounds: CGRect
        let evidence: [String]
    }

    private static func isChromiumBrowser(bundleIdentifier: String) -> Bool {
        [
            "com.google.Chrome",
            "com.google.Chrome.beta",
            "com.google.Chrome.canary",
            "org.chromium.Chromium",
            "com.microsoft.edgemac",
            "com.brave.Browser"
        ].contains(bundleIdentifier)
    }

    private static func targetActionRect(primitives: [ActionPrimitive]) -> CGRect? {
        var rects = [CGRect]()
        for primitive in primitives {
            switch primitive {
            case .move(let to, _, _, let profile):
                rects.append(rect(around: expectedLandingCenter(base: to, profile: profile), profile: profile))
            case .click(let at, _, _, _, let profile):
                rects.append(rect(around: expectedLandingCenter(base: at, profile: profile), profile: profile))
            case .drag(let from, let to, _, _, let profile):
                rects.append(rect(around: from, profile: nil).union(rect(around: expectedLandingCenter(base: to, profile: profile), profile: profile)))
            case .scroll(let at, _, _, _):
                rects.append(rect(around: at, radius: 8))
            case .type, .pasteText, .key:
                continue
            }
        }
        return rects.reduce(nil) { partial, rect in
            partial.map { $0.union(rect) } ?? rect
        }
    }

    private static func rect(around point: CGPoint, profile: PrimitiveProfile?, radius: CGFloat = 3) -> CGRect {
        if let zone = profile?.landingZone {
            let center = zone.center ?? point
            if let zoneRadius = zone.radius, zoneRadius > 0 {
                return rect(around: center, radius: CGFloat(zoneRadius))
            }
            if let width = zone.width, let height = zone.height, width > 0, height > 0 {
                let cgWidth = CGFloat(width)
                let cgHeight = CGFloat(height)
                return CGRect(x: center.x - cgWidth / 2, y: center.y - cgHeight / 2, width: cgWidth, height: cgHeight)
            }
            return rect(around: center, radius: radius)
        }
        return rect(around: point, radius: radius)
    }

    private static func rect(around point: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }

    private static func expectedLandingCenter(base: CGPoint, profile: PrimitiveProfile?) -> CGPoint {
        profile?.landingZone?.center ?? base
    }

    private static func cgWindowCandidates(target: BrowserTarget, targetRect: CGRect) -> [Candidate] {
        guard
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return []
        }

        var candidates = [Candidate]()
        for window in windowList {
            guard let ownerPid = window[kCGWindowOwnerPID as String] as? pid_t, ownerPid == target.pid else {
                continue
            }
            let alpha = (window[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0.01 else {
                continue
            }
            guard let boundsValue = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsValue as CFDictionary),
                  bounds.width > 8,
                  bounds.height > 8,
                  bounds.intersects(targetRect)
            else {
                continue
            }

            let windowId = window[kCGWindowNumber as String] as? Int
            if let windowId, windowId == target.windowId {
                continue
            }
            if isMainBrowserWindow(bounds, targetFrame: target.frame) {
                continue
            }

            let layer = (window[kCGWindowLayer as String] as? Int) ?? 0
            let name = window[kCGWindowName as String] as? String
            let overlayType = classifyCGWindow(name: name, bounds: bounds, targetFrame: target.frame)
            let confidence = min(0.95, (layer == 0 ? 0.72 : 0.82) + (overlayType == "chromePopup" ? 0.08 : 0))
            candidates.append(
                Candidate(
                    overlayType: overlayType,
                    confidence: confidence,
                    bounds: bounds,
                    evidence: [
                        "source=CGWindowList",
                        "windowId=\(windowId.map(String.init) ?? "unknown")",
                        "layer=\(layer)",
                        "name=\(name ?? "")",
                        "bounds=\(describe(bounds))"
                    ]
                )
            )
        }
        return candidates
    }

    private static func axOverlayCandidates(target: BrowserTarget, targetRect: CGRect) -> [Candidate] {
        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.12)
        guard let windows = copyAttribute(appElement, name: kAXWindowsAttribute) as? [AXUIElement] else {
            return []
        }

        var candidates = [Candidate]()
        for window in windows.prefix(12) {
            AXUIElementSetMessagingTimeout(window, 0.12)
            scanAX(element: window, depth: 0, maxDepth: 1, target: target, targetRect: targetRect, candidates: &candidates)
        }
        return candidates
    }

    private static func scanAX(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        target: BrowserTarget,
        targetRect: CGRect,
        candidates: inout [Candidate]
    ) {
        guard let role = copyStringAttribute(element, name: kAXRoleAttribute) else {
            return
        }
        let subrole = copyStringAttribute(element, name: kAXSubroleAttribute)
        let title = copyStringAttribute(element, name: kAXTitleAttribute)
        if let frame = copyFrame(of: element),
           frame.width > 8,
           frame.height > 8,
           frame.intersects(targetRect),
           isShellOverlayRole(role: role, subrole: subrole, depth: depth, frame: frame, targetFrame: target.frame),
           !isMainBrowserWindow(frame, targetFrame: target.frame) {
            let confidence = confidenceForAX(role: role, subrole: subrole, frame: frame, targetFrame: target.frame)
            candidates.append(
                Candidate(
                    overlayType: overlayTypeForAX(role: role, subrole: subrole),
                    confidence: confidence,
                    bounds: frame,
                    evidence: [
                        "source=AX",
                        "depth=\(depth)",
                        "role=\(role)",
                        "subrole=\(subrole ?? "")",
                        "title=\(title ?? "")",
                        "bounds=\(describe(frame))"
                    ]
                )
            )
        }

        guard depth < maxDepth,
              shouldDescendIntoAXChildren(role: role),
              let children = copyAttribute(element, name: kAXChildrenAttribute) as? [AXUIElement]
        else {
            return
        }
        for child in children.prefix(48) {
            scanAX(element: child, depth: depth + 1, maxDepth: maxDepth, target: target, targetRect: targetRect, candidates: &candidates)
        }
    }

    private static func isShellOverlayRole(role: String, subrole: String?, depth: Int, frame: CGRect, targetFrame: CGRect) -> Bool {
        let areaRatio = (frame.width * frame.height) / max(1, targetFrame.width * targetFrame.height)
        if role == "AXWindow", let subrole, ["AXDialog", "AXSystemDialog", "AXFloatingWindow"].contains(subrole) {
            return true
        }
        guard depth <= 1, areaRatio < 0.85 else {
            return false
        }
        if ["AXPopover", "AXMenu", "AXMenuBar", "AXDialog", "AXSheet"].contains(role) {
            return true
        }
        return false
    }

    private static func shouldDescendIntoAXChildren(role: String) -> Bool {
        !["AXWebArea", "AXScrollArea", "AXTextArea", "AXTable", "AXOutline"].contains(role)
    }

    private static func overlayTypeForAX(role: String, subrole: String?) -> String {
        if role == "AXMenu" || role == "AXMenuBar" || role == "AXMenuItem" {
            return "chromeMenu"
        }
        if role == "AXPopover" || subrole?.lowercased().contains("popup") == true {
            return "chromePopup"
        }
        if role == "AXSheet" || role == "AXDialog" || subrole?.lowercased().contains("dialog") == true {
            return "chromeDialog"
        }
        return "chromeOverlay"
    }

    private static func confidenceForAX(role: String, subrole: String?, frame: CGRect, targetFrame: CGRect) -> Double {
        let base: Double
        switch overlayTypeForAX(role: role, subrole: subrole) {
        case "chromeDialog":
            base = 0.92
        case "chromePopup", "chromeMenu":
            base = 0.86
        default:
            base = 0.74
        }
        let areaRatio = (frame.width * frame.height) / max(1, targetFrame.width * targetFrame.height)
        return min(0.97, areaRatio < 0.70 ? base : base - 0.10)
    }

    private static func classifyCGWindow(name: String?, bounds: CGRect, targetFrame: CGRect) -> String {
        let lower = (name ?? "").lowercased()
        if lower.contains("menu") {
            return "chromeMenu"
        }
        if lower.contains("dialog") || lower.contains("sheet") {
            return "chromeDialog"
        }
        let areaRatio = (bounds.width * bounds.height) / max(1, targetFrame.width * targetFrame.height)
        return areaRatio < 0.70 ? "chromePopup" : "chromeOverlay"
    }

    private static func isMainBrowserWindow(_ rect: CGRect, targetFrame: CGRect) -> Bool {
        abs(rect.minX - targetFrame.minX) <= 3
            && abs(rect.minY - targetFrame.minY) <= 3
            && abs(rect.width - targetFrame.width) <= 6
            && abs(rect.height - targetFrame.height) <= 6
    }

    private static func copyAttribute(_ element: AXUIElement, name: String) -> Any? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard status == .success else {
            return nil
        }
        return value
    }

    private static func copyStringAttribute(_ element: AXUIElement, name: String) -> String? {
        copyAttribute(element, name: name) as? String
    }

    private static func copyFrame(of element: AXUIElement) -> CGRect? {
        guard
            let positionObject = copyAttribute(element, name: kAXPositionAttribute),
            let sizeObject = copyAttribute(element, name: kAXSizeAttribute)
        else {
            return nil
        }
        let positionValue = positionObject as! AXValue
        let sizeValue = sizeObject as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func describe(_ rect: CGRect) -> String {
        "x=\(Int(rect.origin.x.rounded())),y=\(Int(rect.origin.y.rounded())),w=\(Int(rect.width.rounded())),h=\(Int(rect.height.rounded()))"
    }
}

private extension CGRect {
    var codable: CodableRect {
        CodableRect(x: origin.x, y: origin.y, width: width, height: height)
    }
}
