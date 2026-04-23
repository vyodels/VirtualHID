import Foundation
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

public struct TracePayload: Codable, Equatable {
    public let eventId: String?
    public let type: String
    public let point: TracePoint?
    public let keyCode: UInt16?
    public let points: [TracePoint]
    public let dwellMs: [Double]
    public let interKeyMs: [Double]

    public init(
        eventId: String?,
        type: String,
        point: TracePoint? = nil,
        keyCode: UInt16? = nil,
        points: [TracePoint] = [],
        dwellMs: [Double] = [],
        interKeyMs: [Double] = []
    ) {
        self.eventId = eventId
        self.type = type
        self.point = point
        self.keyCode = keyCode
        self.points = points
        self.dwellMs = dwellMs
        self.interKeyMs = interKeyMs
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
    private let lock = NSLock()
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let logger = Logger(subsystem: "com.vyodels.virtualhid", category: "profile-store")

    public init(path: String) throws {
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
        return try lock.withLock {
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
            return sqlite3_last_insert_rowid(db)
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
        stage: String?
    ) throws -> TraceCommitResult {
        guard !host.isEmpty else {
            throw ProfileStoreError.invalidInput("host is required")
        }
        guard !elementSig.isEmpty else {
            throw ProfileStoreError.invalidInput("element_sig is required")
        }

        if Self.isSensitiveRole(role) {
            logger.notice("Dropped sensitive trace")
            return TraceCommitResult(committed: false, dropped: true, traceId: nil, reason: "sensitive_role")
        }

        let actionType = Self.actionType(forObservedType: eventType)
        let traceId = try insertTrace(
            TraceInput(
                ts: ts,
                source: "user",
                host: host,
                elementSig: elementSig,
                taskId: taskId,
                stage: stage,
                actionType: actionType,
                payload: TracePayload(
                    eventId: eventId,
                    type: eventType,
                    point: point,
                    keyCode: keyCode,
                    points: point.map { [$0] } ?? []
                )
            )
        )
        return TraceCommitResult(committed: true, dropped: false, traceId: traceId, reason: nil)
    }

    public func rebuild(host: String? = nil) throws -> AggregateReport {
        try lock.withLock {
            let scanned = try countTraces(host: host)
            try deleteTemplates(host: host, sig: nil)
            let groups = try loadGroups(host: host)
            var generated = 0

            for group in groups where group.sampleSize >= 5 {
                let params = try buildParams(for: group)
                try insertTemplate(group: group, paramsJSON: params)
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
                (sig, taskId ?? ""),
                (sig, ""),
                ("", "")
            ]

            for (candidateSig, candidateTaskId) in candidates {
                let sql = """
                SELECT host, element_sig, task_id, action_type, sample_size, confidence, params, updated_at
                FROM templates
                WHERE host = ? AND element_sig = ? AND COALESCE(task_id, '') = ? AND action_type = ?
                ORDER BY confidence DESC, updated_at DESC
                LIMIT 1
                """
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                bindText(host, to: statement, at: 1)
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
            try execute("CREATE INDEX IF NOT EXISTS idx_traces_host_sig ON traces(host, element_sig)")
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

        var points = [TracePoint]()
        var dwell = [Double]()
        var interKey = [Double]()

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let data = columnString(statement, 0).data(using: .utf8),
                  let payload = try? decoder.decode(TracePayload.self, from: data) else {
                continue
            }
            points.append(contentsOf: payload.points)
            if let point = payload.point, payload.points.isEmpty {
                points.append(point)
            }
            dwell.append(contentsOf: payload.dwellMs)
            interKey.append(contentsOf: payload.interKeyMs)
        }

        var params: [String: Any] = [
            "version": 1,
            "strategy": "profile",
            "actionType": group.actionType,
            "sampleSize": group.sampleSize
        ]

        if !points.isEmpty {
            let meanX = points.map(\.x).reduce(0, +) / Double(points.count)
            let meanY = points.map(\.y).reduce(0, +) / Double(points.count)
            params["controlPoints"] = [["x": meanX, "y": meanY]]
            params["pointCount"] = points.count
        }

        if !dwell.isEmpty || !interKey.isEmpty {
            params["dwellMsMean"] = mean(dwell)
            params["interKeyMsMean"] = mean(interKey)
        }

        let data = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func insertTemplate(group: TemplateGroup, paramsJSON: String) throws {
        let sql = """
        INSERT OR REPLACE INTO templates
          (host, element_sig, task_id, action_type, sample_size, confidence, params, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bindText(group.host, to: statement, at: 1)
        bindText(group.elementSig, to: statement, at: 2)
        bindText(group.taskId ?? "", to: statement, at: 3)
        bindText(group.actionType, to: statement, at: 4)
        sqlite3_bind_int(statement, 5, Int32(group.sampleSize))
        sqlite3_bind_double(statement, 6, min(1.0, Double(group.sampleSize) / 50.0))
        bindText(paramsJSON, to: statement, at: 7)
        sqlite3_bind_int64(statement, 8, currentTimeMs())

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

    private static func isSensitiveRole(_ role: String?) -> Bool {
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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
