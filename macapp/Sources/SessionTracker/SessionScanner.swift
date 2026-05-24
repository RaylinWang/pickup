import Foundation

enum SessionScanner {
    static func scanNow() -> Bool {
        guard let cliURL = cliURL() else {
            log("scan skipped: cli.py not found")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", cliURL.path, "scan"]
        process.currentDirectoryURL = cliURL.deletingLastPathComponent()

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log("scan exit=\(process.terminationStatus) \(text)")
            return process.terminationStatus == 0
        } catch {
            log("scan failed: \(error)")
            return false
        }
    }

    private static func cliURL() -> URL? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("sessiontracker-cli")
            .appendingPathComponent("cli.py"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = url.appendingPathComponent("cli.py")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static let logPath = "/tmp/sessiontracker-scan.log"
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
