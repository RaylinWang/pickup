import Foundation
import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    struct TaskBundle: Identifiable {
        let task: TaskItem
        let sessions: [SessionRow]
        let notes: [NoteItem]
        var id: Int64 { task.id }
    }

    @Published var bundles: [TaskBundle] = []
    @Published var archivedTasks: [TaskItem] = []
    @Published var unlinked: [SessionRow] = []
    @Published var lastRefresh = Date()

    private var timer: Timer?
    private var scanTimer: Timer?
    private var scanInFlight = false

    init() {
        runBackgroundScan()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runBackgroundScan() }
        }
    }

    deinit {
        timer?.invalidate()
        scanTimer?.invalidate()
    }

    @discardableResult
    func createTask(name: String) -> Int64? {
        guard let db = DB() else { return nil }
        let id = db.createTask(name: name)
        reload()
        return id
    }

    func updateTaskName(_ id: Int64, name: String) {
        guard let db = DB() else { return }
        db.updateTaskName(id: id, name: name)
        reload()
    }

    func updateTaskDescription(_ id: Int64, description: String) {
        guard let db = DB() else { return }
        db.updateTaskDescription(id: id, description: description)
        reload()
    }

    func deleteTask(_ id: Int64) {
        guard let db = DB() else { return }
        db.deleteTask(id: id)
        reload()
    }

    func archiveTask(_ id: Int64) {
        guard let db = DB() else { return }
        db.archiveTask(id: id)
        reload()
    }

    func restoreTask(_ id: Int64) {
        guard let db = DB() else { return }
        db.restoreTask(id: id)
        reload()
    }

    func moveTaskUp(_ id: Int64) {
        guard let db = DB() else { return }
        db.moveTask(id: id, offset: -1)
        reload()
    }

    func moveTaskDown(_ id: Int64) {
        guard let db = DB() else { return }
        db.moveTask(id: id, offset: 1)
        reload()
    }

    @discardableResult
    func addLink(toTaskId taskId: Int64, title: String, url: String) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              let normalizedURL = normalizeURL(url),
              let db = DB()
        else { return false }
        _ = db.createLinkSession(title: trimmedTitle, url: normalizedURL, taskId: taskId)
        reload()
        return true
    }

    /// Assign a session to a task. Removes existing links first (UI is 1-to-many).
    func assignSession(_ sessionId: String, toTaskId taskId: Int64) {
        guard let db = DB() else { return }
        db.unlinkSessionFromAllTasks(sessionId)
        db.linkSession(sessionId, toTask: taskId)
        reload()
    }

    func unassignSession(_ sessionId: String) {
        guard let db = DB() else { return }
        db.unlinkSessionFromAllTasks(sessionId)
        reload()
    }

    func hideSession(_ sessionId: String) {
        guard let db = DB() else { return }
        db.hideSession(sessionId)
        reload()
    }

    func restoreHiddenAndReload() {
        guard let db = DB() else {
            reload()
            return
        }
        db.restoreHiddenSessions()
        runBackgroundScan()
    }

    func deleteManualLink(_ sessionId: String) {
        guard sessionId.hasPrefix("link:"), let db = DB() else { return }
        db.deleteSession(sessionId)
        reload()
    }

    func renameSession(_ sessionId: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = DB() else { return }
        db.updateSessionTitle(sessionId, title: trimmed)
        reload()
    }

    func importChatGPTExport(from url: URL) throws -> ChatGPTImportResult {
        guard let db = DB() else {
            return ChatGPTImportResult(imported: 0, withFirstUserMessage: 0)
        }
        let rows = try ChatGPTExportImporter.load(from: url)
        for row in rows {
            db.upsertChatGPTExportSession(
                conversationId: row.conversationId,
                title: row.title,
                lastActive: row.lastActive,
                firstUserMessage: row.firstUserMessage,
                rawPath: url.path
            )
        }
        reload()
        return ChatGPTImportResult(
            imported: rows.count,
            withFirstUserMessage: rows.filter { $0.firstUserMessage?.isEmpty == false }.count
        )
    }

    func reload() {
        guard let db = DB() else {
            bundles = []
            archivedTasks = []
            unlinked = []
            return
        }
        let tasks = db.activeTasks()
        bundles = tasks.map { t in
            TaskBundle(
                task: t,
                sessions: db.sessions(forTask: t.id),
                notes: db.notes(forTask: t.id)
            )
        }
        archivedTasks = db.archivedTasks()
        unlinked = db.unlinkedSessions()
        lastRefresh = Date()
    }

    private func runBackgroundScan() {
        guard !scanInFlight else {
            reload()
            return
        }
        scanInFlight = true
        Task.detached(priority: .utility) {
            _ = SessionScanner.scanNow()
            await MainActor.run {
                self.scanInFlight = false
                self.reload()
            }
        }
    }

    private func normalizeURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              let url = components.url
        else { return nil }
        return url.absoluteString
    }
}
