import Foundation

public struct HIDActionVisualContext: Equatable {
    public let actionId: String
    public let source: String
    public let bundleIdentifier: String
    public let pid: Int32
    public let windowTitle: String?
    public let windowFrame: CodableRect
    public let dryRun: Bool
    public let postMode: String
    public let actionTypes: [String]

    public init(
        actionId: String,
        source: String = "hid",
        bundleIdentifier: String,
        pid: Int32,
        windowTitle: String?,
        windowFrame: CodableRect,
        dryRun: Bool,
        postMode: String,
        actionTypes: [String]
    ) {
        self.actionId = actionId
        self.source = source
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.windowTitle = windowTitle
        self.windowFrame = windowFrame
        self.dryRun = dryRun
        self.postMode = postMode
        self.actionTypes = actionTypes
    }
}

public struct HIDActionVisualSummary: Equatable {
    public let context: HIDActionVisualContext
    public let events: [InjectedEvent]
    public let verification: OutcomeEvidence

    public init(context: HIDActionVisualContext, events: [InjectedEvent], verification: OutcomeEvidence) {
        self.context = context
        self.events = events
        self.verification = verification
    }
}

public protocol HIDEventSink: AnyObject {
    func hidActionDidStart(_ context: HIDActionVisualContext)
    func hidActionDidRecord(_ event: InjectedEvent, context: HIDActionVisualContext)
    func hidActionDidFinish(_ summary: HIDActionVisualSummary)
    func hidActionDidFail(actionId: String, errorCode: String)
}

public protocol HIDVisualizationControl: AnyObject {
    func hidVisualizationState() -> [String: Any]
    func hidVisualizationConfigure(_ params: [String: Any]) -> [String: Any]
}

public extension HIDEventSink {
    func hidActionDidStart(_ context: HIDActionVisualContext) {}
    func hidActionDidRecord(_ event: InjectedEvent, context: HIDActionVisualContext) {}
    func hidActionDidFinish(_ summary: HIDActionVisualSummary) {}
    func hidActionDidFail(actionId: String, errorCode: String) {}
}
