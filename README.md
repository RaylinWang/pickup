# Pickup

Pickup 是一个 macOS 菜单栏应用，用来把分散在 ChatGPT、Claude Code、Codex、终端和网页里的工作 session 归到项目下面。

它的目标不是替代 AI 工具，而是帮你回答一个很实际的问题：这个项目相关的对话、终端 session、文档链接都在哪里。

## 功能

- 在菜单栏里管理项目和 session
- 自动同步最近的 ChatGPT session
- 同步 Claude Code、Codex 和 Ghostty/终端里的相关 session
- 手动添加项目链接，比如飞书文档、网页资料、需求链接
- 给 session 重命名，避免只看到编号
- 隐藏噪音 session，不影响后续新 session 自动同步
- 从 Pickup 里直接打开支持的 session 或链接

## 本地数据

Pickup 的数据保存在本机：

```text
~/.sessiontracker/data.db
```

不会上传数据库，也不会把你的 session 内容提交到仓库。

## 构建

```bash
cd macapp
./build.sh
```

构建后的 app 在：

```text
macapp/build/Pickup.app
```

安装到应用程序：

```bash
pkill -x Pickup 2>/dev/null
rm -rf /Applications/Pickup.app
cp -R macapp/build/Pickup.app /Applications/
open /Applications/Pickup.app
```

## 权限

如果要读取 ChatGPT 桌面端侧边栏里的 session 名，Pickup 需要 macOS「辅助功能」权限：

```text
系统设置 -> 隐私与安全性 -> 辅助功能 -> Pickup
```

不开这个权限时，Pickup 仍然可以同步部分本地缓存、浏览器历史和其他工具 session，但 ChatGPT 桌面侧边栏名称可能拿不到。
