import AppKit
import ApplicationServices
import Foundation

enum JumpHelper {
    @discardableResult
    static func openSession(_ session: SessionRow) -> Bool {
        let realId = String(session.id.split(separator: ":", maxSplits: 1).last ?? "")
        let host = session.hostApp ?? ""
        log("openSession host=\(host) sourceId=\(session.id) cwd=\(session.cwd ?? "nil")")
        switch host {
        case "Ghostty":
            openClaudeInTerminal(termAppName: "Ghostty", bundleId: "com.mitchellh.ghostty",
                                 cwd: session.cwd, sessionId: realId)
        case "Terminal":
            openClaudeInTerminal(termAppName: "Terminal", bundleId: "com.apple.Terminal",
                                 cwd: session.cwd, sessionId: realId)
        case "iTerm":
            openClaudeInTerminal(termAppName: "iTerm", bundleId: "com.googlecode.iterm2",
                                 cwd: session.cwd, sessionId: realId)
        case "Claude":
            openDeepLink(scheme: "claude", path: realId, appName: "Claude")
        case "Codex":
            openDeepLink(scheme: "codex", path: realId, appName: "Codex")
        case "ChatGPT":
            openChatGPTConversation(realId)
        case "Link":
            openLink(session.rawPath ?? session.lastMessage)
        default:
            log("unknown host, skipping")
            return false
        }
        return true
    }

    // MARK: - Terminal-based (Claude Code CLI)

    private static func openClaudeInTerminal(termAppName: String, bundleId: String,
                                             cwd: String?, sessionId: String) {
        let workDir = cwd ?? NSHomeDirectory()
        let cmd = "cd \"\(workDir)\" && claude --resume \(sessionId)"

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
        log("clipboard set: \(cmd)")

        let appPath = "/Applications/\(termAppName).app"
        guard FileManager.default.fileExists(atPath: appPath) else {
            log("ERR: \(appPath) not found")
            return
        }

        if !accessibilityGranted() {
            log("accessibility NOT granted, prompting")
            promptAccessibility()
        }

        let appURL = URL(fileURLWithPath: appPath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, err in
            if let err {
                log("ERR launching \(termAppName): \(err)")
                return
            }
            log("launched \(termAppName), waiting for frontmost…")
            waitForFrontmost(bundleId: bundleId, timeout: 2.5) { active in
                log("waitForFrontmost result=\(active)")
                // small extra buffer so the new window is fully drawn + key window
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    guard accessibilityGranted() else {
                        log("accessibility still not granted, skipping keystrokes")
                        return
                    }
                    executeKeystrokes()
                }
            }
        }
    }

    private static func waitForFrontmost(bundleId: String, timeout: TimeInterval,
                                         completion: @escaping (Bool) -> Void) {
        let start = Date()
        func tick() {
            let frontId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if frontId == bundleId {
                completion(true)
                return
            }
            if Date().timeIntervalSince(start) >= timeout {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: tick)
        }
        tick()
    }

    private static func executeKeystrokes() {
        // Generous delays — Ghostty new tab + paste need time to settle.
        let script = """
            tell application "System Events"
                keystroke "t" using {command down}
                delay 0.45
                keystroke "v" using {command down}
                delay 0.25
                keystroke return
            end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            log("ERR keystrokes: \(err)")
        } else {
            log("keystrokes sent OK")
        }
    }

    // MARK: - Deep link (Claude.app / Codex / ChatGPT)

    private static func openChatGPTConversation(_ conversationId: String) {
        guard let url = URL(string: "https://chatgpt.com/c/\(conversationId)") else {
            openDeepLink(scheme: "chatgpt", path: "", appName: "ChatGPT")
            return
        }
        log("openChatGPTConversation \(url.absoluteString)")

        let appPath = "/Applications/ChatGPT.app"
        if FileManager.default.fileExists(atPath: appPath) {
            let appURL = URL(fileURLWithPath: appPath)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: config
            ) { _, err in
                if let err {
                    log("ERR opening ChatGPT URL in app: \(err)")
                    NSWorkspace.shared.open(url)
                } else {
                    log("opened ChatGPT URL in app")
                }
            }
            return
        }

        if NSWorkspace.shared.open(url) {
            log("opened ChatGPT URL in default browser")
        } else {
            log("failed opening ChatGPT URL")
        }
    }

    private static func openDeepLink(scheme: String, path: String, appName: String) {
        let urlStr = "\(scheme)://\(path)"
        log("openDeepLink \(urlStr)")
        if let url = URL(string: urlStr), NSWorkspace.shared.open(url) {
            log("NSWorkspace.open returned true for \(urlStr)")
            return
        }
        log("NSWorkspace.open failed, fallback to opening \(appName).app")
        let appPath = "/Applications/\(appName).app"
        guard FileManager.default.fileExists(atPath: appPath) else { return }
        let appURL = URL(fileURLWithPath: appPath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: { _, _ in })
    }

    private static func openLink(_ rawURL: String?) {
        guard let rawURL,
              let url = URL(string: rawURL),
              NSWorkspace.shared.open(url)
        else {
            log("failed opening link \(rawURL ?? "nil")")
            return
        }
        log("opened link \(url.absoluteString)")
    }

    // MARK: - Accessibility

    private static func accessibilityGranted() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let opts = [key: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private static func promptAccessibility() {
        let alert = NSAlert()
        alert.messageText = "需要 Accessibility 权限"
        alert.informativeText = """
            SessionTracker 需要 Accessibility 权限,才能在终端里自动开新 tab、粘贴并执行 claude --resume 命令。

            命令已经复制到剪贴板,你可以:
            1. 点「打开系统设置」,在「隐私与安全 > Accessibility」里勾选 SessionTracker
            2. 或先用 cmd+V 在终端里手动粘贴运行
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "我自己粘贴")
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Logging

    private static let logPath = "/tmp/sessiontracker-jump.log"
    private static func log(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
}
