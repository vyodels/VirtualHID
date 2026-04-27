import Foundation
import HumanizationKit
import SQLite3
import os

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum ProfileStoreError: Error, LocalizedError {
    case openFailed(String)
    case sqlite(String)
    case notFound
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "SQLite open failed: \(message)"
        case .sqlite(let message):
            return "SQLite error: \(message)"
        case .notFound:
            return "profile not found"
        case .invalidInput(let message):
            return message
        }
    }
}

public struct TracePoint: Codable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct TraceScrollDelta: Codable, Equatable {
    public let dx: Double
    public let dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

public struct RawHIDLearningProfile: Codable, Equatable {
    public let scrollDeltaX: DoubleRange?
    public let scrollDeltaY: DoubleRange?
    public let scrollIntervalsMs: IntRange?
    public let scrollEventCount: IntRange?
    public let doubleClickIntervalMs: IntRange?
    public let dwellMs: IntRange?
    public let interKeyMs: IntRange?
    public let repeatCount: IntRange?
    public let modifierFlags: [UInt64]
    public let flagsChangedKeyCodes: [UInt16]
    public let comboKeyCodes: [[UInt16]]
    public let pathSkeleton: [TracePoint]
    public let segmentMs: [Double]
    public let eventTimeline: [String]

    public init(
        scrollDeltaX: DoubleRange? = nil,
        scrollDeltaY: DoubleRange? = nil,
        scrollIntervalsMs: IntRange? = nil,
        scrollEventCount: IntRange? = nil,
        doubleClickIntervalMs: IntRange? = nil,
        dwellMs: IntRange? = nil,
        interKeyMs: IntRange? = nil,
        repeatCount: IntRange? = nil,
        modifierFlags: [UInt64] = [],
        flagsChangedKeyCodes: [UInt16] = [],
        comboKeyCodes: [[UInt16]] = [],
        pathSkeleton: [TracePoint] = [],
        segmentMs: [Double] = [],
        eventTimeline: [String] = []
    ) {
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.scrollIntervalsMs = scrollIntervalsMs
        self.scrollEventCount = scrollEventCount
        self.doubleClickIntervalMs = doubleClickIntervalMs
        self.dwellMs = dwellMs
        self.interKeyMs = interKeyMs
        self.repeatCount = repeatCount
        self.modifierFlags = modifierFlags
        self.flagsChangedKeyCodes = flagsChangedKeyCodes
        self.comboKeyCodes = comboKeyCodes
        self.pathSkeleton = pathSkeleton
        self.segmentMs = segmentMs
        self.eventTimeline = eventTimeline
    }
}

public struct TraceRetentionPolicy: Equatable {
    public let maxAgeMs: Int64
    public let maxTracesPerGroup: Int
    public let cleanupIntervalMs: Int64

    public init(
        maxAgeMs: Int64 = 30 * 24 * 60 * 60 * 1000,
        maxTracesPerGroup: Int = 600,
        cleanupIntervalMs: Int64 = 6 * 60 * 60 * 1000
    ) {
        self.maxAgeMs = maxAgeMs
        self.maxTracesPerGroup = maxTracesPerGroup
        self.cleanupIntervalMs = cleanupIntervalMs
    }
}

public struct TracePayload: Codable, Equatable {
    public let eventId: String?
    public let type: String
    public let point: TracePoint?
    public let keyCode: UInt16?
    public let points: [TracePoint]
    public let origin: TracePoint?
    public let targetPoint: TracePoint?
    public let targetRadiusPx: Double?
    public let landingErrorPx: Double?
    public let durationMs: Double?
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
    public let straightness: Double?
    public let turnJitter: Double?
    public let pathLengthPx: Double?
    public let speedPxS: Double?

    public init(
        eventId: String?,
        type: String,
        point: TracePoint? = nil,
        keyCode: UInt16? = nil,
        points: [TracePoint] = [],
        origin: TracePoint? = nil,
        targetPoint: TracePoint? = nil,
        targetRadiusPx: Double? = nil,
        landingErrorPx: Double? = nil,
        durationMs: Double? = nil,
        segmentMs: [Double] = [],
        hesitationMs: [Double] = [],
        clickHoldMs: [Double] = [],
        interClickMs: [Double] = [],
        dwellMs: [Double] = [],
        interKeyMs: [Double] = [],
        scrollDeltas: [TraceScrollDelta] = [],
        scrollIntervalsMs: [Double] = [],
        doubleClickIntervalMs: [Double] = [],
        modifierFlags: [UInt64] = [],
        flagsChangedKeyCodes: [UInt16] = [],
        comboKeyCodes: [UInt16] = [],
        repeatCount: Int = 0,
        eventTimeline: [String] = [],
        behaviorMode: HumanBehaviorMode? = nil,
        flavor: MotionFlavor? = nil,
        straightness: Double? = nil,
        turnJitter: Double? = nil,
        pathLengthPx: Double? = nil,
        speedPxS: Double? = nil
    ) {
        self.eventId = eventId
        self.type = type
        self.point = point
        self.keyCode = keyCode
        self.points = points
        self.origin = origin
        self.targetPoint = targetPoint
        self.targetRadiusPx = targetRadiusPx
        self.landingErrorPx = landingErrorPx
        self.durationMs = durationMs
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
        self.straightness = straightness
        self.turnJitter = turnJitter
        self.pathLengthPx = pathLengthPx
        self.speedPxS = speedPxS
    }

    private enum CodingKeys: String, CodingKey {
        case eventId
        case type
        case point
        case keyCode
        case points
        case origin
        case targetPoint
        case targetRadiusPx
        case landingErrorPx
        case durationMs
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
        case straightness
        case turnJitter
        case pathLengthPx
        case speedPxS
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try container.decodeIfPresent(String.self, forKey: .eventId)
        type = try container.decode(String.self, forKey: .type)
        point = try container.decodeIfPresent(TracePoint.self, forKey: .point)
        keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        points = try container.decodeIfPresent([TracePoint].self, forKey: .points) ?? []
        origin = try container.decodeIfPresent(TracePoint.self, forKey: .origin)
        targetPoint = try container.decodeIfPresent(TracePoint.self, forKey: .targetPoint)
        targetRadiusPx = try container.decodeIfPresent(Double.self, forKey: .targetRadiusPx)
        landingErrorPx = try container.decodeIfPresent(Double.self, forKey: .landingErrorPx)
        durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
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
        straightness = try container.decodeIfPresent(Double.self, forKey: .straightness)
        turnJitter = try container.decodeIfPresent(Double.self, forKey: .turnJitter)
        pathLengthPx = try container.decodeIfPresent(Double.self, forKey: .pathLengthPx)
        speedPxS = try container.decodeIfPresent(Double.self, forKey: .speedPxS)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(eventId, forKey: .eventId)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(point, forKey: .point)
        try container.encodeIfPresent(keyCode, forKey: .keyCode)
        try container.encode(points, forKey: .points)
        try container.encodeIfPresent(origin, forKey: .origin)
        try container.encodeIfPresent(targetPoint, forKey: .targetPoint)
        try container.encodeIfPresent(targetRadiusPx, forKey: .targetRadiusPx)
        try container.encodeIfPresent(landingErrorPx, forKey: .landingErrorPx)
        try container.encodeIfPresent(durationMs, forKey: .durationMs)
        try container.encode(segmentMs, forKey: .segmentMs)
        try container.encode(hesitationMs, forKey: .hesitationMs)
        try container.encode(clickHoldMs, forKey: .clickHoldMs)
        try container.encode(interClickMs, forKey: .interClickMs)
        try container.encode(dwellMs, forKey: .dwellMs)
        try container.encode(interKeyMs, forKey: .interKeyMs)
        try container.encode(scrollDeltas, forKey: .scrollDeltas)
        try container.encode(scrollIntervalsMs, forKey: .scrollIntervalsMs)
        try container.encode(doubleClickIntervalMs, forKey: .doubleClickIntervalMs)
        try container.encode(modifierFlags, forKey: .modifierFlags)
        try container.encode(flagsChangedKeyCodes, forKey: .flagsChangedKeyCodes)
        try container.encode(comboKeyCodes, forKey: .comboKeyCodes)
        try container.encode(repeatCount, forKey: .repeatCount)
        try container.encode(eventTimeline, forKey: .eventTimeline)
        try container.encodeIfPresent(behaviorMode, forKey: .behaviorMode)
        try container.encodeIfPresent(flavor, forKey: .flavor)
        try container.encodeIfPresent(straightness, forKey: .straightness)
        try container.encodeIfPresent(turnJitter, forKey: .turnJitter)
        try container.encodeIfPresent(pathLengthPx, forKey: .pathLengthPx)
        try container.encodeIfPresent(speedPxS, forKey: .speedPxS)
    }
}

public struct TraceInput: Equatable {
    public let ts: Int64
    public let source: String
    public let host: String
    public let elementSig: String?
    public let taskId: String?
    public let stage: String?
    public let actionType: String
    public let payload: TracePayload

    public init(
        ts: Int64,
        source: String,
        host: String,
        elementSig: String?,
        taskId: String?,
        stage: String?,
        actionType: String,
        payload: TracePayload
    ) {
        self.ts = ts
        self.source = source
        self.host = host
        self.elementSig = elementSig
        self.taskId = taskId
        self.stage = stage
        self.actionType = actionType
        self.payload = payload
    }
}

public struct TraceSummary: Codable, Equatable {
    public let id: Int64
    public let ts: Int64
    public let source: String
    public let host: String
    public let elementSig: String?
    public let taskId: String?
    public let stage: String?
    public let actionType: String
    public let eventType: String
    public let pointCount: Int
    public let durationMs: Double?
    public let clickHoldMs: [Double]
    public let interClickMs: [Double]
    public let dwellMs: [Double]
    public let interKeyMs: [Double]
    public let pathLengthPx: Double?
    public let speedPxS: Double?
    public let straightness: Double?
    public let turnJitter: Double?

    public init(
        id: Int64,
        ts: Int64,
        source: String,
        host: String,
        elementSig: String?,
        taskId: String?,
        stage: String?,
        actionType: String,
        eventType: String,
        pointCount: Int,
        durationMs: Double?,
        clickHoldMs: [Double],
        interClickMs: [Double],
        dwellMs: [Double] = [],
        interKeyMs: [Double] = [],
        pathLengthPx: Double?,
        speedPxS: Double?,
        straightness: Double?,
        turnJitter: Double?
    ) {
        self.id = id
        self.ts = ts
        self.source = source
        self.host = host
        self.elementSig = elementSig
        self.taskId = taskId
        self.stage = stage
        self.actionType = actionType
        self.eventType = eventType
        self.pointCount = pointCount
        self.durationMs = durationMs
        self.clickHoldMs = clickHoldMs
        self.interClickMs = interClickMs
        self.dwellMs = dwellMs
        self.interKeyMs = interKeyMs
        self.pathLengthPx = pathLengthPx
        self.speedPxS = speedPxS
        self.straightness = straightness
        self.turnJitter = turnJitter
    }
}

public struct TraceCommitResult: Codable, Equatable {
    public let committed: Bool
    public let dropped: Bool
    public let traceId: Int64?
    public let reason: String?

    public init(committed: Bool, dropped: Bool, traceId: Int64?, reason: String?) {
        self.committed = committed
        self.dropped = dropped
        self.traceId = traceId
        self.reason = reason
    }
}

public struct ReplayCommitResult: Codable, Equatable {
    public let traceId: Int64
    public let replayId: Int64
    public let fingerprint: ReplayTraceFingerprint

    public init(traceId: Int64, replayId: Int64, fingerprint: ReplayTraceFingerprint) {
        self.traceId = traceId
        self.replayId = replayId
        self.fingerprint = fingerprint
    }
}

public struct ProfileTemplate: Codable, Equatable {
    public let host: String
    public let elementSig: String
    public let taskId: String?
    public let actionType: String
    public let sampleSize: Int
    public let confidence: Double
    public let paramsJSON: String
    public let updatedAt: Int64

    public init(
        host: String,
        elementSig: String,
        taskId: String?,
        actionType: String,
        sampleSize: Int,
        confidence: Double,
        paramsJSON: String,
        updatedAt: Int64
    ) {
        self.host = host
        self.elementSig = elementSig
        self.taskId = taskId
        self.actionType = actionType
        self.sampleSize = sampleSize
        self.confidence = confidence
        self.paramsJSON = paramsJSON
        self.updatedAt = updatedAt
    }
}

public struct AggregateReport: Codable, Equatable {
    public let scannedTraces: Int
    public let generatedTemplates: Int
    public let updatedTemplates: Int

    public init(scannedTraces: Int, generatedTemplates: Int, updatedTemplates: Int) {
        self.scannedTraces = scannedTraces
        self.generatedTemplates = generatedTemplates
        self.updatedTemplates = updatedTemplates
    }
}

public actor Aggregator {
    private let store: ProfileStore

    public init(store: ProfileStore) {
        self.store = store
    }

    public func rebuild(for host: String? = nil) async throws -> AggregateReport {
        try store.rebuild(host: host)
    }
}

public final class ProfileStore {
    public static let globalLearningHost = "__global__"

    private let lock = NSLock()
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let templateEncoder = JSONEncoder()
    private let logger = Logger(subsystem: "com.vyodels.virtualhid", category: "profile-store")
    private let retentionPolicy: TraceRetentionPolicy
    private var lastCleanupAtMs: Int64

    public init(path: String, retentionPolicy: TraceRetentionPolicy = TraceRetentionPolicy()) throws {
        self.retentionPolicy = retentionPolicy
        lastCleanupAtMs = 0
        templateEncoder.outputFormatting = [.sortedKeys]

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &database, flags, nil) != SQLITE_OK {
            let message = database.flatMap { sqlite3_errmsg($0).map { String(cString: $0) } } ?? "unknown"
            sqlite3_close(database)
            throw ProfileStoreError.openFailed(message)
        }
        db = database
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    public func insertTrace(_ input: TraceInput) throws -> Int64 {
        guard !input.host.isEmpty else {
            throw ProfileStoreError.invalidInput("host is required")
        }
        guard !input.actionType.isEmpty else {
            throw ProfileStoreError.invalidInput("action_type is required")
        }

        let payload = String(data: try encoder.encode(input.payload), encoding: .utf8) ?? "{}"
        return try lock.withLock { [self] in
            let sql = """
            INSERT INTO traces (ts, source, host, element_sig, task_id, stage, action_type, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, input.ts)
            bindText(input.source, to: statement, at: 2)
            bindText(input.host, to: statement, at: 3)
            bindNullableText(input.elementSig, to: statement, at: 4)
            bindNullableText(input.taskId, to: statement, at: 5)
            bindNullableText(input.stage, to: statement, at: 6)
            bindText(input.actionType, to: statement, at: 7)
            bindText(payload, to: statement, at: 8)

            try stepDone(statement)
            let traceId = sqlite3_last_insert_rowid(self.db)
            try self.performRetentionIfNeeded(nowMs: self.currentTimeMs())
            return traceId
        }
    }

    public func commitObservedEvent(
        eventId: String,
        eventType: String,
        ts: Int64,
        point: TracePoint?,
        keyCode: UInt16?,
        elementSig: String,
        role: String?,
        host: String,
        taskId: String?,
        stage: String?,
        actionTypeOverride: String? = nil,
        payloadOverride: TracePayload? = nil
    ) throws -> TraceCommitResult {
        guard !host.isEmpty else {
            throw ProfileStoreError.invalidInput("host is required")
        }
        guard !elementSig.isEmpty || host == Self.globalLearningHost else {
            throw ProfileStoreError.invalidInput("element_sig is required")
        }

        if Self.isSensitiveRole(role) {
            logger.notice("Dropped sensitive trace")
            return TraceCommitResult(committed: false, dropped: true, traceId: nil, reason: "sensitive_role")
        }

        let payload = payloadOverride ?? TracePayload(
            eventId: eventId,
            type: eventType,
            point: point,
            keyCode: keyCode,
            points: point.map { [$0] } ?? []
        )
        let actionType = actionTypeOverride ?? Self.actionType(forObservedType: eventType)
        let traceId = try insertTrace(
            TraceInput(
                ts: ts,
                source: "user",
                host: host,
                elementSig: elementSig,
                taskId: taskId,
                stage: stage,
                actionType: actionType,
                payload: payload
            )
        )
        return TraceCommitResult(committed: true, dropped: false, traceId: traceId, reason: nil)
    }

    public func commitReplayTrace(input: TraceInput, instructionKey: String) throws -> ReplayCommitResult {
        if Self.isSensitiveRole(input.payload.type) {
            throw ProfileStoreError.invalidInput("sensitive replay trace is not allowed")
        }
        let traceId = try insertTrace(input)
        let fingerprint = ReplayTraceStore.fingerprint(input: input, instructionKey: instructionKey)
        let replayId = try insertReplayFingerprint(fingerprint)
        return ReplayCommitResult(traceId: traceId, replayId: replayId, fingerprint: fingerprint)
    }

    public func insertReplayFingerprint(_ fingerprint: ReplayTraceFingerprint) throws -> Int64 {
        let payload = String(data: try encoder.encode(fingerprint), encoding: .utf8) ?? "{}"
        return try lock.withLock { [self] in
            let sql = """
            INSERT INTO replay_fingerprints
              (ts, source, host, task_id, stage, instruction_key, action_type, quality, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, fingerprint.ts)
            bindText(fingerprint.source, to: statement, at: 2)
            bindText(fingerprint.key.host, to: statement, at: 3)
            bindNullableText(fingerprint.key.taskId, to: statement, at: 4)
            bindNullableText(fingerprint.key.stage, to: statement, at: 5)
            bindText(fingerprint.key.instructionKey, to: statement, at: 6)
            bindText(fingerprint.key.actionType, to: statement, at: 7)
            sqlite3_bind_double(statement, 8, fingerprint.quality)
            bindText(payload, to: statement, at: 9)

            try stepDone(statement)
            let replayId = sqlite3_last_insert_rowid(self.db)
            try trimReplayFingerprints(nowMs: fingerprint.ts)
            return replayId
        }
    }

    public func listReplayFingerprints(host: String? = nil, instructionKey: String? = nil) throws -> [ReplayTraceFingerprint] {
        try lock.withLock { [self] in
            var clauses = [String]()
            var bindings = [String]()
            if let host {
                clauses.append("host = ?")
                bindings.append(host)
            }
            if let instructionKey {
                clauses.append("instruction_key = ?")
                bindings.append(instructionKey)
            }
            let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let statement = try prepare("""
            SELECT payload
            FROM replay_fingerprints
            \(whereClause)
            ORDER BY ts ASC, id ASC
            """)
            defer { sqlite3_finalize(statement) }
            bind(bindings, to: statement)

            var fingerprints = [ReplayTraceFingerprint]()
            while sqlite3_step(statement) == SQLITE_ROW {
                let payload = columnString(statement, 0)
                guard let data = payload.data(using: .utf8),
                      let fingerprint = try? decoder.decode(ReplayTraceFingerprint.self, from: data) else {
                    continue
                }
                fingerprints.append(fingerprint)
            }
            return fingerprints
        }
    }

    public func replaySummary(key: ReplayTraceKey) throws -> ReplayTraceSummary? {
        let fingerprints = try listReplayFingerprints(host: key.host, instructionKey: key.instructionKey)
            .filter { $0.key == key }
        guard !fingerprints.isEmpty else {
            return nil
        }
        let store = ReplayTraceStore()
        for fingerprint in fingerprints {
            store.commit(fingerprint)
        }
        return store.summarize(key: key)
    }

    public func applyTemplate(
        host: String,
        elementSig: String,
        taskId: String?,
        actionType: String,
        sampleSize: Int,
        confidence: Double,
        paramsJSON: String
    ) throws -> ProfileTemplate {
        guard !host.isEmpty else {
            throw ProfileStoreError.invalidInput("host is required")
        }
        guard !elementSig.isEmpty || host == Self.globalLearningHost else {
            throw ProfileStoreError.invalidInput("element_sig is required")
        }
        guard !actionType.isEmpty else {
            throw ProfileStoreError.invalidInput("action_type is required")
        }
        guard let data = paramsJSON.data(using: .utf8),
              (try? decoder.decode(LearnedMotionTemplate.self, from: data)) != nil else {
            throw ProfileStoreError.invalidInput("params must be a LearnedMotionTemplate JSON object")
        }
        let template = ProfileTemplate(
            host: host,
            elementSig: elementSig,
            taskId: taskId,
            actionType: actionType,
            sampleSize: max(1, sampleSize),
            confidence: clamp(confidence, min: 0, max: 1),
            paramsJSON: paramsJSON,
            updatedAt: currentTimeMs()
        )
        try lock.withLock {
            try upsertTemplate(template)
        }
        return template
    }

    public func rebuild(host: String? = nil) throws -> AggregateReport {
        try lock.withLock { [self] in
            try self.performRetentionIfNeeded(nowMs: self.currentTimeMs(), force: true)
            let scanned = try self.countTraces(host: host)
            try self.deleteTemplates(host: host, sig: nil)
            let groups = try self.loadGroups(host: host)
            var generated = 0

            for group in groups where group.sampleSize >= 5 {
                let params = try self.buildParams(for: group)
                try self.insertTemplate(group: group, paramsJSON: params)
                generated += 1
            }

            return AggregateReport(scannedTraces: scanned, generatedTemplates: generated, updatedTemplates: 0)
        }
    }

    public func listTemplates(host: String? = nil) throws -> [ProfileTemplate] {
        try lock.withLock {
            let sql: String
            if host == nil {
                sql = """
                SELECT host, element_sig, task_id, action_type, sample_size, confidence, params, updated_at
                FROM templates
                ORDER BY updated_at DESC
                """
            } else {
                sql = """
                SELECT host, element_sig, task_id, action_type, sample_size, confidence, params, updated_at
                FROM templates
                WHERE host = ?
                ORDER BY updated_at DESC
                """
            }
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            if let host {
                bindText(host, to: statement, at: 1)
            }

            var templates = [ProfileTemplate]()
            while sqlite3_step(statement) == SQLITE_ROW {
                templates.append(template(from: statement))
            }
            return templates
        }
    }

    public func getTemplate(host: String, sig: String) throws -> ProfileTemplate {
        try lock.withLock {
            let sql = """
            SELECT host, element_sig, task_id, action_type, sample_size, confidence, params, updated_at
            FROM templates
            WHERE host = ? AND element_sig = ?
            ORDER BY confidence DESC, updated_at DESC
            LIMIT 1
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bindText(host, to: statement, at: 1)
            bindText(sig, to: statement, at: 2)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw ProfileStoreError.notFound
            }
            return template(from: statement)
        }
    }

    public func lookupTemplate(host: String, sig: String, taskId: String?, actionType: String) throws -> ProfileTemplate {
        try lock.withLock {
            let candidates = [
                (host, sig, taskId ?? ""),
                (host, sig, ""),
                (host, "", ""),
                (Self.globalLearningHost, "", "")
            ]

            for (candidateHost, candidateSig, candidateTaskId) in candidates {
                let sql = """
                SELECT host, element_sig, task_id, action_type, sample_size, confidence, params, updated_at
                FROM templates
                WHERE host = ? AND element_sig = ? AND COALESCE(task_id, '') = ? AND action_type = ?
                ORDER BY confidence DESC, updated_at DESC
                LIMIT 1
                """
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                bindText(candidateHost, to: statement, at: 1)
                bindText(candidateSig, to: statement, at: 2)
                bindText(candidateTaskId, to: statement, at: 3)
                bindText(actionType, to: statement, at: 4)
                if sqlite3_step(statement) == SQLITE_ROW {
                    return template(from: statement)
                }
            }

            throw ProfileStoreError.notFound
        }
    }

    public func forget(host: String? = nil, sig: String? = nil) throws -> Int {
        try lock.withLock {
            try deleteTraces(host: host, sig: sig)
            try deleteTemplates(host: host, sig: sig)
            return Int(sqlite3_changes(db))
        }
    }

    public func totalTemplates() throws -> Int {
        try lock.withLock {
            try scalarInt("SELECT COUNT(*) FROM templates")
        }
    }

    public func traceCount(host: String? = nil) throws -> Int {
        try lock.withLock {
            try countTraces(host: host)
        }
    }

    public func listTraceSummaries(host: String? = nil, limit: Int = 20) throws -> [TraceSummary] {
        try lock.withLock { [self] in
            let safeLimit = max(1, min(limit, 100))
            let sql: String
            if host == nil {
                sql = """
                SELECT id, ts, source, host, element_sig, task_id, stage, action_type, payload
                FROM traces
                ORDER BY ts DESC, id DESC
                LIMIT ?
                """
            } else {
                sql = """
                SELECT id, ts, source, host, element_sig, task_id, stage, action_type, payload
                FROM traces
                WHERE host = ?
                ORDER BY ts DESC, id DESC
                LIMIT ?
                """
            }
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            if let host {
                bindText(host, to: statement, at: 1)
                sqlite3_bind_int(statement, 2, Int32(safeLimit))
            } else {
                sqlite3_bind_int(statement, 1, Int32(safeLimit))
            }

            var summaries = [TraceSummary]()
            while sqlite3_step(statement) == SQLITE_ROW {
                let payloadText = columnString(statement, 8)
                let payloadData = payloadText.data(using: .utf8)
                let payload = payloadData.flatMap { try? decoder.decode(TracePayload.self, from: $0) }
                summaries.append(
                    TraceSummary(
                        id: sqlite3_column_int64(statement, 0),
                        ts: sqlite3_column_int64(statement, 1),
                        source: columnString(statement, 2),
                        host: columnString(statement, 3),
                        elementSig: emptyToNil(columnString(statement, 4)),
                        taskId: emptyToNil(columnString(statement, 5)),
                        stage: emptyToNil(columnString(statement, 6)),
                        actionType: columnString(statement, 7),
                        eventType: payload?.type ?? columnString(statement, 7),
                        pointCount: payload?.points.count ?? 0,
                        durationMs: payload?.durationMs,
                        clickHoldMs: payload?.clickHoldMs ?? [],
                        interClickMs: payload?.interClickMs ?? [],
                        dwellMs: payload?.dwellMs ?? [],
                        interKeyMs: payload?.interKeyMs ?? [],
                        pathLengthPx: payload?.pathLengthPx,
                        speedPxS: payload?.speedPxS,
                        straightness: payload?.straightness,
                        turnJitter: payload?.turnJitter
                    )
                )
            }
            return summaries
        }
    }

    public func lastLearnedAtMs() throws -> Int64? {
        try lock.withLock {
            let statement = try prepare("SELECT MAX(updated_at) FROM templates")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else {
                return nil
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func migrate() throws {
        try lock.withLock {
            try execute("""
            CREATE TABLE IF NOT EXISTS traces (
              id          INTEGER PRIMARY KEY,
              ts          INTEGER NOT NULL,
              source      TEXT NOT NULL,
              host        TEXT NOT NULL,
              element_sig TEXT,
              task_id     TEXT,
              stage       TEXT,
              action_type TEXT NOT NULL,
              payload     TEXT NOT NULL
            )
            """)
            try execute("""
            CREATE TABLE IF NOT EXISTS templates (
              host          TEXT NOT NULL,
              element_sig   TEXT NOT NULL,
              task_id       TEXT,
              action_type   TEXT NOT NULL,
              sample_size   INTEGER NOT NULL,
              confidence    REAL NOT NULL,
              params        TEXT NOT NULL,
              updated_at    INTEGER NOT NULL,
              PRIMARY KEY (host, element_sig, task_id, action_type)
            )
            """)
            try execute("""
            CREATE TABLE IF NOT EXISTS replay_fingerprints (
              id              INTEGER PRIMARY KEY,
              ts              INTEGER NOT NULL,
              source          TEXT NOT NULL,
              host            TEXT NOT NULL,
              task_id         TEXT,
              stage           TEXT,
              instruction_key TEXT NOT NULL,
              action_type     TEXT NOT NULL,
              quality         REAL NOT NULL,
              payload         TEXT NOT NULL
            )
            """)
            try execute("CREATE INDEX IF NOT EXISTS idx_traces_host_sig ON traces(host, element_sig)")
            try execute("CREATE INDEX IF NOT EXISTS idx_traces_group_ts ON traces(host, COALESCE(element_sig, ''), COALESCE(task_id, ''), action_type, ts DESC, id DESC)")
            try execute("CREATE INDEX IF NOT EXISTS idx_replay_key_ts ON replay_fingerprints(host, COALESCE(task_id, ''), COALESCE(stage, ''), instruction_key, action_type, ts DESC, id DESC)")
        }
    }

    private func loadGroups(host: String?) throws -> [TemplateGroup] {
        let sql: String
        if host == nil {
            sql = """
            SELECT host, COALESCE(element_sig, ''), COALESCE(task_id, ''), action_type, COUNT(*)
            FROM traces
            GROUP BY host, COALESCE(element_sig, ''), COALESCE(task_id, ''), action_type
            """
        } else {
            sql = """
            SELECT host, COALESCE(element_sig, ''), COALESCE(task_id, ''), action_type, COUNT(*)
            FROM traces
            WHERE host = ?
            GROUP BY host, COALESCE(element_sig, ''), COALESCE(task_id, ''), action_type
            """
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let host {
            bindText(host, to: statement, at: 1)
        }

        var groups = [TemplateGroup]()
        while sqlite3_step(statement) == SQLITE_ROW {
            groups.append(
                TemplateGroup(
                    host: columnString(statement, 0),
                    elementSig: columnString(statement, 1),
                    taskId: emptyToNil(columnString(statement, 2)),
                    actionType: columnString(statement, 3),
                    sampleSize: Int(sqlite3_column_int(statement, 4))
                )
            )
        }
        return groups
    }

    private func buildParams(for group: TemplateGroup) throws -> String {
        let sql = """
        SELECT payload
        FROM traces
        WHERE host = ?
          AND COALESCE(element_sig, '') = ?
          AND COALESCE(task_id, '') = ?
          AND action_type = ?
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindText(group.host, to: statement, at: 1)
        bindText(group.elementSig, to: statement, at: 2)
        bindText(group.taskId ?? "", to: statement, at: 3)
        bindText(group.actionType, to: statement, at: 4)

        var samples = [TraceSample]()

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let data = columnString(statement, 0).data(using: .utf8),
                  let payload = try? decoder.decode(TracePayload.self, from: data) else {
                continue
            }
            if let sample = traceSample(from: payload) {
                samples.append(sample)
            }
        }

        let behaviorBlend = behaviorBlend(for: samples)
        let motion = MotionProfile(
            flavor: deriveFlavor(from: samples, behaviorBlend: behaviorBlend),
            behaviorBlend: behaviorBlend,
            moveSpeedPxS: group.actionType == "move" ? stochasticDoubleRange(values: samples.compactMap(\.speedPxS), floor: 90, ceil: 1400, minimumFractionalSpan: 0.18, absoluteMinimumSpan: 60) : nil,
            dragSpeedPxS: group.actionType == "drag" ? stochasticDoubleRange(values: samples.compactMap(\.speedPxS), floor: 80, ceil: 1200, minimumFractionalSpan: 0.20, absoluteMinimumSpan: 50) : nil,
            pointCount: stochasticIntRange(values: samples.map(\.pointCount).filter { $0 > 0 }, minimumSpan: 2, floor: 1, ceil: 240),
            overshootProbability: boundedProbability(averageOrNil(samples.compactMap(\.overshootSignal))),
            wind: deriveWind(from: samples),
            gravity: deriveGravity(from: samples),
            maxStep: deriveMaxStep(from: samples),
            jitter: deriveJitter(from: samples),
            controlSpread: deriveControlSpread(from: samples),
            targetSpreadPx: deriveTargetSpread(from: samples),
            hesitationProbability: deriveHesitationProbability(from: samples),
            hesitationMs: stochasticIntRange(values: samples.flatMap(\.hesitationMs), minimumSpan: 18, floor: 24, ceil: 420),
            settleMs: deriveSettleRange(from: samples),
            detourProbability: boundedProbability(averageOrNil(samples.compactMap(\.detourSignal))),
            clickHoldMs: stochasticIntRange(values: samples.flatMap(\.clickHoldMs), minimumSpan: 12, floor: 18, ceil: 320),
            interClickMs: stochasticIntRange(values: samples.flatMap(\.interClickMs), minimumSpan: 18, floor: 36, ceil: 520),
            doubleClickHoldMs: stochasticIntRange(values: samples.flatMap(\.clickHoldMs), minimumSpan: 10, floor: 18, ceil: 320),
            doubleClickInterClickMs: stochasticIntRange(values: samples.flatMap(\.doubleClickIntervalMs), minimumSpan: 12, floor: 40, ceil: 520),
            doubleClickSecondOffsetPx: deriveDoubleClickSecondOffsetRange(from: samples),
            scrollDeltaX: signedDoubleRange(values: samples.flatMap(\.scrollDeltas).map(\.dx), floor: -3000, ceil: 3000, absoluteMinimumSpan: 1),
            scrollDeltaY: signedDoubleRange(values: samples.flatMap(\.scrollDeltas).map(\.dy), floor: -3000, ceil: 3000, absoluteMinimumSpan: 1),
            scrollStepCount: stochasticIntRange(values: samples.map { Double($0.scrollDeltas.count) }.filter { $0 > 0 }, minimumSpan: 1, floor: 1, ceil: 64),
            scrollStepDelayMs: stochasticIntRange(values: samples.flatMap(\.scrollIntervalsMs), minimumSpan: 6, floor: 1, ceil: 600),
            scrollInertiaDecay: deriveScrollInertiaDecayRange(from: samples),
            dwellMs: stochasticIntRange(values: samples.flatMap(\.dwellMs), minimumSpan: 8, floor: 12, ceil: 600),
            interKeyMs: stochasticIntRange(values: samples.flatMap(\.interKeyMs), minimumSpan: 10, floor: 12, ceil: 900),
            modifierHoldMs: stochasticIntRange(values: samples.flatMap(\.dwellMs), minimumSpan: 8, floor: 12, ceil: 900),
            keyRepeatDelayMs: stochasticIntRange(values: samples.map(\.repeatCount).filter { $0 > 0 }.map { Double($0) * 90 }, minimumSpan: 20, floor: 80, ceil: 1200),
            keyRepeatIntervalMs: stochasticIntRange(values: samples.map(\.repeatCount).filter { $0 > 0 }.map { Double($0) * 35 }, minimumSpan: 10, floor: 24, ceil: 320),
            pathSkeleton: learnedPathSkeleton(from: samples),
            segmentMs: learnedSegmentRanges(from: samples),
            dwellMsMean: averageOrNil(samples.flatMap(\.dwellMs)),
            interKeyMsMean: averageOrNil(samples.flatMap(\.interKeyMs)),
            straightnessMean: averageOrNil(samples.compactMap(\.straightness)),
            turnJitterMean: averageOrNil(samples.compactMap(\.turnJitter))
        )
        let template = LearnedRawHIDTemplate(
            version: 2,
            strategy: "profile",
            actionType: group.actionType,
            sampleSize: group.sampleSize,
            motion: motion,
            rawHID: rawHIDProfile(for: samples)
        )

        let data = try templateEncoder.encode(template)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func insertTemplate(group: TemplateGroup, paramsJSON: String) throws {
        let template = ProfileTemplate(
            host: group.host,
            elementSig: group.elementSig,
            taskId: group.taskId,
            actionType: group.actionType,
            sampleSize: group.sampleSize,
            confidence: min(1.0, Double(group.sampleSize) / 50.0),
            paramsJSON: paramsJSON,
            updatedAt: currentTimeMs()
        )
        try upsertTemplate(template)
    }

    private func upsertTemplate(_ template: ProfileTemplate) throws {
        let sql = """
        INSERT OR REPLACE INTO templates
          (host, element_sig, task_id, action_type, sample_size, confidence, params, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bindText(template.host, to: statement, at: 1)
        bindText(template.elementSig, to: statement, at: 2)
        bindText(template.taskId ?? "", to: statement, at: 3)
        bindText(template.actionType, to: statement, at: 4)
        sqlite3_bind_int(statement, 5, Int32(template.sampleSize))
        sqlite3_bind_double(statement, 6, template.confidence)
        bindText(template.paramsJSON, to: statement, at: 7)
        sqlite3_bind_int64(statement, 8, template.updatedAt)

        try stepDone(statement)
    }

    private func deleteTraces(host: String?, sig: String?) throws {
        let (whereClause, bindings) = deleteWhere(host: host, sig: sig)
        let statement = try prepare("DELETE FROM traces \(whereClause)")
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        try stepDone(statement)
    }

    private func deleteTemplates(host: String?, sig: String?) throws {
        let (whereClause, bindings) = deleteWhere(host: host, sig: sig)
        let statement = try prepare("DELETE FROM templates \(whereClause)")
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        try stepDone(statement)
    }

    private func deleteWhere(host: String?, sig: String?) -> (String, [String]) {
        var clauses = [String]()
        var bindings = [String]()
        if let host {
            clauses.append("host = ?")
            bindings.append(host)
        }
        if let sig {
            clauses.append("element_sig = ?")
            bindings.append(sig)
        }
        if clauses.isEmpty {
            return ("", bindings)
        }
        return ("WHERE " + clauses.joined(separator: " AND "), bindings)
    }

    private func countTraces(host: String?) throws -> Int {
        if let host {
            let statement = try prepare("SELECT COUNT(*) FROM traces WHERE host = ?")
            defer { sqlite3_finalize(statement) }
            bindText(host, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return 0
            }
            return Int(sqlite3_column_int(statement, 0))
        }
        return try scalarInt("SELECT COUNT(*) FROM traces")
    }

    private func performRetentionIfNeeded(nowMs: Int64, force: Bool = false) throws {
        guard retentionPolicy.maxAgeMs > 0 || retentionPolicy.maxTracesPerGroup > 0 else {
            return
        }
        let interval = retentionPolicy.cleanupIntervalMs
        let shouldRun = force || interval <= 0 || lastCleanupAtMs == 0 || (nowMs - lastCleanupAtMs) >= interval
        guard shouldRun else {
            return
        }

        if retentionPolicy.maxAgeMs > 0 {
            try deleteAgedTraces(olderThan: nowMs - retentionPolicy.maxAgeMs)
        }
        if retentionPolicy.maxTracesPerGroup > 0 {
            try trimTraceOverflow(limit: retentionPolicy.maxTracesPerGroup)
            try trimReplayOverflow(limit: retentionPolicy.maxTracesPerGroup)
        }
        lastCleanupAtMs = nowMs
    }

    private func deleteAgedTraces(olderThan cutoffMs: Int64) throws {
        let statement = try prepare("DELETE FROM traces WHERE ts < ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoffMs)
        try stepDone(statement)
    }

    private func trimReplayFingerprints(nowMs: Int64) throws {
        if retentionPolicy.maxAgeMs > 0 {
            let statement = try prepare("DELETE FROM replay_fingerprints WHERE ts < ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, nowMs - retentionPolicy.maxAgeMs)
            try stepDone(statement)
        }
        if retentionPolicy.maxTracesPerGroup > 0 {
            try trimReplayOverflow(limit: retentionPolicy.maxTracesPerGroup)
        }
    }

    private func trimTraceOverflow(limit: Int) throws {
        let sql = """
        WITH ranked AS (
          SELECT id,
                 ROW_NUMBER() OVER (
                   PARTITION BY host, COALESCE(element_sig, ''), COALESCE(task_id, ''), action_type
                   ORDER BY ts DESC, id DESC
                 ) AS row_num
          FROM traces
        )
        DELETE FROM traces
        WHERE id IN (SELECT id FROM ranked WHERE row_num > ?)
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        try stepDone(statement)
    }

    private func trimReplayOverflow(limit: Int) throws {
        let sql = """
        WITH ranked AS (
          SELECT id,
                 ROW_NUMBER() OVER (
                   PARTITION BY host, COALESCE(task_id, ''), COALESCE(stage, ''), instruction_key, action_type
                   ORDER BY ts DESC, id DESC
                 ) AS row_num
          FROM replay_fingerprints
        )
        DELETE FROM replay_fingerprints
        WHERE id IN (SELECT id FROM ranked WHERE row_num > ?)
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        try stepDone(statement)
    }

    private func traceSample(from payload: TracePayload) -> TraceSample? {
        let path = resolvedPath(from: payload)
        let pathLength = positive(payload.pathLengthPx) ?? computePathLength(path)
        let durationMs = positive(payload.durationMs) ?? sumPositive(payload.segmentMs)
        let speedPxS = positive(payload.speedPxS) ?? {
            guard let pathLength, let durationMs, durationMs > 0 else {
                return nil
            }
            return (pathLength / durationMs) * 1000.0
        }()
        let landingErrorPx = positive(payload.landingErrorPx) ?? computeLandingError(path: path, target: payload.targetPoint)
        let straightness = boundedUnit(payload.straightness ?? computeStraightness(path))
        let turnJitter = boundedUnit(payload.turnJitter ?? computeTurnJitter(path))
        let pointCount = max(path.count, payload.points.count, payload.point == nil ? 0 : 1)

        guard pointCount > 0
            || !payload.clickHoldMs.isEmpty
            || !payload.interClickMs.isEmpty
            || !payload.dwellMs.isEmpty
            || !payload.interKeyMs.isEmpty
            || !payload.scrollDeltas.isEmpty
            || !payload.scrollIntervalsMs.isEmpty
            || !payload.doubleClickIntervalMs.isEmpty
            || !payload.modifierFlags.isEmpty
            || !payload.flagsChangedKeyCodes.isEmpty
            || !payload.comboKeyCodes.isEmpty
            || payload.repeatCount > 0 else {
            return nil
        }

        let targetSpreadPx = positive(landingErrorPx)
            ?? positive(payload.targetRadiusPx)
            ?? inferTargetSpread(path: path, target: payload.targetPoint)
        let overshootSignal = computeOvershootSignal(path: path, target: payload.targetPoint, targetRadiusPx: payload.targetRadiusPx)
        let detourSignal = straightness.map { $0 < 0.9 ? 1.0 : max(0, min(1, (1 - $0) * 2.8)) }
        let behaviorMode = payload.behaviorMode ?? classifyBehavior(
            speedPxS: speedPxS,
            hesitationMs: payload.hesitationMs,
            clickHoldMs: payload.clickHoldMs,
            dwellMs: payload.dwellMs,
            interKeyMs: payload.interKeyMs,
            straightness: straightness,
            turnJitter: turnJitter,
            targetSpreadPx: targetSpreadPx
        )

        return TraceSample(
            pathSkeleton: path,
            segmentMs: payload.segmentMs.filter { $0 > 0 },
            pointCount: max(1, pointCount),
            speedPxS: speedPxS,
            hesitationMs: payload.hesitationMs.filter { $0 > 0 },
            clickHoldMs: payload.clickHoldMs.filter { $0 > 0 },
            interClickMs: payload.interClickMs.filter { $0 > 0 },
            dwellMs: payload.dwellMs.filter { $0 > 0 },
            interKeyMs: payload.interKeyMs.filter { $0 > 0 },
            scrollDeltas: payload.scrollDeltas.filter { $0.dx != 0 || $0.dy != 0 },
            scrollIntervalsMs: payload.scrollIntervalsMs.filter { $0 > 0 },
            doubleClickIntervalMs: payload.doubleClickIntervalMs.filter { $0 > 0 },
            modifierFlags: payload.modifierFlags,
            flagsChangedKeyCodes: payload.flagsChangedKeyCodes,
            comboKeyCodes: payload.comboKeyCodes,
            repeatCount: payload.repeatCount,
            eventTimeline: payload.eventTimeline,
            straightness: straightness,
            turnJitter: turnJitter,
            targetSpreadPx: targetSpreadPx,
            overshootSignal: overshootSignal,
            detourSignal: detourSignal,
            behaviorMode: behaviorMode,
            flavor: payload.flavor
        )
    }

    private func resolvedPath(from payload: TracePayload) -> [TracePoint] {
        if !payload.points.isEmpty {
            return payload.points
        }
        var path = [TracePoint]()
        if let origin = payload.origin {
            path.append(origin)
        }
        if let point = payload.point, path.last != point {
            path.append(point)
        } else if let targetPoint = payload.targetPoint, path.last != targetPoint {
            path.append(targetPoint)
        }
        return path
    }

    private func computePathLength(_ path: [TracePoint]) -> Double? {
        guard path.count > 1 else {
            return nil
        }
        return zip(path, path.dropFirst()).reduce(0) { partial, pair in
            partial + distance(from: pair.0, to: pair.1)
        }
    }

    private func computeLandingError(path: [TracePoint], target: TracePoint?) -> Double? {
        guard let target, let last = path.last else {
            return nil
        }
        return distance(from: last, to: target)
    }

    private func inferTargetSpread(path: [TracePoint], target: TracePoint?) -> Double? {
        guard let target else {
            return nil
        }
        let distances = path.map { distance(from: $0, to: target) }.filter { $0 > 0 }
        guard !distances.isEmpty else {
            return nil
        }
        return percentile(of: distances.sorted(), at: 0.2)
    }

    private func computeStraightness(_ path: [TracePoint]) -> Double? {
        guard path.count > 1, let pathLength = computePathLength(path), pathLength > 0 else {
            return nil
        }
        let direct = distance(from: path[0], to: path[path.count - 1])
        return max(0, min(1, direct / pathLength))
    }

    private func computeTurnJitter(_ path: [TracePoint]) -> Double? {
        guard path.count > 2 else {
            return nil
        }
        var turns = [Double]()
        turns.reserveCapacity(path.count - 2)
        for index in 1..<(path.count - 1) {
            let previous = path[index - 1]
            let current = path[index]
            let next = path[index + 1]
            let a1 = atan2(current.y - previous.y, current.x - previous.x)
            let a2 = atan2(next.y - current.y, next.x - current.x)
            turns.append(abs(normalizeAngle(a2 - a1)) / Double.pi)
        }
        return averageOrNil(turns)
    }

    private func computeOvershootSignal(path: [TracePoint], target: TracePoint?, targetRadiusPx: Double?) -> Double? {
        guard let target, path.count > 2 else {
            return nil
        }
        let threshold = max(targetRadiusPx ?? 0, 4)
        let distances = path.map { distance(from: $0, to: target) }
        guard let entryIndex = distances.firstIndex(where: { $0 <= threshold }) else {
            return 0
        }
        let suffix = distances.suffix(from: entryIndex)
        guard let maxAfterEntry = suffix.max(), let finalDistance = distances.last else {
            return 0
        }
        return maxAfterEntry > threshold * 1.7 && finalDistance <= threshold * 1.15 ? 1 : 0
    }

    private func behaviorBlend(for samples: [TraceSample]) -> BehaviorBlend {
        guard !samples.isEmpty else {
            return BehaviorBlend(normal: 1).normalized()
        }
        var idle = 0.0
        var normal = 0.0
        var flow = 0.0
        var lowEfficiency = 0.0
        for sample in samples {
            switch sample.behaviorMode {
            case .idle:
                idle += 1
            case .normal:
                normal += 1
            case .flow:
                flow += 1
            case .lowEfficiency:
                lowEfficiency += 1
            }
        }
        return BehaviorBlend(
            idle: idle,
            normal: normal,
            flow: flow,
            lowEfficiency: lowEfficiency
        ).normalized()
    }

    private func deriveFlavor(from samples: [TraceSample], behaviorBlend: BehaviorBlend) -> MotionFlavor {
        let explicit = samples.compactMap(\.flavor)
        if let winner = mostFrequent(explicit) {
            return winner
        }
        let weights = behaviorBlend.normalized()
        if weights.idle >= max(weights.normal, weights.flow, weights.lowEfficiency) {
            return .idle
        }
        if weights.flow >= max(weights.idle, weights.normal, weights.lowEfficiency) {
            return .hurried
        }
        let straightness = averageOrNil(samples.compactMap(\.straightness)) ?? 0.9
        let jitter = averageOrNil(samples.compactMap(\.turnJitter)) ?? 0.1
        return straightness >= 0.91 && jitter <= 0.18 ? .smooth : .gentle
    }

    private func deriveWind(from samples: [TraceSample]) -> Double? {
        let jitter = averageOrNil(samples.compactMap(\.turnJitter))
        let hesitation = deriveHesitationProbability(from: samples)
        guard jitter != nil || hesitation != nil else {
            return nil
        }
        return clamp(2.2 + (jitter ?? 0.12) * 4.8 + (hesitation ?? 0.16) * 1.6, min: 1.2, max: 8.8)
    }

    private func deriveGravity(from samples: [TraceSample]) -> Double? {
        let straightness = averageOrNil(samples.compactMap(\.straightness))
        let speed = averageOrNil(samples.compactMap(\.speedPxS))
        guard straightness != nil || speed != nil else {
            return nil
        }
        return clamp(7.4 + (straightness ?? 0.9) * 2.0 + min((speed ?? 320) / 420, 2.2), min: 6.0, max: 13.5)
    }

    private func deriveMaxStep(from samples: [TraceSample]) -> Double? {
        guard let speed = averageOrNil(samples.compactMap(\.speedPxS)) else {
            return nil
        }
        return clamp(speed / 72, min: 4.0, max: 18.0)
    }

    private func deriveJitter(from samples: [TraceSample]) -> Double? {
        guard let turnJitter = averageOrNil(samples.compactMap(\.turnJitter)) else {
            return nil
        }
        return clamp(0.03 + turnJitter * 0.75, min: 0.02, max: 0.5)
    }

    private func deriveControlSpread(from samples: [TraceSample]) -> Double? {
        let turnJitter = averageOrNil(samples.compactMap(\.turnJitter))
        let targetSpread = deriveTargetSpread(from: samples)
        guard turnJitter != nil || targetSpread != nil else {
            return nil
        }
        let targetRatio = min((targetSpread ?? 4) / 180, 0.16)
        return clamp(0.08 + (turnJitter ?? 0.12) * 0.62 + targetRatio, min: 0.05, max: 0.34)
    }

    private func deriveTargetSpread(from samples: [TraceSample]) -> Double? {
        let values = samples.compactMap(\.targetSpreadPx).filter { $0 > 0 }
        guard !values.isEmpty else {
            return nil
        }
        let sorted = values.sorted()
        return clamp(max(percentile(of: sorted, at: 0.7), mean(sorted) * 0.92), min: 1.5, max: 48)
    }

    private func deriveHesitationProbability(from samples: [TraceSample]) -> Double? {
        guard !samples.isEmpty else {
            return nil
        }
        let hits = Double(samples.filter { !$0.hesitationMs.isEmpty }.count)
        return boundedProbability(hits / Double(samples.count))
    }

    private func deriveSettleRange(from samples: [TraceSample]) -> IntRange? {
        let baseValues = samples.compactMap(\.targetSpreadPx).map { max(24, $0 * 6.2) }
        let hesitationTail = samples.flatMap(\.hesitationMs).map { max(18, $0 * 0.42) }
        let settleValues = baseValues + hesitationTail
        guard !settleValues.isEmpty else {
            return nil
        }
        return stochasticIntRange(values: settleValues, minimumSpan: 16, floor: 20, ceil: 260)
    }

    private func deriveDoubleClickSecondOffsetRange(from samples: [TraceSample]) -> DoubleRange? {
        let values = samples
            .filter { !$0.doubleClickIntervalMs.isEmpty }
            .compactMap(\.targetSpreadPx)
        guard !values.isEmpty else {
            return nil
        }
        return stochasticDoubleRange(values: values, floor: 0, ceil: 16, minimumFractionalSpan: 0.24, absoluteMinimumSpan: 1.5)
    }

    private func deriveScrollInertiaDecayRange(from samples: [TraceSample]) -> DoubleRange? {
        let ratios = samples.flatMap { sample -> [Double] in
            let magnitudes = sample.scrollDeltas
                .map { hypot($0.dx, $0.dy) }
                .filter { $0 > 0.01 }
            guard magnitudes.count > 1 else {
                return []
            }
            return zip(magnitudes.dropFirst(), magnitudes).compactMap { current, previous in
                guard previous > 0 else {
                    return nil
                }
                return clamp(current / previous, min: 0.2, max: 0.98)
            }
        }
        return stochasticDoubleRange(values: ratios, floor: 0.2, ceil: 0.98, minimumFractionalSpan: 0.12, absoluteMinimumSpan: 0.06)
    }

    private func learnedPathSkeleton(from samples: [TraceSample]) -> [LearnedPathPoint]? {
        let representative = representativePathSkeleton(from: samples)
        guard representative.count >= 2 else {
            return nil
        }
        return representative.map { LearnedPathPoint(x: $0.x, y: $0.y) }
    }

    private func learnedSegmentRanges(from samples: [TraceSample]) -> [IntRange]? {
        let segments = samples.map(\.segmentMs).filter { !$0.isEmpty }
        guard let targetCount = segments.max(by: { $0.count < $1.count })?.count, targetCount > 0 else {
            return nil
        }
        let ranges = (0..<targetCount).compactMap { index -> IntRange? in
            let values = segments.compactMap { segment -> Double? in
                guard segment.indices.contains(index) else {
                    return nil
                }
                return segment[index]
            }
            return stochasticIntRange(values: values, minimumSpan: 8, floor: 1, ceil: 1_200)
        }
        return ranges.isEmpty ? nil : ranges
    }

    private func rawHIDProfile(for samples: [TraceSample]) -> RawHIDLearningProfile? {
        let scrollDeltas = samples.flatMap(\.scrollDeltas)
        let scrollIntervals = samples.flatMap(\.scrollIntervalsMs)
        let doubleClickIntervals = samples.flatMap(\.doubleClickIntervalMs)
        let dwell = samples.flatMap(\.dwellMs)
        let interKey = samples.flatMap(\.interKeyMs)
        let repeatCounts = samples.map(\.repeatCount)
        let modifierFlags = sortedUnique(samples.flatMap(\.modifierFlags))
        let flagsChanged = sortedUnique(samples.flatMap(\.flagsChangedKeyCodes))
        let comboKeys = sortedUniqueCombos(samples.map(\.comboKeyCodes).filter { !$0.isEmpty })
        let representative = representativePathSkeleton(from: samples)
        let representativeSegments = representativeSegmentMs(from: samples)
        let timeline = representativeTimeline(from: samples)

        let profile = RawHIDLearningProfile(
            scrollDeltaX: signedDoubleRange(values: scrollDeltas.map(\.dx), floor: -3000, ceil: 3000, absoluteMinimumSpan: 1),
            scrollDeltaY: signedDoubleRange(values: scrollDeltas.map(\.dy), floor: -3000, ceil: 3000, absoluteMinimumSpan: 1),
            scrollIntervalsMs: stochasticIntRange(values: scrollIntervals, minimumSpan: 6, floor: 1, ceil: 600),
            scrollEventCount: stochasticIntRange(values: samples.map { Double($0.scrollDeltas.count) }.filter { $0 > 0 }, minimumSpan: 1, floor: 1, ceil: 64),
            doubleClickIntervalMs: stochasticIntRange(values: doubleClickIntervals, minimumSpan: 12, floor: 40, ceil: 520),
            dwellMs: stochasticIntRange(values: dwell, minimumSpan: 8, floor: 12, ceil: 600),
            interKeyMs: stochasticIntRange(values: interKey, minimumSpan: 10, floor: 12, ceil: 900),
            repeatCount: stochasticIntRange(values: repeatCounts.map(Double.init).filter { $0 > 0 }, minimumSpan: 1, floor: 1, ceil: 32),
            modifierFlags: modifierFlags,
            flagsChangedKeyCodes: flagsChanged,
            comboKeyCodes: comboKeys,
            pathSkeleton: representative,
            segmentMs: representativeSegments,
            eventTimeline: timeline
        )

        if profile.scrollDeltaX == nil,
           profile.scrollDeltaY == nil,
           profile.scrollIntervalsMs == nil,
           profile.scrollEventCount == nil,
           profile.doubleClickIntervalMs == nil,
           profile.dwellMs == nil,
           profile.interKeyMs == nil,
           profile.repeatCount == nil,
           profile.modifierFlags.isEmpty,
           profile.flagsChangedKeyCodes.isEmpty,
           profile.comboKeyCodes.isEmpty,
           profile.pathSkeleton.isEmpty,
           profile.segmentMs.isEmpty,
           profile.eventTimeline.isEmpty {
            return nil
        }
        return profile
    }

    private func classifyBehavior(
        speedPxS: Double?,
        hesitationMs: [Double],
        clickHoldMs: [Double],
        dwellMs: [Double],
        interKeyMs: [Double],
        straightness: Double?,
        turnJitter: Double?,
        targetSpreadPx: Double?
    ) -> HumanBehaviorMode {
        let hesitationMean = averageOrNil(hesitationMs) ?? 0
        let clickHoldMean = averageOrNil(clickHoldMs) ?? 0
        let dwellMean = averageOrNil(dwellMs) ?? 0
        let interKeyMean = averageOrNil(interKeyMs) ?? 0
        let straightness = straightness ?? 0.9
        let turnJitter = turnJitter ?? 0.1
        let targetSpread = targetSpreadPx ?? 0

        if let speedPxS, speedPxS >= 640, hesitationMean < 76, clickHoldMean < 84, interKeyMean < 118, straightness > 0.9, turnJitter < 0.24 {
            return .flow
        }
        if dwellMean >= 320 || interKeyMean >= 220 || clickHoldMean >= 160 || (speedPxS ?? 0) < 150 && hesitationMean >= 120 {
            return .idle
        }
        if hesitationMean >= 150 || turnJitter >= 0.4 || straightness <= 0.82 || targetSpread >= 18 || ((speedPxS ?? 280) < 210 && straightness < 0.88) {
            return .lowEfficiency
        }
        return .normal
    }

    private func stochasticIntRange(values: [Int], minimumSpan: Int, floor lowerBound: Int, ceil upperBound: Int) -> IntRange? {
        stochasticIntRange(values: values.map(Double.init), minimumSpan: minimumSpan, floor: lowerBound, ceil: upperBound)
    }

    private func stochasticIntRange(values: [Double], minimumSpan: Int, floor lowerBound: Int, ceil upperBound: Int) -> IntRange? {
        guard let range = stochasticDoubleRange(
            values: values,
            floor: Double(lowerBound),
            ceil: Double(upperBound),
            minimumFractionalSpan: 0.16,
            absoluteMinimumSpan: Double(minimumSpan)
        ) else {
            return nil
        }
        let minValue = max(lowerBound, Int(floor(range.min)))
        let maxValue = min(upperBound, max(minValue + minimumSpan, Int(ceil(range.max))))
        return IntRange(min: minValue, max: maxValue)
    }

    private func stochasticDoubleRange(
        values: [Double],
        floor lowerBound: Double,
        ceil upperBound: Double,
        minimumFractionalSpan: Double,
        absoluteMinimumSpan: Double
    ) -> DoubleRange? {
        let filtered = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !filtered.isEmpty else {
            return nil
        }

        let low = percentile(of: filtered, at: 0.18)
        let high = percentile(of: filtered, at: 0.86)
        let center = mean(filtered)
        let minimumSpan = max(abs(center) * minimumFractionalSpan, absoluteMinimumSpan)

        var minValue = max(lowerBound, min(low, center - minimumSpan / 2))
        var maxValue = min(upperBound, max(high, center + minimumSpan / 2))
        if maxValue - minValue < minimumSpan {
            let midpoint = clamp(center, min: lowerBound + minimumSpan / 2, max: upperBound - minimumSpan / 2)
            minValue = max(lowerBound, midpoint - minimumSpan / 2)
            maxValue = min(upperBound, midpoint + minimumSpan / 2)
        }

        if maxValue <= minValue {
            maxValue = min(upperBound, minValue + minimumSpan)
        }
        return DoubleRange(min: minValue, max: maxValue)
    }

    private func signedDoubleRange(
        values: [Double],
        floor lowerBound: Double,
        ceil upperBound: Double,
        absoluteMinimumSpan: Double
    ) -> DoubleRange? {
        let filtered = values.filter { $0.isFinite && $0 != 0 }.sorted()
        guard !filtered.isEmpty else {
            return nil
        }
        let low = percentile(of: filtered, at: 0.18)
        let high = percentile(of: filtered, at: 0.86)
        let center = mean(filtered)
        let minimumSpan = max(absoluteMinimumSpan, abs(center) * 0.12)
        var minValue = max(lowerBound, min(low, center - minimumSpan / 2))
        var maxValue = min(upperBound, max(high, center + minimumSpan / 2))
        if maxValue - minValue < minimumSpan {
            let midpoint = clamp(center, min: lowerBound + minimumSpan / 2, max: upperBound - minimumSpan / 2)
            minValue = max(lowerBound, midpoint - minimumSpan / 2)
            maxValue = min(upperBound, midpoint + minimumSpan / 2)
        }
        return DoubleRange(min: minValue, max: maxValue)
    }

    private func representativePathSkeleton(from samples: [TraceSample]) -> [TracePoint] {
        samples
            .filter { $0.pathSkeleton.count >= 2 }
            .max { lhs, rhs in lhs.pathSkeleton.count < rhs.pathSkeleton.count }?
            .pathSkeleton ?? []
    }

    private func representativeSegmentMs(from samples: [TraceSample]) -> [Double] {
        samples
            .filter { !$0.segmentMs.isEmpty }
            .max { lhs, rhs in lhs.segmentMs.count < rhs.segmentMs.count }?
            .segmentMs ?? []
    }

    private func representativeTimeline(from samples: [TraceSample]) -> [String] {
        samples
            .filter { !$0.eventTimeline.isEmpty }
            .max { lhs, rhs in lhs.eventTimeline.count < rhs.eventTimeline.count }?
            .eventTimeline ?? []
    }

    private func sortedUnique<T: Comparable & Hashable>(_ values: [T]) -> [T] {
        Array(Set(values)).sorted()
    }

    private func sortedUniqueCombos(_ combos: [[UInt16]]) -> [[UInt16]] {
        let normalized = combos.map { Array(Set($0)).sorted() }.filter { !$0.isEmpty }
        var seen = Set<String>()
        var result = [[UInt16]]()
        for combo in normalized {
            let key = combo.map(String.init).joined(separator: "+")
            if seen.insert(key).inserted {
                result.append(combo)
            }
        }
        return result.sorted { $0.lexicographicallyPrecedes($1) }
    }

    private func percentile(of sortedValues: [Double], at percentile: Double) -> Double {
        guard !sortedValues.isEmpty else {
            return 0
        }
        if sortedValues.count == 1 {
            return sortedValues[0]
        }
        let clamped = clamp(percentile, min: 0, max: 1)
        let index = clamped * Double(sortedValues.count - 1)
        let lowerIndex = Int(floor(index))
        let upperIndex = Int(ceil(index))
        guard lowerIndex != upperIndex else {
            return sortedValues[lowerIndex]
        }
        let fraction = index - Double(lowerIndex)
        return sortedValues[lowerIndex] + (sortedValues[upperIndex] - sortedValues[lowerIndex]) * fraction
    }

    private func averageOrNil(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        return mean(values)
    }

    private func mostFrequent<T: Hashable>(_ values: [T]) -> T? {
        guard !values.isEmpty else {
            return nil
        }
        var counts = [T: Int]()
        for value in values {
            counts[value, default: 0] += 1
        }
        return counts.max { lhs, rhs in
            if lhs.value == rhs.value {
                return String(describing: lhs.key) > String(describing: rhs.key)
            }
            return lhs.value < rhs.value
        }?.key
    }

    private func sumPositive(_ values: [Double]) -> Double? {
        let filtered = values.filter { $0 > 0 }
        guard !filtered.isEmpty else {
            return nil
        }
        return filtered.reduce(0, +)
    }

    private func positive(_ value: Double?) -> Double? {
        guard let value, value > 0, value.isFinite else {
            return nil
        }
        return value
    }

    private func boundedUnit(_ value: Double?) -> Double? {
        guard let value else {
            return nil
        }
        return clamp(value, min: 0, max: 1)
    }

    private func boundedProbability(_ value: Double?) -> Double? {
        guard let value else {
            return nil
        }
        return clamp(value, min: 0, max: 1)
    }

    private func distance(from lhs: TracePoint, to rhs: TracePoint) -> Double {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
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

    private func clamp<T: Comparable>(_ value: T, min lowerBound: T, max upperBound: T) -> T {
        Swift.max(lowerBound, Swift.min(upperBound, value))
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(error)
            throw ProfileStoreError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw ProfileStoreError.sqlite(lastErrorMessage())
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ProfileStoreError.sqlite(lastErrorMessage())
        }
    }

    private func bind(_ values: [String], to statement: OpaquePointer?) {
        for (index, value) in values.enumerated() {
            bindText(value, to: statement, at: Int32(index + 1))
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bindNullableText(_ value: String?, to statement: OpaquePointer?, at index: Int32) {
        if let value {
            bindText(value, to: statement, at: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func template(from statement: OpaquePointer?) -> ProfileTemplate {
        ProfileTemplate(
            host: columnString(statement, 0),
            elementSig: columnString(statement, 1),
            taskId: emptyToNil(columnString(statement, 2)),
            actionType: columnString(statement, 3),
            sampleSize: Int(sqlite3_column_int(statement, 4)),
            confidence: sqlite3_column_double(statement, 5),
            paramsJSON: columnString(statement, 6),
            updatedAt: sqlite3_column_int64(statement, 7)
        )
    }

    private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: pointer)
    }

    private func emptyToNil(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private func lastErrorMessage() -> String {
        db.flatMap { sqlite3_errmsg($0).map { String(cString: $0) } } ?? "unknown"
    }

    private func currentTimeMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func actionType(forObservedType eventType: String) -> String {
        switch eventType {
        case "leftMouseDown", "rightMouseDown", "otherMouseDown", "leftMouseUp", "rightMouseUp", "otherMouseUp":
            return "click"
        case "leftMouseDragged", "rightMouseDragged", "otherMouseDragged":
            return "drag"
        case "scrollWheel":
            return "scroll"
        case "keyDown", "keyUp":
            return "type"
        default:
            return "move"
        }
    }

    public static func isSensitiveRole(_ role: String?) -> Bool {
        guard let role = role?.lowercased() else {
            return false
        }
        return role == "password" || role == "securetextfield" || role == "secure-text-field"
    }
}

private struct TemplateGroup {
    let host: String
    let elementSig: String
    let taskId: String?
    let actionType: String
    let sampleSize: Int
}

private struct LearnedRawHIDTemplate: Codable, Equatable {
    let version: Int
    let strategy: String
    let actionType: String
    let sampleSize: Int
    let motion: MotionProfile
    let rawHID: RawHIDLearningProfile?
}

private struct TraceSample {
    let pathSkeleton: [TracePoint]
    let segmentMs: [Double]
    let pointCount: Int
    let speedPxS: Double?
    let hesitationMs: [Double]
    let clickHoldMs: [Double]
    let interClickMs: [Double]
    let dwellMs: [Double]
    let interKeyMs: [Double]
    let scrollDeltas: [TraceScrollDelta]
    let scrollIntervalsMs: [Double]
    let doubleClickIntervalMs: [Double]
    let modifierFlags: [UInt64]
    let flagsChangedKeyCodes: [UInt16]
    let comboKeyCodes: [UInt16]
    let repeatCount: Int
    let eventTimeline: [String]
    let straightness: Double?
    let turnJitter: Double?
    let targetSpreadPx: Double?
    let overshootSignal: Double?
    let detourSignal: Double?
    let behaviorMode: HumanBehaviorMode
    let flavor: MotionFlavor?
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
