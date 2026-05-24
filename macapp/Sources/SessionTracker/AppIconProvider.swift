import AppKit
import Foundation

enum AppIconProvider {
    private static var cache: [String: NSImage] = [:]

    static func icon(forHost host: String) -> NSImage? {
        if let cached = cache[host] { return cached }
        guard let path = appPath(for: host),
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[host] = image
        return image
    }

    private static func appPath(for host: String) -> String? {
        switch host {
        case "Claude": return "/Applications/Claude.app"
        case "Codex": return "/Applications/Codex.app"
        case "ChatGPT": return "/Applications/ChatGPT.app"
        case "Ghostty": return "/Applications/Ghostty.app"
        case "iTerm": return "/Applications/iTerm.app"
        case "Terminal": return "/System/Applications/Utilities/Terminal.app"
        default: return nil
        }
    }
}
