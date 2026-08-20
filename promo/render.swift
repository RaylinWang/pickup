import AppKit
import Foundation
import SwiftUI

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = root.appendingPathComponent("promo/output")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

private let canvasSize = CGSize(width: 1080, height: 1080)
private let menuSize = CGSize(width: 380, height: 540)
private let menuScale: CGFloat = 1.52

struct DemoSession: Identifiable {
    let id: String
    let host: String
    let title: String
    let preview: String?
    let age: String
}

struct DemoProject: Identifiable {
    let id: Int
    let name: String
    let description: String
    let sessions: [DemoSession]
}

private let projectPlan = DemoProject(
    id: 1,
    name: "产品发布计划",
    description: "官网文案、发布 checklist 和素材整理",
    sessions: [
        DemoSession(id: "claude-brief", host: "Claude", title: "发布 checklist", preview: "把上线前检查项分成设计、工程、运营", age: "2h"),
        DemoSession(id: "chatgpt-pricing", host: "ChatGPT", title: "定价页文案改写", preview: "帮我把这段说明压缩成三句话", age: "3h"),
        DemoSession(id: "link-doc", host: "Link", title: "飞书项目文档", preview: "https://demo.feishu.cn/wiki/product-plan", age: "3h"),
        DemoSession(id: "codex-guide", host: "Codex", title: "安装向导说明", preview: "已更新本地构建和启动步骤", age: "1d"),
    ]
)

private let researchProject = DemoProject(
    id: 2,
    name: "用户访谈整理",
    description: "把访谈记录、洞察和跟进任务放在一起",
    sessions: [
        DemoSession(id: "claude-summary", host: "Claude", title: "访谈摘要结构", preview: "按场景、阻碍、动机整理要点", age: "1d"),
        DemoSession(id: "ghostty-notes", host: "Ghostty", title: "~/Projects/interviews", preview: "导出访谈记录并生成 markdown", age: "1d"),
    ]
)

private let unlinkedSessions = [
    DemoSession(id: "gpt-onboarding", host: "ChatGPT", title: "Onboarding 流程优化", preview: "把首次使用路径拆成 3 步", age: "28m"),
    DemoSession(id: "gpt-welcome", host: "ChatGPT", title: "新用户欢迎页文案", preview: "让第一屏说明更短、更像产品语言", age: "1h"),
    DemoSession(id: "claude-video", host: "Claude", title: "功能演示视频脚本", preview: "30 秒版本和 90 秒版本各一版", age: "4h"),
    DemoSession(id: "codex-tests", host: "Codex", title: "修复菜单刷新状态", preview: "检查隐藏 session 和手动刷新逻辑", age: "6h"),
    DemoSession(id: "gpt-english", host: "ChatGPT", title: "英文落地页翻译", preview: "把中文介绍改成自然的英文表达", age: "1d"),
    DemoSession(id: "link-design", host: "Link", title: "设计稿链接", preview: "https://demo.figma.com/file/pickup", age: "1d"),
    DemoSession(id: "gpt-weekly", host: "ChatGPT", title: "周报结构整理", preview: "用项目进展、风险、下一步来组织", age: "2d"),
    DemoSession(id: "ghostty-build", host: "Ghostty", title: "打包测试命令", preview: "生成 app 包并检查启动状态", age: "2d"),
]

enum OverlayKind {
    case projectMenu
    case addLink
    case sessionMenu
}

struct PromoCanvas: View {
    let title: String
    let subtitle: String
    let projects: [DemoProject]
    let unlinked: [DemoSession]
    var overlay: OverlayKind?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: NSColor(calibratedWhite: 0.965, alpha: 1)),
                    Color(nsColor: NSColor(calibratedWhite: 0.925, alpha: 1)),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 0) {
                Color.white.opacity(0.54).frame(height: 220)
                Color(nsColor: NSColor(calibratedRed: 0.92, green: 0.94, blue: 0.96, alpha: 1)).frame(height: 640)
                Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.98, blue: 0.97, alpha: 1))
            }

            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.18))
                    Text(subtitle)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                .padding(.top, 28)

                ZStack(alignment: .topLeading) {
                    PickupMenu(projects: projects, unlinked: unlinked)
                    if overlay == .projectMenu {
                        FloatingMenu(width: 164, items: [
                            ("pencil", "编辑名称", false),
                            ("text.alignleft", "编辑概述", false),
                            ("link", "添加链接", false),
                            ("trash", "删除项目", true),
                        ])
                        .offset(x: 208, y: 78)
                    }
                    if overlay == .sessionMenu {
                        FloatingMenu(width: 178, items: [
                            ("pencil", "重命名", false),
                            ("arrow.up.right.square", "在 ChatGPT 打开", false),
                            ("circle", "移到项目", false),
                            ("eye.slash", "隐藏 session", true),
                        ])
                        .offset(x: 194, y: 146)
                    }
                    if overlay == .addLink {
                        AddLinkDialog()
                            .offset(x: 48, y: 338)
                    }
                }
                .frame(width: menuSize.width, height: menuSize.height)
                .scaleEffect(menuScale)
                .frame(width: menuSize.width * menuScale, height: menuSize.height * menuScale)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }
}

struct PickupMenu: View {
    let projects: [DemoProject]
    let unlinked: [DemoSession]

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                if projects.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(projects.enumerated()), id: \.element.id) { idx, project in
                        ProjectSection(project: project)
                        if idx < projects.count - 1 {
                            Divider().padding(.horizontal, 16)
                        }
                    }
                }
                if !unlinked.isEmpty {
                    Divider().padding(.horizontal, 16)
                    UnlinkedSection(sessions: unlinked)
                }
            }
            .padding(.vertical, 4)
            .frame(width: menuSize.width, height: menuSize.height - 47, alignment: .topLeading)
            .offset(y: 47)
            .clipped()
            VStack(spacing: 0) {
                header
                Divider()
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .zIndex(1)
        }
        .frame(width: menuSize.width, height: menuSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 22, x: 0, y: 18)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Sessions")
                .font(.system(.headline, design: .default))
            Spacer()
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
            Image(systemName: "xmark.circle")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Color.primary)
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
}

struct ProjectSection: View {
    let project: DemoProject

    var uniquePlatforms: [String] {
        var seen = Set<String>()
        return project.sessions.compactMap { session in
            guard !seen.contains(session.host) else { return nil }
            seen.insert(session.host)
            return session.host
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(project.name)
                    .font(.system(.subheadline, design: .default).weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                ForEach(uniquePlatforms, id: \.self) { host in
                    HostIcon(host: host, size: 12)
                }
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
            }

            Text(project.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1...4)

            ForEach(project.sessions) { session in
                SessionMiniRow(session: session)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct SessionMiniRow: View {
    let session: DemoSession

    var body: some View {
        HStack(spacing: 8) {
            HostIcon(host: session.host, size: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(.subheadline, design: .default))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let preview = session.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(.caption2, design: .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text("\(session.host) · \(session.age)")
                    .font(.system(.caption2, design: .default))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16)
        }
    }
}

struct UnlinkedSection: View {
    let sessions: [DemoSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("其他 session (\(sessions.count))")
                    .font(.system(.subheadline, design: .default).weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text("近 7 天还没分配的 session · 点 ⋯ 添加到项目")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            ForEach(sessions) { session in
                SessionMiniRow(session: session)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct HostIcon: View {
    let host: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image = AppIconProvider.icon(forHost: host) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: sfFallback(host))
                    .font(.system(size: max(size - 3, 8)))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
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

enum AppIconProvider {
    private static var cache: [String: NSImage] = [:]

    static func icon(forHost host: String) -> NSImage? {
        if let cached = cache[host] { return cached }
        guard let path = appPath(for: host), FileManager.default.fileExists(atPath: path) else {
            return nil
        }
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

struct FloatingMenu: View {
    let width: CGFloat
    let items: [(String, String, Bool)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index == items.count - 1 {
                    Divider().padding(.leading, 34)
                }
                HStack(spacing: 10) {
                    Image(systemName: item.0)
                        .font(.system(size: 12, weight: .regular))
                        .frame(width: 16)
                    Text(item.1)
                        .font(.system(size: 13, weight: .regular))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(item.2 ? Color.red : Color.primary)
                .padding(.horizontal, 12)
                .frame(height: 30)
            }
        }
        .padding(.vertical, 6)
        .frame(width: width)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 8)
    }
}

struct AddLinkDialog: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("添加链接")
                .font(.system(.headline, design: .default))
            Text("保存到「产品发布计划」")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                FieldRow(label: "名称", value: "飞书项目文档")
                FieldRow(label: "链接", value: "https://demo.feishu.cn/wiki/product-plan")
            }

            HStack {
                Spacer()
                Text("取消")
                    .font(.system(size: 13))
                    .frame(width: 64, height: 24)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("添加")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 24)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(16)
        .frame(width: 284)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.20), radius: 16, x: 0, y: 12)
    }
}

struct FieldRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.9), lineWidth: 1)
                }
        }
    }
}

func writePNG(_ image: NSImage, name: String) {
    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        fatalError("Failed to encode \(name)")
    }
    try! png.write(to: outDir.appendingPathComponent(name))
}

@available(macOS 13.0, *)
@MainActor
func renderWithImageRenderer<V: View>(_ view: V, name: String) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage else {
        fatalError("Failed to render \(name)")
    }
    writePNG(image, name: name)
}

@MainActor
func renderWithHostingView<V: View>(_ view: V, name: String) {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: canvasSize)
    hosting.layoutSubtreeIfNeeded()
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        fatalError("Failed to create bitmap for \(name)")
    }
    rep.size = canvasSize
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let image = NSImage(size: canvasSize)
    image.addRepresentation(rep)
    writePNG(image, name: name)
}

@MainActor
func render<V: View>(_ view: V, name: String) {
    if #available(macOS 13.0, *) {
        renderWithImageRenderer(view, name: name)
    } else {
        renderWithHostingView(view, name: name)
    }
}

await MainActor.run {
    render(
        PromoCanvas(
            title: "Pickup 真实界面",
            subtitle: "把 AI 对话、终端 session 和项目链接收在一起",
            projects: [projectPlan, researchProject],
            unlinked: Array(unlinkedSessions.prefix(3))
        ),
        name: "01-cover.png"
    )

    render(
        PromoCanvas(
            title: "最近 7 天自动同步",
            subtitle: "ChatGPT、Claude、Codex、Ghostty 会出现在「其他 session」",
            projects: [],
            unlinked: unlinkedSessions
        ),
        name: "02-problem.png"
    )

    render(
        PromoCanvas(
            title: "链接不用监听",
            subtitle: "飞书、网页和需求文档可以手动添加到项目",
            projects: [projectPlan],
            unlinked: [],
            overlay: .projectMenu
        ),
        name: "03-features.png"
    )

    render(
        PromoCanvas(
            title: "噪音可以藏起来",
            subtitle: "不重要的 session 可手动隐藏，刷新时还能恢复",
            projects: [projectPlan],
            unlinked: Array(unlinkedSessions.suffix(4)),
            overlay: .sessionMenu
        ),
        name: "04-example.png"
    )

    render(
        PromoCanvas(
            title: "手动添加项目链接",
            subtitle: "给链接命名后，它会像 session 一样留在项目里",
            projects: [projectPlan],
            unlinked: [],
            overlay: .addLink
        ),
        name: "05-link-dialog.png"
    )
}

print("Generated sanitized SwiftUI promo screenshots in \(outDir.path)")
