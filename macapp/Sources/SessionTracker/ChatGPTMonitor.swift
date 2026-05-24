import AppKit
import ApplicationServices
import Foundation

/// Polls ChatGPT's local conversation cache. The .data payloads are encrypted,
/// but the file names are stable conversation ids and mtimes give activity.
final class ChatGPTMonitor {
    private var timer: Timer?
    private let bundleId = "com.openai.chat"
    private let interval: TimeInterval = 30.0

    func start() {
        log("monitor start (interval=\(interval)s)")
        check()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let axOK = AXIsProcessTrusted()
        log("tick — ax=\(axOK)")
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId).first
        if let running {
            log("  → ChatGPT running pid=\(running.processIdentifier)")
        } else {
            log("  → ChatGPT.app not running; scanning cache anyway")
        }

        let rows = scanLocalConversations()
        guard !rows.isEmpty else {
            log("  → no local conversations found")
            return
        }
        guard let db = DB() else {
            log("  → DB unavailable")
            return
        }
        for row in rows {
            db.upsertChatGPTSession(
                id: "chatgpt:\(row.conversationId)",
                title: row.title,
                lastActive: row.lastActive,
                rawPath: row.path
            )
        }
        log("  → upserted local conversations: \(rows.count)")
    }

    private struct LocalConversation {
        let conversationId: String
        let title: String
        let lastActive: String
        let path: String
    }

    private func scanLocalConversations() -> [LocalConversation] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.openai.chat")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let iso = ISO8601DateFormatter()
        let titleDate = DateFormatter()
        titleDate.locale = Locale(identifier: "en_US_POSIX")
        titleDate.dateFormat = "MM-dd HH:mm"
        var rows: [LocalConversation] = []
        var seen = Set<String>()
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        for case let url as URL in enumerator {
            guard url.pathExtension == "data",
                  url.deletingLastPathComponent().lastPathComponent.hasPrefix("conversations-v3-")
            else { continue }

            let conversationId = url.deletingPathExtension().lastPathComponent
            guard !conversationId.isEmpty, !seen.contains(conversationId) else { continue }

            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
            ])
            guard values?.isRegularFile == true else { continue }

            let modified = values?.contentModificationDate ?? Date.distantPast
            guard modified >= cutoff else { continue }

            seen.insert(conversationId)
            rows.append(LocalConversation(
                conversationId: conversationId,
                title: "ChatGPT 桌面 · \(titleDate.string(from: modified))",
                lastActive: iso.string(from: modified),
                path: url.path
            ))
        }
        return rows.sorted { $0.lastActive > $1.lastActive }
    }

    private static let logPath = "/tmp/sessiontracker-chatgpt.log"
    private func log(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: Self.logPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: Self.logPath))
        }
    }
}
