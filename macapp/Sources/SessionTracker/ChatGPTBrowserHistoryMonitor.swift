import Foundation
import SQLite3

final class ChatGPTBrowserHistoryMonitor {
    private var timer: Timer?
    private let interval: TimeInterval = 60.0

    func start() {
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
        Task.detached(priority: .utility) {
            let rows = BrowserHistoryScanner.scan()
            guard !rows.isEmpty else { return }
            await MainActor.run {
                guard let db = DB() else { return }
                for row in rows {
                    db.upsertChatGPTBrowserSession(
                        conversationId: row.conversationId,
                        title: row.title,
                        lastActive: row.lastActive,
                        url: row.url
                    )
                }
            }
        }
    }
}

private struct BrowserHistoryRow {
    let conversationId: String
    let title: String?
    let lastActive: String
    let url: String
}

private enum BrowserHistoryScanner {
    static func scan() -> [BrowserHistoryRow] {
        var bestById: [String: BrowserHistoryRow] = [:]
        for historyPath in historyDatabasePaths() {
            for row in scanHistoryDatabase(at: historyPath) {
                if let existing = bestById[row.conversationId] {
                    bestById[row.conversationId] = prefer(row, over: existing)
                } else {
                    bestById[row.conversationId] = row
                }
            }
        }
        return Array(bestById.values).sorted { $0.lastActive > $1.lastActive }
    }

    private static func historyDatabasePaths() -> [URL] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let roots = [
            "Dia/User Data",
            "Google/Chrome",
            "Arc/User Data",
            "BraveSoftware/Brave-Browser",
            "Microsoft Edge",
            "Chromium",
        ].compactMap { appSupport?.appendingPathComponent($0) }

        var results: [URL] = []
        for root in roots {
            results.append(contentsOf: findHistoryFiles(under: root))
        }
        return results
    }

    private static func findHistoryFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              )
        else { return [] }

        var files: [URL] = []
        let rootDepth = root.pathComponents.count
        for case let url as URL in enumerator {
            if url.pathComponents.count - rootDepth > 3 {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "History" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private static func scanHistoryDatabase(at sourceURL: URL) -> [BrowserHistoryRow] {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pickup-history-\(UUID().uuidString).sqlite")
        do {
            try FileManager.default.copyItem(at: sourceURL, to: tmpURL)
        } catch {
            return []
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        let cutoff = chromeTimestamp(for: Date().addingTimeInterval(-7 * 24 * 60 * 60))
        let sql = """
            SELECT url, title, last_visit_time
            FROM urls
            WHERE last_visit_time >= ?
              AND (
                url LIKE '%://chatgpt.com%/c/%'
                OR url LIKE '%://chat.openai.com%/c/%'
              )
            ORDER BY last_visit_time DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)

        let iso = ISO8601DateFormatter()
        var rows: [BrowserHistoryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let url = text(stmt, 0),
                  let conversationId = conversationId(from: url)
            else { continue }

            let timestamp = sqlite3_column_int64(stmt, 2)
            let lastActive = iso.string(from: chromeDate(timestamp))
            rows.append(BrowserHistoryRow(
                conversationId: conversationId,
                title: cleanTitle(text(stmt, 1)),
                lastActive: lastActive,
                url: url
            ))
        }
        return rows
    }

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: ptr)
    }

    private static func conversationId(from rawURL: String) -> String? {
        guard let components = URLComponents(string: rawURL),
              let host = components.host?.lowercased(),
              host == "chatgpt.com" || host == "chat.openai.com"
        else { return nil }

        let parts = components.path.split(separator: "/").map(String.init)
        guard let cIndex = parts.firstIndex(of: "c"),
              parts.indices.contains(cIndex + 1)
        else { return nil }

        let id = parts[cIndex + 1]
        return id.isEmpty ? nil : id
    }

    private static func cleanTitle(_ title: String?) -> String? {
        guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }

        for suffix in [" - ChatGPT", " | ChatGPT"] where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title.isEmpty ? nil : title
    }

    private static func chromeDate(_ value: Int64) -> Date {
        let unixSeconds = (Double(value) / 1_000_000.0) - 11_644_473_600.0
        return Date(timeIntervalSince1970: unixSeconds)
    }

    private static func chromeTimestamp(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600.0) * 1_000_000.0)
    }

    private static func prefer(_ lhs: BrowserHistoryRow, over rhs: BrowserHistoryRow) -> BrowserHistoryRow {
        if lhs.lastActive != rhs.lastActive {
            return lhs.lastActive > rhs.lastActive ? lhs : rhs
        }
        if lhs.title != nil && rhs.title == nil {
            return lhs
        }
        return rhs
    }
}
