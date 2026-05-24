import Foundation

struct ChatGPTExportCandidate {
    let key: String
    let path: String
    let modifiedAt: Date
    let data: Data
}

enum ChatGPTExportAutoImporter {
    static func candidates() -> [ChatGPTExportCandidate] {
        let roots = [
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
        ].compactMap { $0 }

        var candidates: [ChatGPTExportCandidate] = []
        for root in roots {
            candidates.append(contentsOf: jsonCandidates(under: root))
            candidates.append(contentsOf: zipCandidates(under: root))
        }

        var seen = Set<String>()
        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .filter { candidate in
                if seen.contains(candidate.key) { return false }
                seen.insert(candidate.key)
                return true
            }
    }

    private static func jsonCandidates(under root: URL) -> [ChatGPTExportCandidate] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [ChatGPTExportCandidate] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "conversations.json" else { continue }
            guard looksLikeChatGPTExportPath(url) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  plausibleSize(values.fileSize)
            else { continue }

            do {
                results.append(ChatGPTExportCandidate(
                    key: fileKey(url),
                    path: url.path,
                    modifiedAt: values.contentModificationDate ?? Date.distantPast,
                    data: try Data(contentsOf: url)
                ))
            } catch {
                continue
            }
        }
        return results
    }

    private static func zipCandidates(under root: URL) -> [ChatGPTExportCandidate] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [ChatGPTExportCandidate] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "zip" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  plausibleSize(values.fileSize)
            else { continue }
            guard let entry = conversationsEntry(inZipAt: url),
                  let data = unzipEntry(entry, inZipAt: url)
            else { continue }

            results.append(ChatGPTExportCandidate(
                key: "\(fileKey(url))#\(entry)",
                path: "\(url.path)#\(entry)",
                modifiedAt: values.contentModificationDate ?? Date.distantPast,
                data: data
            ))
        }
        return results
    }

    private static func conversationsEntry(inZipAt url: URL) -> String? {
        guard let output = run("/usr/bin/unzip", arguments: ["-Z1", url.path]),
              let text = String(data: output, encoding: .utf8)
        else { return nil }
        return text
            .split(separator: "\n")
            .map(String.init)
            .first { $0 == "conversations.json" || $0.hasSuffix("/conversations.json") }
    }

    private static func unzipEntry(_ entry: String, inZipAt url: URL) -> Data? {
        run("/usr/bin/unzip", arguments: ["-p", url.path, entry], maxBytes: 200 * 1024 * 1024)
    }

    private static func run(_ launchPath: String, arguments: [String], maxBytes: Int = 20 * 1024 * 1024) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= maxBytes else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private static func looksLikeChatGPTExportPath(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("chatgpt")
            || path.contains("openai")
            || path.contains("data export")
            || url.lastPathComponent == "conversations.json"
    }

    private static func plausibleSize(_ size: Int?) -> Bool {
        guard let size else { return true }
        return size > 100 && size < 500 * 1024 * 1024
    }

    private static func fileKey(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(url.path)|\(Int(modified))|\(size)"
    }
}
