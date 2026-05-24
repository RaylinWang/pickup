import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum JumpHelper {
    @discardableResult
    static func openSession(_ session: SessionRow) -> Bool {
        let realId = String(session.id.split(separator: ":", maxSplits: 1).last ?? "")
        let host = session.hostApp ?? ""
        log("openSession source=\(session.source) host=\(host) sourceId=\(session.id) cwd=\(session.cwd ?? "nil") rawPath=\(session.rawPath ?? "nil")")

        if session.source == "claude_code" {
            if isTerminalHost(host) {
                let terminal = terminalConfig(for: host)
                openClaudeInTerminal(termAppName: terminal.appName, bundleId: terminal.bundleId,
                                     cwd: session.cwd, sessionId: realId)
                return true
            }
            return openClaudeCodeSession(sessionId: realId, cwd: session.cwd, preferredHost: host)
        }

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
            return openCodexSession(session, sessionId: realId)
        case "ChatGPT":
            return openChatGPTSession(session)
        case "Link":
            openLink(session.rawPath ?? session.lastMessage)
        default:
            log("unknown host, skipping")
            return false
        }
        return true
    }

    // MARK: - Terminal-based (Claude Code CLI)

    private static func openClaudeCodeSession(sessionId: String, cwd: String?, preferredHost: String) -> Bool {
        if let desktopSession = desktopClaudeSession(for: sessionId),
           openClaudeDesktopSession(desktopSession) {
            return true
        }

        let terminal = terminalPreference(preferredHost: preferredHost)
        openClaudeInTerminal(
            termAppName: terminal.appName,
            bundleId: terminal.bundleId,
            cwd: cwd,
            sessionId: sessionId
        )
        return true
    }

    // MARK: - Claude Desktop session lookup

    private struct DesktopClaudeSession: Decodable {
        let sessionId: String
        let cliSessionId: String?
        let title: String?
        let lastActivityAt: Double?
    }

    private static func desktopClaudeSession(for cliSessionId: String) -> DesktopClaudeSession? {
        let decoder = JSONDecoder()
        var matches: [DesktopClaudeSession] = []

        for file in claudeDesktopSessionFiles() {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(DesktopClaudeSession.self, from: data),
                  session.cliSessionId == cliSessionId
            else { continue }
            matches.append(session)
        }

        let selected = matches.max {
            ($0.lastActivityAt ?? 0) < ($1.lastActivityAt ?? 0)
        }

        if let selected {
            log("mapped Claude CLI session \(cliSessionId) -> desktop \(selected.sessionId) title=\(selected.title ?? "nil")")
        } else {
            log("no Claude Desktop mapping for CLI session \(cliSessionId)")
        }
        return selected
    }

    private static func claudeDesktopSessionFiles() -> [URL] {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }

        let roots = [
            appSupport.appendingPathComponent("Claude/claude-code-sessions"),
            appSupport.appendingPathComponent("Claude-3p/claude-code-sessions")
        ]

        return roots.flatMap { root -> [URL] in
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            var files: [URL] = []
            for case let file as URL in enumerator {
                guard file.lastPathComponent.hasPrefix("local_"),
                      file.pathExtension == "json"
                else { continue }
                files.append(file)
            }
            return files
        }
    }

    private static func openClaudeDesktopSession(_ session: DesktopClaudeSession) -> Bool {
        guard let query = session.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty
        else {
            log("Claude Desktop mapping has empty title for \(session.sessionId)")
            return false
        }

        let appPath = "/Applications/Claude.app"
        guard FileManager.default.fileExists(atPath: appPath) else {
            log("Claude.app not found, fallback to CLI")
            return false
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(query, forType: .string)
        log("clipboard set Claude Desktop search: \(query)")

        if !accessibilityGranted() {
            log("accessibility NOT granted for Claude Desktop search, prompting")
            promptAccessibility()
            return true
        }

        let appURL = URL(fileURLWithPath: appPath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, err in
            if let err {
                log("ERR launching Claude: \(err)")
                return
            }

            log("launched Claude, waiting for frontmost...")
            waitForFrontmost(bundleId: "com.anthropic.claudefordesktop", timeout: 3.0) { active in
                log("waitForClaudeFrontmost result=\(active)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard accessibilityGranted() else {
                        log("accessibility lost before Claude search")
                        return
                    }

                    sendKey(53) // Escape, closes popovers/search before starting.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if clickClaudeSessionElement(named: query) {
                            log("Claude Desktop visible session clicked for \(session.sessionId)")
                            return
                        }

                        guard pressClaudeSearchButton() else {
                            log("ERR Claude Search button not found")
                            showOpenUnavailable(
                                title: "没找到 Claude 的搜索按钮",
                                message: "Pickup 已经把 session 名称复制到剪贴板: \(query)\n\n你可以在 Claude 里点 Search 后粘贴搜索。"
                            )
                            return
                        }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            guard clickClaudeSearchField() else {
                                log("ERR Claude search field not found")
                                showOpenUnavailable(
                                    title: "没找到 Claude 的搜索输入框",
                                    message: "Pickup 已经把 session 名称复制到剪贴板: \(query)\n\n你可以在 Claude 里点 Search 后粘贴搜索。"
                                )
                                return
                            }

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                sendKey(0, flags: .maskCommand) // A
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                    sendKey(9, flags: .maskCommand) // V
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                                        if clickClaudeSessionElement(named: query) {
                                            log("Claude Desktop searched session clicked for \(session.sessionId)")
                                        } else {
                                            log("ERR Claude session result not found for \(session.sessionId) title=\(query)")
                                            showOpenUnavailable(
                                                title: "没找到对应的 Claude session",
                                                message: "Pickup 已经在 Claude 搜索了: \(query)\n\n如果 Claude 还没加载出结果,你可以稍等一下再点一次。"
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return true
    }

    private static func terminalPreference(preferredHost: String) -> (appName: String, bundleId: String) {
        let candidates: [(String, String)] = {
            switch preferredHost {
            case "Ghostty":
                return [terminalConfig(for: "Ghostty"), terminalConfig(for: "Terminal")]
            case "Terminal":
                return [terminalConfig(for: "Terminal"), terminalConfig(for: "Ghostty")]
            case "iTerm":
                return [terminalConfig(for: "iTerm"), terminalConfig(for: "Ghostty"), terminalConfig(for: "Terminal")]
            default:
                return [terminalConfig(for: "Ghostty"), terminalConfig(for: "Terminal"), terminalConfig(for: "iTerm")]
            }
        }()

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: terminalAppPath(candidate.0)) {
                return (candidate.0, candidate.1)
            }
        }
        return ("Terminal", "com.apple.Terminal")
    }

    private static func isTerminalHost(_ host: String) -> Bool {
        ["Ghostty", "Terminal", "iTerm"].contains(host)
    }

    private static func terminalConfig(for host: String) -> (appName: String, bundleId: String) {
        switch host {
        case "Terminal":
            return ("Terminal", "com.apple.Terminal")
        case "iTerm":
            return ("iTerm", "com.googlecode.iterm2")
        default:
            return ("Ghostty", "com.mitchellh.ghostty")
        }
    }

    private static func openClaudeInTerminal(termAppName: String, bundleId: String,
                                             cwd: String?, sessionId: String) {
        let workDir = cwd ?? NSHomeDirectory()
        let command = "claude --resume \(shellQuote(sessionId))"
        openCommandInTerminal(termAppName: termAppName, bundleId: bundleId, cwd: workDir, command: command)
    }

    private static func openCommandInTerminal(termAppName: String, bundleId: String,
                                              cwd: String, command: String) {
        let cmd = "cd \(shellQuote(cwd)) && \(command)"

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
        log("clipboard set: \(cmd)")

        let appPath = terminalAppPath(termAppName)
        guard FileManager.default.fileExists(atPath: appPath) else {
            log("ERR: \(appPath) not found")
            return
        }

        if termAppName == "Ghostty", openGhosttyCommand(cwd: cwd, command: command) {
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
            waitForFrontmost(bundleId: bundleId, timeout: 4.0) { active in
                log("waitForFrontmost result=\(active)")
                // small extra buffer so the new window is fully drawn + key window
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard accessibilityGranted() else {
                        log("accessibility still not granted, skipping keystrokes")
                        return
                    }
                    executeKeystrokes()
                }
            }
        }
    }

    private static func openGhosttyCommand(cwd: String, command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-na",
            "Ghostty.app",
            "--args",
            "--working-directory=\(cwd)",
            "--initial-command=\(command)"
        ]

        do {
            try process.run()
            log("launched Ghostty with initial-command cwd=\(cwd) command=\(command)")
            return true
        } catch {
            log("ERR launching Ghostty initial-command: \(error)")
            return false
        }
    }

    private static func terminalAppPath(_ termAppName: String) -> String {
        switch termAppName {
        case "Terminal":
            return "/System/Applications/Utilities/Terminal.app"
        default:
            return "/Applications/\(termAppName).app"
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
        sendKey(17, flags: .maskCommand) // T
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            sendKey(9, flags: .maskCommand) // V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                sendKey(36) // Return
                log("keystrokes sent OK")
            }
        }
    }

    private static func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Deep link (Claude.app / Codex / ChatGPT)

    private static func openCodexSession(_ session: SessionRow, sessionId: String) -> Bool {
        let codexCLI = "/Applications/Codex.app/Contents/Resources/codex"
        guard FileManager.default.fileExists(atPath: codexCLI) else {
            showOpenUnavailable(
                title: "没找到 Codex CLI",
                message: "Pickup 需要 Codex 自带的 CLI 才能精确恢复 session。"
            )
            return false
        }

        let workDir = session.cwd ?? NSHomeDirectory()
        let command = "\(shellQuote(codexCLI)) resume \(shellQuote(sessionId))"
        let terminal = terminalPreference(preferredHost: "Ghostty")
        openCommandInTerminal(
            termAppName: terminal.appName,
            bundleId: terminal.bundleId,
            cwd: workDir,
            command: command
        )
        log("openCodexSession resume id=\(sessionId) cwd=\(workDir)")
        return true
    }

    private static func openChatGPTSession(_ session: SessionRow) -> Bool {
        if let url = chatGPTConversationURL(from: session.rawPath)
            ?? chatGPTConversationURL(from: session.lastMessage) {
            openChatGPTURL(url)
            return true
        }

        copyToPasteboard(session.displayTitle)
        if openChatGPTDesktopSession(title: session.displayTitle) {
            return true
        }

        showOpenUnavailable(
            title: "这个 ChatGPT session 不能精确打开",
            message: """
            这条记录来自 ChatGPT 桌面端本地缓存,没有可验证的 chatgpt.com/c/... 链接,并且本机没有找到 ChatGPT.app。

            Pickup 已经把标题复制到剪贴板。你在浏览器里打开过这条对话后,Pickup 才能从浏览器历史里拿到可精确跳转的链接。
            """
        )
        log("ChatGPT session lacks verified URL id=\(session.id) rawPath=\(session.rawPath ?? "nil")")
        return false
    }

    private static func chatGPTConversationURL(from raw: String?) -> URL? {
        guard let raw,
              let url = URL(string: raw),
              let host = url.host?.lowercased(),
              host == "chatgpt.com" || host == "chat.openai.com"
        else { return nil }

        let parts = url.path.split(separator: "/").map(String.init)
        guard let cIndex = parts.firstIndex(of: "c"),
              parts.indices.contains(cIndex + 1),
              !parts[cIndex + 1].isEmpty
        else { return nil }
        return url
    }

    private static func openChatGPTURL(_ url: URL) {
        log("openChatGPTConversation \(url.absoluteString)")

        if NSWorkspace.shared.open(url) {
            log("opened ChatGPT URL in default browser")
        } else {
            log("failed opening ChatGPT URL")
        }
    }

    private static func openChatGPTDesktopSession(title: String) -> Bool {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }

        let appPath = "/Applications/ChatGPT.app"
        guard FileManager.default.fileExists(atPath: appPath) else {
            log("ChatGPT.app not found for desktop title fallback")
            return false
        }

        if !accessibilityGranted() {
            log("accessibility NOT granted for ChatGPT title fallback, prompting")
            promptAccessibility()
            return true
        }

        let appURL = URL(fileURLWithPath: appPath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, err in
            if let err {
                log("ERR launching ChatGPT: \(err)")
                return
            }

            log("launched ChatGPT, waiting for frontmost...")
            waitForFrontmost(bundleId: "com.openai.chat", timeout: 4.0) { active in
                log("waitForChatGPTFrontmost result=\(active)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    findChatGPTSession(named: query)
                }
            }
        }
        return true
    }

    private static func findChatGPTSession(named query: String) {
        if clickChatGPTSessionElement(named: query) {
            log("ChatGPT visible session clicked title=\(query)")
            return
        }

        guard pressChatGPTSearchButton() else {
            log("ERR ChatGPT Search button not found title=\(query)")
            showOpenUnavailable(
                title: "没找到 ChatGPT 的搜索入口",
                message: "Pickup 已经打开 ChatGPT,并把 session 标题复制到剪贴板: \(query)\n\n你可以在 ChatGPT 里搜索这个标题。"
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard clickChatGPTSearchField() else {
                log("ERR ChatGPT search field not found title=\(query)")
                showOpenUnavailable(
                    title: "没找到 ChatGPT 的搜索输入框",
                    message: "Pickup 已经把 session 标题复制到剪贴板: \(query)\n\n你可以在 ChatGPT 里手动搜索这个标题。"
                )
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                sendKey(0, flags: .maskCommand) // A
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    sendKey(9, flags: .maskCommand) // V
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        if clickChatGPTSessionElement(named: query) {
                            log("ChatGPT searched session clicked title=\(query)")
                        } else {
                            log("ERR ChatGPT session result not found title=\(query)")
                            showOpenUnavailable(
                                title: "没找到对应的 ChatGPT session",
                                message: "Pickup 已经在 ChatGPT 搜索了: \(query)\n\n如果结果还没加载出来,可以稍等一下再点一次。"
                            )
                        }
                    }
                }
            }
        }
    }

    private static func copyToPasteboard(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        log("clipboard set text: \(value)")
    }

    private static func shellQuote(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func showOpenUnavailable(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
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

    private static func clickChatGPTSessionElement(named title: String) -> Bool {
        guard let axApp = chatGPTAXApp() else { return false }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let result = findAXElement(axApp, maxDepth: 24, match: { element in
            let role = axString(element, kAXRoleAttribute) ?? ""
            let clickableRoles = ["AXButton", "AXStaticText", "AXRow", "AXCell", "AXGroup"]
            guard clickableRoles.contains(role),
                  axMatchesSessionTitle(element, title: trimmedTitle),
                  let frame = axFrame(element),
                  frame.height >= 18,
                  frame.height <= 90,
                  frame.width >= 80
            else { return false }
            return true
        })
        if let result {
            log("click ChatGPT session labels=\(axLabels(result, descendantDepth: 2).joined(separator: " | "))")
            return clickCenter(of: result)
        }

        return false
    }

    private static func clickChatGPTSearchField() -> Bool {
        guard let axApp = chatGPTAXApp() else { return false }
        guard let field = findAXElement(axApp, maxDepth: 24, match: { element in
            let role = axString(element, kAXRoleAttribute) ?? ""
            guard role == "AXTextArea" || role == "AXTextField" else { return false }
            let labels = axLabels(element, descendantDepth: 1)
            return labels.contains(where: { label in
                let lower = label.lowercased()
                return lower.contains("search") || label.contains("搜索")
            })
        }) else {
            return false
        }

        log("click ChatGPT search field labels=\(axLabels(field, descendantDepth: 1).joined(separator: " | "))")
        return clickCenter(of: field)
    }

    private static func pressChatGPTSearchButton() -> Bool {
        guard let axApp = chatGPTAXApp() else { return false }
        guard let button = findAXElement(axApp, maxDepth: 22, match: { element in
            guard axString(element, kAXRoleAttribute) == (kAXButtonRole as String) else {
                return false
            }

            let labels = axLabels(element, descendantDepth: 2)
            return labels.contains(where: { label in
                let lower = label.lowercased()
                return lower.contains("search") || label.contains("搜索")
            })
        }) else {
            return false
        }

        let err = AXUIElementPerformAction(button, kAXPressAction as CFString)
        log("AX press ChatGPT Search result=\(err.rawValue)")
        return err == .success
    }

    private static func chatGPTAXApp() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.chat"
        ).first else {
            log("ChatGPT is not running for AX")
            return nil
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private static func clickClaudeSessionElement(named title: String) -> Bool {
        guard let axApp = claudeAXApp() else { return false }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let button = findAXElement(axApp, maxDepth: 24, match: { element in
            axString(element, kAXRoleAttribute) == (kAXButtonRole as String)
                && axMatchesSessionTitle(element, title: trimmedTitle)
                && axFrame(element) != nil
        })
        if let button {
            log("click Claude session button labels=\(axLabels(button, descendantDepth: 2).joined(separator: " | "))")
            return clickCenter(of: button)
        }

        let result = findAXElement(axApp, maxDepth: 24, match: { element in
            let role = axString(element, kAXRoleAttribute) ?? ""
            let clickableRoles = ["AXStaticText", "AXRow", "AXCell", "AXGroup"]
            return clickableRoles.contains(role)
                && axMatchesSessionTitle(element, title: trimmedTitle)
                && axFrame(element) != nil
        })
        if let result {
            log("click Claude session result labels=\(axLabels(result, descendantDepth: 2).joined(separator: " | "))")
            return clickCenter(of: result)
        }

        return false
    }

    private static func clickClaudeSearchField() -> Bool {
        guard let axApp = claudeAXApp() else { return false }
        guard let field = findAXElement(axApp, maxDepth: 24, match: { element in
            let role = axString(element, kAXRoleAttribute) ?? ""
            guard role == "AXTextArea" || role == "AXTextField" else { return false }
            let labels = axLabels(element, descendantDepth: 1)
            return labels.contains("Search chats and projects")
                || labels.contains(where: { $0.lowercased().contains("search") })
        }) else {
            return false
        }

        log("click Claude search field labels=\(axLabels(field, descendantDepth: 1).joined(separator: " | "))")
        return clickCenter(of: field)
    }

    private static func pressClaudeSearchButton() -> Bool {
        guard let axApp = claudeAXApp() else { return false }
        guard let button = findAXElement(axApp, maxDepth: 22, match: { element in
            guard axString(element, kAXRoleAttribute) == (kAXButtonRole as String) else {
                return false
            }

            let labels = axLabels(element, descendantDepth: 2)
            return labels.contains("Search")
        }) else {
            return false
        }

        let err = AXUIElementPerformAction(button, kAXPressAction as CFString)
        log("AX press Claude Search result=\(err.rawValue)")
        return err == .success
    }

    private static func claudeAXApp() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.anthropic.claudefordesktop"
        ).first else {
            log("Claude is not running for AX")
            return nil
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private static func findAXElement(_ element: AXUIElement,
                                      maxDepth: Int,
                                      match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(element) {
            return element
        }
        guard maxDepth > 0 else { return nil }

        for child in axChildren(element).prefix(600) {
            if let found = findAXElement(child, maxDepth: maxDepth - 1, match: match) {
                return found
            }
        }
        return nil
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        axElementArray(element, kAXChildrenAttribute)
            + axElementArray(element, kAXWindowsAttribute)
    }

    private static func axElementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else {
            return []
        }
        return elements
    }

    private static func axLabels(_ element: AXUIElement, descendantDepth: Int) -> [String] {
        var labels = [
            axString(element, kAXTitleAttribute),
            axString(element, kAXDescriptionAttribute),
            axString(element, kAXValueAttribute)
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard descendantDepth > 0 else { return labels }
        for child in axChildren(element).prefix(20) {
            labels.append(contentsOf: axLabels(child, descendantDepth: descendantDepth - 1))
        }
        return labels
    }

    private static func axMatchesSessionTitle(_ element: AXUIElement, title: String) -> Bool {
        guard !title.isEmpty else { return false }
        let labels = axLabels(element, descendantDepth: 2)
        return labels.contains(title)
            || labels.contains("Idle \(title)")
            || labels.contains("Running \(title)")
            || labels.contains(where: { label in
                label == title
                    || label.hasPrefix("\(title) ")
                    || label.hasSuffix(" \(title)")
                    || label.contains(title)
            })
    }

    private static func clickCenter(of element: AXUIElement) -> Bool {
        guard let frame = axFrame(element) else { return false }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let source = CGEventSource(stateID: .hidSystemState)

        let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                           mouseCursorPosition: point, mouseButton: .left)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left)

        move?.post(tap: .cghidEventTap)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        let ok = move != nil && down != nil && up != nil
        log("clickCenter point=(\(Int(point.x)),\(Int(point.y))) ok=\(ok)")
        return ok
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = axPoint(element, kAXPositionAttribute),
              let size = axSize(element, kAXSizeAttribute),
              size.width > 1,
              size.height > 1
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else {
            return nil
        }

        if let string = value as? String {
            return string
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    private static func accessibilityGranted() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let opts = [key: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private static func promptAccessibility() {
        let alert = NSAlert()
        alert.messageText = "需要 Accessibility 权限"
        alert.informativeText = """
            Pickup 需要 Accessibility 权限,才能帮你自动打开终端,或在 Claude 里搜索并定位到对应 session。

            命令或 session 名称已经复制到剪贴板,你可以:
            1. 点「打开系统设置」,在「隐私与安全 > Accessibility」里勾选 Pickup
            2. 或先手动打开目标 App,再用 cmd+V 粘贴
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
