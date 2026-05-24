import AppKit
import ApplicationServices
import Foundation

final class ChatGPTSidebarMonitor {
    private var timer: Timer?
    private let bundleId = "com.openai.chat"
    private let interval: TimeInterval = 45.0

    func start() {
        requestAccessibilityIfNeeded()
        check()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func check() {
        guard AXIsProcessTrusted() else {
            log("sidebar skipped: accessibility not trusted")
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            log("sidebar skipped: ChatGPT not running")
            return
        }

        let titles = sidebarTitles(pid: app.processIdentifier)
        guard !titles.isEmpty else {
            log("sidebar found no titles")
            return
        }

        guard let db = DB() else {
            log("sidebar skipped: DB unavailable")
            return
        }
        db.upsertChatGPTSidebarTitles(titles)
        log("sidebar upserted titles: \(titles.count)")
    }

    private func sidebarTitles(pid: pid_t) -> [String] {
        let appElement = AXUIElementCreateApplication(pid)
        guard let windows = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else {
            return []
        }

        var titles: [PositionedTitle] = []
        for window in windows {
            guard let frame = frame(of: window), frame.width > 100, frame.height > 100 else {
                continue
            }
            let sidebarMaxX = frame.minX + min(460, max(280, frame.width * 0.38))
            collectTitles(
                from: window,
                windowFrame: frame,
                sidebarMaxX: sidebarMaxX,
                depth: 0,
                into: &titles
            )
        }

        var seen = Set<String>()
        return titles
            .sorted { lhs, rhs in
                if abs(lhs.midY - rhs.midY) > 2 {
                    return lhs.midY < rhs.midY
                }
                return lhs.midX < rhs.midX
            }
            .compactMap { item in
                guard !seen.contains(item.title) else { return nil }
                seen.insert(item.title)
                return item.title
            }
    }

    private func collectTitles(
        from element: AXUIElement,
        windowFrame: CGRect,
        sidebarMaxX: CGFloat,
        depth: Int,
        into titles: inout [PositionedTitle]
    ) {
        guard depth <= 12 else { return }

        if let text = elementText(element), isConversationTitle(text),
           let frame = frame(of: element),
           frame.midX >= windowFrame.minX,
           frame.midX <= sidebarMaxX,
           frame.midY >= windowFrame.minY + 40,
           frame.midY <= windowFrame.maxY - 20 {
            titles.append(PositionedTitle(title: text, midX: frame.midX, midY: frame.midY))
        }

        guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return
        }
        for child in children {
            collectTitles(
                from: child,
                windowFrame: windowFrame,
                sidebarMaxX: sidebarMaxX,
                depth: depth + 1,
                into: &titles
            )
        }
    }

    private func elementText(_ element: AXUIElement) -> String? {
        for key in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            if let value = attribute(element, key) as? String {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    private func isConversationTitle(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 90 else { return false }
        guard !trimmed.contains("\n") else { return false }

        let blocked: Set<String> = [
            "ChatGPT",
            "New chat",
            "Search chats",
            "Search",
            "Library",
            "Explore GPTs",
            "Settings",
            "GPT",
            "Projects",
            "Recents",
            "Today",
            "Yesterday",
            "Previous 7 Days",
            "Previous 30 Days",
            "Upgrade plan",
            "新聊天",
            "搜索聊天",
            "搜索",
            "库",
            "设置",
            "项目",
            "新建项目",
            "视频插图",
            "封面制作",
            "最近",
            "附件",
            "代理",
            "今天",
            "昨天",
            "前 7 天",
            "前 30 天",
        ]
        if blocked.contains(trimmed) { return false }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("message ")
            || lower.hasPrefix("ask anything")
            || lower.hasPrefix("thought for ")
            || lower.hasSuffix(" thinking") {
            return false
        }
        return true
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> Any? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionAny = attribute(element, kAXPositionAttribute),
              let sizeAny = attribute(element, kAXSizeAttribute),
              CFGetTypeID(positionAny as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeAny as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        let positionValue = positionAny as! AXValue
        let sizeValue = sizeAny as! AXValue

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    private struct PositionedTitle {
        let title: String
        let midX: CGFloat
        let midY: CGFloat
    }

    private static let logPath = "/tmp/sessiontracker-chatgpt-sidebar.log"
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
