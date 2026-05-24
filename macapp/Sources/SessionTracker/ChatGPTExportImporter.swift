import Foundation

struct ImportedChatGPTConversation {
    let conversationId: String
    let title: String
    let lastActive: String
    let firstUserMessage: String?
}

struct ChatGPTImportResult {
    let imported: Int
    let withFirstUserMessage: Int
}

enum ChatGPTExportImportError: LocalizedError {
    case invalidTopLevel

    var errorDescription: String? {
        switch self {
        case .invalidTopLevel:
            return "这个文件不像 ChatGPT 的 conversations.json"
        }
    }
}

enum ChatGPTExportImporter {
    private struct ExtractedMessage {
        let role: String
        let text: String
        let createdAt: Double?
        let order: Int
    }

    static func load(from url: URL) throws -> [ImportedChatGPTConversation] {
        let data = try Data(contentsOf: url)
        return try load(from: data)
    }

    static func load(from data: Data) throws -> [ImportedChatGPTConversation] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let conversations = object as? [[String: Any]] else {
            throw ChatGPTExportImportError.invalidTopLevel
        }
        return conversations.compactMap(parseConversation)
    }

    private static func parseConversation(_ conversation: [String: Any]) -> ImportedChatGPTConversation? {
        guard let id = stringValue(conversation["id"] ?? conversation["conversation_id"]) else {
            return nil
        }

        let messages = extractedMessages(from: conversation)
        let firstUserMessage = messages
            .filter { $0.role == "user" && !$0.text.isEmpty }
            .sorted(by: messageSort)
            .first
            .map { summarize($0.text, limit: 220) }

        let exportedTitle = stringValue(conversation["title"])
        let title: String
        if let exportedTitle,
           !exportedTitle.isEmpty,
           exportedTitle.lowercased() != "new chat" {
            title = summarize(exportedTitle, limit: 120)
        } else if let firstUserMessage, !firstUserMessage.isEmpty {
            title = summarize(firstUserMessage, limit: 80)
        } else {
            title = "ChatGPT"
        }

        let timestamp = numericValue(conversation["update_time"])
            ?? numericValue(conversation["create_time"])
            ?? messages.compactMap(\.createdAt).max()
            ?? Date().timeIntervalSince1970

        return ImportedChatGPTConversation(
            conversationId: id,
            title: title,
            lastActive: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: timestamp)),
            firstUserMessage: firstUserMessage
        )
    }

    private static func extractedMessages(from conversation: [String: Any]) -> [ExtractedMessage] {
        guard let mapping = conversation["mapping"] as? [String: Any] else {
            return []
        }

        var messages: [ExtractedMessage] = []
        for (index, value) in mapping.values.enumerated() {
            guard let node = value as? [String: Any],
                  let message = node["message"] as? [String: Any],
                  let author = message["author"] as? [String: Any],
                  let role = stringValue(author["role"]),
                  !isHidden(message)
            else { continue }

            let text = contentText(from: message)
            guard !text.isEmpty else { continue }
            messages.append(ExtractedMessage(
                role: role,
                text: text,
                createdAt: numericValue(message["create_time"]),
                order: index
            ))
        }
        return messages
    }

    private static func contentText(from message: [String: Any]) -> String {
        guard let content = message["content"] as? [String: Any] else {
            return stringValue(message["text"]) ?? ""
        }

        if let parts = content["parts"] as? [Any] {
            let text = parts.compactMap(partText).joined(separator: "\n")
            if !text.isEmpty { return normalizeWhitespace(text) }
        }

        for key in ["text", "result", "content"] {
            if let text = stringValue(content[key]), !text.isEmpty {
                return normalizeWhitespace(text)
            }
        }
        return ""
    }

    private static func partText(_ part: Any) -> String? {
        if let text = stringValue(part) {
            return text
        }
        guard let dict = part as? [String: Any] else {
            return nil
        }
        for key in ["text", "content", "caption"] {
            if let text = stringValue(dict[key]), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func isHidden(_ message: [String: Any]) -> Bool {
        guard let metadata = message["metadata"] as? [String: Any] else {
            return false
        }
        return boolValue(metadata["is_visually_hidden_from_conversation"]) == true
            || boolValue(metadata["is_hidden_from_conversation"]) == true
    }

    private static func messageSort(_ lhs: ExtractedMessage, _ rhs: ExtractedMessage) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (l?, r?) where l != r:
            return l < r
        default:
            return lhs.order < rhs.order
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = normalizeWhitespace(string)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private static func summarize(_ text: String, limit: Int) -> String {
        let cleaned = normalizeWhitespace(text)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
