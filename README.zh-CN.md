# LaunchLens `v0.2.0`

**[English](README.md)** | **简体中文**

**面向 Apple Silicon 的 macOS 原生后台 `LaunchAgents`、`LaunchDaemons` 与脱离终端 AI/开发孤儿进程常驻内存账本——内置字节级 SHA-256 可逆冻结与一键恢复保险库。**

![LaunchLens 中文主账本面板](docs/screenshot-main-zh.png)

在 Apple Silicon Mac 上，遗忘的后台 `LaunchAgents`、静默自动更新器，以及终端关闭后残留的 CLI / MCP 子进程（`PPID == 1` 的 `node`、`python`、`uvx`、`ollama`、`codex` 守护进程）常常悄无声息地吞噬 4–12 GB 统一内存并占用大量本地 `localhost` TCP 端口。

**LaunchLens `v0.2.0`** 是一款体积仅约 1.5 MB 的纯 SwiftPM 原生 macOS 14+ 工具（主账本窗口 + 菜单栏弹窗 + 无头命令行 CLI），**支持应用内实时 `中文 / EN` 双语切换、零第三方依赖、零 `sudo` 提权弹窗、零网络请求**。

## 核心亮点

- **统一内存占用光谱条** — 直观展示非 Apple 后台常驻物理内存（RSS）在用户级 `LaunchAgents`、系统级守护进程与孤儿开发进程之间的分布占比。
- **AI 与开发孤儿守护进程检测** — 交叉关联 `launchctl list`、`ps` 与 `lsof`，精准揪出当前用户下脱离父终端（`PPID == 1`）且不受任何 `.plist` 或 `.app` 管理的 `node`、`npx`、`uvx`、`python`、`ollama`、`codex`、`claude`、`opencode` 残留进程及监听端口。
- **字节级 SHA-256 冻结与恢复保险库** — 冻结用户级 `LaunchAgent` 时，**先**将原始 `.plist` 原字节备份及 SHA-256 摘要写入 `~/Library/Application Support/LaunchLens/Snapshots/` 并完成二次落盘校验，**随后**才执行 `launchctl bootout gui/<uid>` 卸载并移出原配置，重启亦不再自启；一键恢复时自动核验 SHA-256 哈希、原样写回字节并执行 `launchctl bootstrap` 重新引导。
- **严格安全边界** — `/Library/LaunchDaemons`、`/Library/LaunchAgents` 与 `com.apple.*` 系统服务严格只读保护，绝不索取 `sudo` 权限或改动系统目录。
- **应用内实时 `中文 / EN` 双语切换 (`v0.2.0`)** — 首次启动自动识别简体中文 macOS 系统语言；主窗口顶栏与菜单栏弹窗顶栏均配备 **`中文 | EN`** 分段切换胶囊，支持菜单栏快捷键 `⇧⌘L`（`切换语言 / Toggle Language`）及命令行 `--lang zh|en` 参数覆盖。
- **菜单栏常驻弹窗与无头 CLI** — 在菜单栏实时显示非 Apple 后台常驻内存总量，或直接通过终端命令巡检。

<p align="center">
  <img src="docs/screenshot-menubar-zh.png" width="420" alt="LaunchLens 中文菜单栏弹窗" />
</p>

## 安装指南 (`v0.2.0`)

### Homebrew Cask 安装（推荐）

```bash
brew install --cask zxu756/tap/launchlens
```

> 首次打开未经公证的本地 ad-hoc 签名构建包时，如遇 Gatekeeper 提示，可执行一次 `xattr -cr /Applications/LaunchLens.app`。

### 从源码编译（macOS 14.0+，Apple Silicon）

```bash
git clone https://github.com/zxu756/LaunchLens.git
cd LaunchLens
swift test --no-parallel
chmod +x Scripts/build-app.sh
./Scripts/build-app.sh
open build/LaunchLens.app
```

## 命令行（Headless CLI）用法

```bash
# 按实时常驻内存（RSS）降序列出非 Apple 后台服务（支持 --lang zh|en）
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang zh

# 仅列出 PPID==1 的开发与 MCP 孤儿守护进程
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli orphans --lang zh

# 查看快照保险库中经 SHA-256 校验的已冻结配置
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli frozen --lang zh

# 导出 2x Retina 中文宣传截图
build/LaunchLens.app/Contents/MacOS/LaunchLens --export-screenshots docs --lang zh
```

## 架构与设计规范

关联算法、安全不变量与快照状态机详见 [docs/SPEC.md](docs/SPEC.md)。

## 开源协议

MIT
