import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct TaskItem: Identifiable {
    let id: Int64
    let name: String
    let description: String
    let status: String
    let sortOrder: Int64
    let updatedAt: String
}

struct SessionRow: Identifiable {
    let id: String
    let source: String
    let hostApp: String?
    let title: String
    let titleOverride: String?
    let cwd: String?
    let lastActive: String
    let lastMessage: String?
    let rawPath: String?

    var displayTitle: String {
        let trimmed = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed! : title
    }
}

struct NoteItem: Identifiable {
    let id: Int64
    let content: String
    let createdAt: String
}

final class DB {
    private var conn: OpaquePointer?

    init?() {
        let dbPath = ("~/.sessiontracker/data.db" as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        guard sqlite3_open_v2(dbPath, &conn, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_exec(conn, "PRAGMA foreign_keys = ON", nil, nil, nil)
        migrate()
    }

    deinit {
        if let conn { sqlite3_close(conn) }
    }

    private func text(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: ptr)
    }

    private func textOr(_ stmt: OpaquePointer?, _ col: Int32, _ fallback: String = "") -> String {
        text(stmt, col) ?? fallback
    }

    private func queryTasks(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }) -> [TaskItem] {
        var items: [TaskItem] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(TaskItem(
                id: sqlite3_column_int64(stmt, 0),
                name: textOr(stmt, 1),
                description: textOr(stmt, 2),
                status: textOr(stmt, 3),
                sortOrder: sqlite3_column_int64(stmt, 4),
                updatedAt: textOr(stmt, 5)
            ))
        }
        return items
    }

    func activeTasks() -> [TaskItem] {
        let sql = """
            SELECT id, name, description, status, sort_order, updated_at
            FROM tasks
            WHERE status = 'active'
            ORDER BY sort_order ASC, updated_at DESC, id DESC
        """
        return queryTasks(sql)
    }

    func archivedTasks() -> [TaskItem] {
        let sql = """
            SELECT id, name, description, status, sort_order, updated_at
            FROM tasks
            WHERE status = 'archived'
            ORDER BY updated_at DESC, sort_order ASC, id DESC
        """
        return queryTasks(sql)
    }

    // MARK: - Writes

    @discardableResult
    func createTask(name: String) -> Int64? {
        let now = ISO8601DateFormatter().string(from: Date())
        let sortOrder = newTopSortOrder()
        let sql = "INSERT INTO tasks(name, description, status, sort_order, created_at, updated_at) VALUES(?, '', 'active', ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, sortOrder)
        sqlite3_bind_text(stmt, 3, now, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, now, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(conn)
    }

    func updateTaskName(id: Int64, name: String) {
        execUpdate("UPDATE tasks SET name = ?, updated_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, isoNow(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, id)
        }
    }

    func updateTaskDescription(id: Int64, description: String) {
        execUpdate("UPDATE tasks SET description = ?, updated_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, description, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, isoNow(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, id)
        }
    }

    func deleteTask(id: Int64) {
        execUpdate("DELETE FROM tasks WHERE id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, id)
        }
    }

    func archiveTask(id: Int64) {
        execUpdate("UPDATE tasks SET status = 'archived', updated_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, id)
        }
        normalizeActiveTaskSortOrder()
    }

    func restoreTask(id: Int64) {
        let sortOrder = newTopSortOrder()
        execUpdate("UPDATE tasks SET status = 'active', sort_order = ?, updated_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, sortOrder)
            sqlite3_bind_text(stmt, 2, isoNow(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, id)
        }
        normalizeActiveTaskSortOrder()
    }

    func moveTask(id: Int64, offset: Int) {
        let order = activeTaskOrder()
        guard let index = order.firstIndex(where: { $0.id == id }) else { return }
        let targetIndex = index + offset
        guard targetIndex >= 0 && targetIndex < order.count else { return }

        let current = order[index]
        let target = order[targetIndex]
        execUpdate("UPDATE tasks SET sort_order = ? WHERE id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, target.sortOrder)
            sqlite3_bind_int64(stmt, 2, current.id)
        }
        execUpdate("UPDATE tasks SET sort_order = ? WHERE id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, current.sortOrder)
            sqlite3_bind_int64(stmt, 2, target.id)
        }
        normalizeActiveTaskSortOrder()
    }

    @discardableResult
    func createLinkSession(title: String, url: String, taskId: Int64) -> String? {
        let now = isoNow()
        let id = "link:\(UUID().uuidString)"
        let sql = """
            INSERT INTO sessions(id, source, host_app, title, cwd, last_active, last_message, raw_path)
            VALUES(?, 'link', 'Link', ?, NULL, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, now, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, url, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, url, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        linkSession(id, toTask: taskId)
        return id
    }

    func linkSession(_ sessionId: String, toTask taskId: Int64) {
        let now = isoNow()
        execUpdate("INSERT OR REPLACE INTO session_task_links(session_id, task_id, linked_at) VALUES(?, ?, ?)") { stmt in
            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, taskId)
            sqlite3_bind_text(stmt, 3, now, -1, SQLITE_TRANSIENT)
        }
        execUpdate("UPDATE tasks SET updated_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, now, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, taskId)
        }
    }

    func unlinkSessionFromAllTasks(_ sessionId: String) {
        execUpdate("DELETE FROM session_task_links WHERE session_id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
        }
    }

    func deleteSession(_ sessionId: String) {
        unlinkSessionFromAllTasks(sessionId)
        execUpdate("DELETE FROM sessions WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
        }
    }

    func hideSession(_ sessionId: String) {
        execUpdate("UPDATE sessions SET hidden_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, sessionId, -1, SQLITE_TRANSIENT)
        }
    }

    func restoreHiddenSessions() {
        execUpdate("UPDATE sessions SET hidden_at = NULL WHERE hidden_at IS NOT NULL") { _ in }
    }

    func updateSessionTitle(_ sessionId: String, title: String) {
        execUpdate("UPDATE sessions SET title_override = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, sessionId, -1, SQLITE_TRANSIENT)
        }
    }

    /// Upsert a ChatGPT session record observed from the local cache.
    func upsertChatGPTSession(id: String, title: String, lastActive: String, rawPath: String?) {
        let sql = """
            INSERT INTO sessions(id, source, host_app, title, cwd, last_active, last_message, raw_path)
            VALUES(?, 'chatgpt', 'ChatGPT', ?, NULL, ?, NULL, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = CASE
                    WHEN sessions.title IS NULL OR sessions.title = '' OR sessions.title LIKE 'ChatGPT · % · %'
                        OR sessions.title LIKE 'ChatGPT 桌面 · %'
                    THEN excluded.title
                    ELSE sessions.title
                END,
                last_active = excluded.last_active,
                raw_path = CASE
                    WHEN sessions.raw_path LIKE 'http://%' OR sessions.raw_path LIKE 'https://%'
                    THEN sessions.raw_path
                    ELSE excluded.raw_path
                END
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, lastActive, -1, SQLITE_TRANSIENT)
        if let rawPath {
            sqlite3_bind_text(stmt, 4, rawPath, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_step(stmt)
    }

    /// Upsert a ChatGPT session from the user's official ChatGPT data export.
    func upsertChatGPTExportSession(
        conversationId: String,
        title: String,
        lastActive: String,
        firstUserMessage: String?,
        rawPath: String
    ) {
        let sql = """
            INSERT INTO sessions(id, source, host_app, title, cwd, last_active, last_message, raw_path)
            VALUES(?, 'chatgpt', 'ChatGPT', ?, NULL, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                last_active = MAX(sessions.last_active, excluded.last_active),
                last_message = COALESCE(excluded.last_message, sessions.last_message),
                raw_path = COALESCE(sessions.raw_path, excluded.raw_path)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "chatgpt:\(conversationId)", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, lastActive, -1, SQLITE_TRANSIENT)
        if let firstUserMessage, !firstUserMessage.isEmpty {
            sqlite3_bind_text(stmt, 4, firstUserMessage, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_text(stmt, 5, "chatgpt-export:\(rawPath)", -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// Upsert a ChatGPT session observed from browser history.
    func upsertChatGPTBrowserSession(conversationId: String, title: String?, lastActive: String, url: String) {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = cleanTitle?.isEmpty == false ? cleanTitle! : "ChatGPT"

        let sql = """
            INSERT INTO sessions(id, source, host_app, title, cwd, last_active, last_message, raw_path)
            VALUES(?, 'chatgpt', 'ChatGPT', ?, NULL, ?, NULL, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = CASE
                    WHEN (
                        sessions.title IS NULL
                        OR sessions.title = ''
                        OR sessions.title = 'ChatGPT'
                        OR sessions.title LIKE 'ChatGPT · %'
                        OR sessions.title LIKE 'ChatGPT 桌面 · %'
                    )
                    THEN excluded.title
                    ELSE sessions.title
                END,
                last_active = MAX(sessions.last_active, excluded.last_active),
                raw_path = excluded.raw_path
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "chatgpt:\(conversationId)", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, displayTitle, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, lastActive, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, url, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// Upsert a ChatGPT title observed in the desktop app sidebar. The sidebar
    /// exposes titles but not conversation ids, so these rows use a stable title id.
    func upsertChatGPTSidebarTitle(_ title: String, lastActive: String, fallbackIndex: Int) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }

        if existingChatGPTId(title: cleanTitle) != nil {
            return
        }

        if let cacheId = untitledChatGPTCacheId(at: fallbackIndex) {
            execUpdate("UPDATE sessions SET title = ?, raw_path = COALESCE(raw_path, 'chatgpt-sidebar') WHERE id = ?") { stmt in
                sqlite3_bind_text(stmt, 1, cleanTitle, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, cacheId, -1, SQLITE_TRANSIENT)
            }
            return
        }

        let existingSidebarTime = existingSidebarLastActive(title: cleanTitle)
        let effectiveLastActive = existingSidebarTime ?? lastActive
        let sql = """
            INSERT INTO sessions(id, source, host_app, title, cwd, last_active, last_message, raw_path)
            VALUES(?, 'chatgpt', 'ChatGPT', ?, NULL, ?, NULL, 'chatgpt-sidebar')
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                last_active = sessions.last_active
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "chatgpt-ui:\(stableHash(cleanTitle))", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, cleanTitle, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, effectiveLastActive, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    private func untitledChatGPTCacheId(at index: Int) -> String? {
        let sql = """
            SELECT id
            FROM sessions
            WHERE source = 'chatgpt'
              AND raw_path LIKE '/Users/%/Library/Application Support/com.openai.chat/%'
              AND title_override IS NULL
              AND (
                title = 'ChatGPT'
                OR title LIKE 'ChatGPT · %'
                OR title LIKE 'ChatGPT 桌面 · %'
              )
            ORDER BY last_active DESC, id
            LIMIT 1 OFFSET ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(index))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return text(stmt, 0)
    }

    private func existingSidebarLastActive(title: String) -> String? {
        let sql = "SELECT last_active FROM sessions WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "chatgpt-ui:\(stableHash(title))", -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return text(stmt, 0)
    }

    func deleteChatGPTSidebarRows() {
        execUpdate("DELETE FROM sessions WHERE source = 'chatgpt' AND id LIKE 'chatgpt-ui:%'") { _ in }
    }

    func upsertChatGPTSidebarTitles(_ titles: [String]) {
        let cleanTitles = titles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanTitles.isEmpty else { return }

        deleteChatGPTSidebarRows()

        let cacheIds = untitledChatGPTCacheIds(limit: cleanTitles.count)
        var cacheIndex = 0
        for title in cleanTitles {
            if existingChatGPTId(title: title) != nil {
                continue
            }
            guard cacheIndex < cacheIds.count else {
                continue
            }
            let cacheId = cacheIds[cacheIndex]
            cacheIndex += 1
            execUpdate("UPDATE sessions SET title = ? WHERE id = ?") { stmt in
                sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, cacheId, -1, SQLITE_TRANSIENT)
            }
        }
    }

    private func untitledChatGPTCacheIds(limit: Int) -> [String] {
        let sql = """
            SELECT id
            FROM sessions
            WHERE source = 'chatgpt'
              AND raw_path LIKE '/Users/%/Library/Application Support/com.openai.chat/%'
              AND title_override IS NULL
              AND (
                title = 'ChatGPT'
                OR title LIKE 'ChatGPT · %'
                OR title LIKE 'ChatGPT 桌面 · %'
              )
            ORDER BY last_active DESC, id
            LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = text(stmt, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    private func execUpdate(_ sql: String, bind: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        sqlite3_step(stmt)
    }

    private func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func isoDaysAgo(_ days: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-days * 24 * 60 * 60))
    }

    private func existingChatGPTId(title: String) -> String? {
        let sql = """
            SELECT id
            FROM sessions
            WHERE source = 'chatgpt'
              AND title = ?
              AND id NOT LIKE 'chatgpt-ui:%'
            ORDER BY last_active DESC
            LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return text(stmt, 0)
    }

    private func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func tableColumns(_ table: String) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var columns = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = text(stmt, 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    private func migrate() {
        let sessionColumns = tableColumns("sessions")
        if !sessionColumns.contains("title_override") {
            sqlite3_exec(conn, "ALTER TABLE sessions ADD COLUMN title_override TEXT", nil, nil, nil)
        }
        if !sessionColumns.contains("hidden_at") {
            sqlite3_exec(conn, "ALTER TABLE sessions ADD COLUMN hidden_at TEXT", nil, nil, nil)
        }

        let taskColumns = tableColumns("tasks")
        if !taskColumns.contains("sort_order") {
            sqlite3_exec(conn, "ALTER TABLE tasks ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        }
        normalizeActiveTaskSortOrder()
    }

    private func newTopSortOrder() -> Int64 {
        var stmt: OpaquePointer?
        let sql = "SELECT MIN(sort_order) FROM tasks WHERE status = 'active'"
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
            return 0
        }
        return sqlite3_column_int64(stmt, 0) - 1000
    }

    private func activeTaskOrder() -> [(id: Int64, sortOrder: Int64)] {
        var rows: [(id: Int64, sortOrder: Int64)] = []
        var stmt: OpaquePointer?
        let sql = """
            SELECT id, sort_order
            FROM tasks
            WHERE status = 'active'
            ORDER BY sort_order ASC, updated_at DESC, id DESC
        """
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1)))
        }
        return rows
    }

    private func normalizeActiveTaskSortOrder() {
        for (index, task) in activeTaskOrder().enumerated() {
            let normalized = Int64(index * 1000)
            if task.sortOrder == normalized { continue }
            execUpdate("UPDATE tasks SET sort_order = ? WHERE id = ?") { stmt in
                sqlite3_bind_int64(stmt, 1, normalized)
                sqlite3_bind_int64(stmt, 2, task.id)
            }
        }
    }

    private func querySessions(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }) -> [SessionRow] {
        var items: [SessionRow] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(SessionRow(
                id: textOr(stmt, 0),
                source: textOr(stmt, 1),
                hostApp: text(stmt, 2),
                title: textOr(stmt, 3, "(no title)"),
                titleOverride: text(stmt, 4),
                cwd: text(stmt, 5),
                lastActive: textOr(stmt, 6),
                lastMessage: text(stmt, 7),
                rawPath: text(stmt, 8)
            ))
        }
        return items
    }

    func sessions(forTask taskId: Int64) -> [SessionRow] {
        let sql = """
            SELECT s.id, s.source, s.host_app, s.title, s.title_override, s.cwd, s.last_active, s.last_message, s.raw_path
            FROM sessions s
            JOIN session_task_links l ON l.session_id = s.id
            WHERE l.task_id = ?
              AND s.hidden_at IS NULL
              AND NOT (
                s.source = 'chatgpt'
                AND s.title_override IS NULL
                AND (
                    s.title = 'ChatGPT'
                    OR s.title LIKE 'ChatGPT · %'
                    OR s.title LIKE 'ChatGPT 桌面 · %'
                )
              )
            ORDER BY s.last_active DESC
        """
        return querySessions(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, taskId)
        }
    }

    func unlinkedSessions() -> [SessionRow] {
        let sql = """
            SELECT s.id, s.source, s.host_app, s.title, s.title_override, s.cwd, s.last_active, s.last_message, s.raw_path
            FROM sessions s
            LEFT JOIN session_task_links l ON l.session_id = s.id
            WHERE l.session_id IS NULL
              AND s.hidden_at IS NULL
              AND NOT (s.source = 'chatgpt' AND s.last_active < ?)
              AND NOT (
                s.source = 'chatgpt'
                AND s.title_override IS NULL
                AND (
                    s.title = 'ChatGPT'
                    OR s.title LIKE 'ChatGPT · %'
                    OR s.title LIKE 'ChatGPT 桌面 · %'
                )
              )
            ORDER BY s.last_active DESC
        """
        return querySessions(sql) { stmt in
            sqlite3_bind_text(stmt, 1, isoDaysAgo(7), -1, SQLITE_TRANSIENT)
        }
    }

    func notes(forTask taskId: Int64, limit: Int = 3) -> [NoteItem] {
        var items: [NoteItem] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, content, created_at FROM notes WHERE task_id = ? ORDER BY created_at DESC LIMIT ?"
        guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, taskId)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(NoteItem(
                id: sqlite3_column_int64(stmt, 0),
                content: textOr(stmt, 1),
                createdAt: textOr(stmt, 2)
            ))
        }
        return items
    }
}
