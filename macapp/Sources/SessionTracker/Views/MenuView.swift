import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.bundles.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(store.bundles.enumerated()), id: \.element.id) { idx, bundle in
                            TaskSection(bundle: bundle, store: store)
                            if idx < store.bundles.count - 1 {
                                Divider().padding(.horizontal, 16)
                            }
                        }
                    }
                    if !store.unlinked.isEmpty {
                        Divider().padding(.horizontal, 16)
                        UnlinkedSection(sessions: store.unlinked, store: store)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 380, height: 540)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Sessions")
                .font(.system(.headline, design: .default))
            Spacer()
            Button {
                store.createTask(name: defaultNewProjectName())
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("新建项目")
            Button {
                store.restoreHiddenAndReload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("恢复隐藏并刷新")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("退出 SessionTracker")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有项目")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("点击右上角 + 新建项目")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func defaultNewProjectName() -> String {
        let existing = Set(store.bundles.map { $0.task.name })
        var i = 1
        while existing.contains("新项目 \(i)") { i += 1 }
        return "新项目 \(i)"
    }
}

private struct TaskSection: View {
    let bundle: SessionStore.TaskBundle
    @ObservedObject var store: SessionStore

    @State private var editedName: String = ""
    @State private var editedDescription: String = ""
    @FocusState private var focused: Field?

    enum Field: Hashable { case name, description }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("项目名", text: $editedName)
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline, design: .default).weight(.semibold))
                    .focused($focused, equals: .name)
                    .onSubmit { commitName(); focused = nil }
                Spacer(minLength: 6)
                ForEach(uniquePlatforms, id: \.self) { host in
                    HostIcon(host: host, size: 12)
                }
                Menu {
                    Button {
                        focused = .name
                    } label: {
                        Label("编辑名称", systemImage: "pencil")
                    }
                    Button {
                        focused = .description
                    } label: {
                        Label("编辑概述", systemImage: "text.alignleft")
                    }
                    Button {
                        promptAddLink()
                    } label: {
                        Label("添加链接", systemImage: "link")
                    }
                    Divider()
                    Button(role: .destructive) {
                        store.deleteTask(bundle.task.id)
                    } label: {
                        Label("删除项目", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            TextField("添加概述...", text: $editedDescription, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1...4)
                .focused($focused, equals: .description)
                .onSubmit { commitDescription(); focused = nil }

            if bundle.sessions.isEmpty {
                Text("从下面「其他 session」点 ⋯ 添加进来,或在项目菜单添加链接")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            } else {
                ForEach(bundle.sessions) { s in
                    SessionMiniRow(session: s, currentTaskId: bundle.task.id, store: store)
                }
            }

            ForEach(bundle.notes) { n in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                    Text(n.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear {
            editedName = bundle.task.name
            editedDescription = bundle.task.description
        }
        .onChange(of: bundle.task.name) { _, new in
            if focused != .name { editedName = new }
        }
        .onChange(of: bundle.task.description) { _, new in
            if focused != .description { editedDescription = new }
        }
        .onChange(of: focused) { old, new in
            if old == .name && new != .name { commitName() }
            if old == .description && new != .description { commitDescription() }
        }
    }

    private func commitName() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            editedName = bundle.task.name
            return
        }
        if trimmed != bundle.task.name {
            store.updateTaskName(bundle.task.id, name: trimmed)
        }
    }

    private func commitDescription() {
        if editedDescription != bundle.task.description {
            store.updateTaskDescription(bundle.task.id, description: editedDescription)
        }
    }

    private func promptAddLink() {
        let alert = NSAlert()
        alert.messageText = "添加链接"
        alert.informativeText = "保存到「\(bundle.task.name)」"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")

        let titleField = NSTextField(frame: NSRect(x: 58, y: 48, width: 340, height: 24))
        titleField.placeholderString = "飞书需求文档"

        let urlField = NSTextField(frame: NSRect(x: 58, y: 12, width: 340, height: 24))
        urlField.placeholderString = "https://feishu.cn/..."
        if let clipboard = NSPasteboard.general.string(forType: .string),
           looksLikeURLText(clipboard) {
            urlField.stringValue = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 82))
        let titleLabel = NSTextField(labelWithString: "名称")
        titleLabel.frame = NSRect(x: 0, y: 50, width: 44, height: 20)
        titleLabel.alignment = .right
        let urlLabel = NSTextField(labelWithString: "链接")
        urlLabel.frame = NSRect(x: 0, y: 14, width: 44, height: 20)
        urlLabel.alignment = .right
        accessory.addSubview(titleLabel)
        accessory.addSubview(titleField)
        accessory.addSubview(urlLabel)
        accessory.addSubview(urlField)
        alert.accessoryView = accessory

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = titleField
        if alert.runModal() == .alertFirstButtonReturn {
            let ok = store.addLink(
                toTaskId: bundle.task.id,
                title: titleField.stringValue,
                url: urlField.stringValue
            )
            if !ok {
                showInvalidLinkAlert()
            }
        }
    }

    private func looksLikeURLText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://")
            || trimmed.hasPrefix("https://")
            || trimmed.contains(".")
    }

    private func showInvalidLinkAlert() {
        let alert = NSAlert()
        alert.messageText = "链接没保存"
        alert.informativeText = "名称和链接都要填写，链接可以是 https://... 或 feishu.cn/... 这种格式。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private var uniquePlatforms: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for s in bundle.sessions {
            let host = s.hostApp ?? s.source
            if !seen.contains(host) {
                seen.insert(host)
                result.append(host)
            }
        }
        return result
    }
}

private struct SessionMiniRow: View {
    let session: SessionRow
    /// nil = unassigned (in "其他 session")
    let currentTaskId: Int64?
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 8) {
            HostIcon(host: displayHost, size: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(.system(.subheadline, design: .default))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let preview = session.lastMessage, !preview.isEmpty {
                    Text(preview)
                        .font(.system(.caption2, design: .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text("\(displayHost) · \(humanAge(session.lastActive))")
                    .font(.system(.caption2, design: .default))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Menu {
                sessionMenu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var displayHost: String {
        session.hostApp ?? fallbackHost(source: session.source)
    }

    @ViewBuilder
    private var sessionMenu: some View {
        Button {
            promptRename()
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Divider()
        if session.hostApp != nil {
            Button {
                JumpHelper.openSession(session)
            } label: {
                Label("在 \(displayHost) 打开", systemImage: "arrow.up.right.square")
            }
            Divider()
        }
        if store.bundles.isEmpty {
            Text("还没有项目,先点右上角 + 新建")
        } else {
            let candidates = store.bundles.filter { $0.task.id != currentTaskId }
            if !candidates.isEmpty {
                if currentTaskId == nil {
                    Text("添加到项目")
                } else {
                    Text("移到项目")
                }
                ForEach(candidates) { b in
                    Button(b.task.name) {
                        store.assignSession(session.id, toTaskId: b.task.id)
                    }
                }
            }
        if currentTaskId != nil {
                Divider()
                Button(role: .destructive) {
                    store.unassignSession(session.id)
                } label: {
                    Label("取消分配", systemImage: "xmark.circle")
                }
            }
        }
        if session.source == "link" {
            Divider()
            Button(role: .destructive) {
                store.deleteManualLink(session.id)
            } label: {
                Label("删除链接", systemImage: "trash")
            }
        } else {
            Divider()
            Button(role: .destructive) {
                store.hideSession(session.id)
            } label: {
                Label("隐藏 session", systemImage: "eye.slash")
            }
        }
    }

    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = "重命名 session"
        alert.informativeText = "这个名字会保存在 Pickup,后续自动同步不会覆盖。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = session.displayTitle
        alert.accessoryView = input
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.renameSession(session.id, title: input.stringValue)
        }
    }
}

private struct UnlinkedSection: View {
    let sessions: [SessionRow]
    @ObservedObject var store: SessionStore
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("其他 session (\(sessions.count))")
                        .font(.system(.subheadline, design: .default).weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if expanded {
                Text("近 7 天还没分配的 session · 点 ⋯ 添加到项目")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 2)
                ForEach(sessions) { s in
                    SessionMiniRow(session: s, currentTaskId: nil, store: store)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Renders a host platform icon: real app icon if available, SF Symbol fallback otherwise.
struct HostIcon: View {
    let host: String
    let size: CGFloat

    var body: some View {
        if let img = AppIconProvider.icon(forHost: host) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: sfFallback(host))
                .font(.system(size: size - 3))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    private func sfFallback(_ host: String) -> String {
        switch host {
        case "Claude": return "sparkles"
        case "Codex": return "terminal"
        case "ChatGPT": return "bubble.left.fill"
        case "Link": return "link"
        case "Ghostty", "Terminal", "iTerm": return "command"
        default: return "circle.fill"
        }
    }
}

private func fallbackHost(source: String) -> String {
    switch source {
    case "claude_code": return "Claude Code"
    case "codex": return "Codex"
    case "chatgpt": return "ChatGPT"
    case "link": return "Link"
    case "ghostty": return "Ghostty"
    default: return source
    }
}

private func humanAge(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = f.date(from: iso)
    if date == nil {
        f.formatOptions = [.withInternetDateTime]
        date = f.date(from: iso)
    }
    guard let date else { return "?" }
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s/60)m" }
    if s < 86400 { return "\(s/3600)h" }
    return "\(s/86400)d"
}
