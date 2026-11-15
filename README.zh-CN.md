# LaunchLens

**[English](README.md)** | **简体中文**

**面向 macOS 的用户级 `LaunchAgents` 与后台服务常驻内存（RSS）账本：支持去重进程树内存核算、脚本与可执行文件名精确孤儿检测、可回滚 SHA-256 事务型冻结、冲突比对恢复与启动台账自检。**

![LaunchLens 中文主账本面板（演示数据预览）](docs/screenshot-main-zh.png)

> **`[演示数据 / DEMO]` 截图说明：** 本文档中的两张界面截图均由 `LaunchLensMonitor.preview()`（`--export-screenshots` / `--demo`）静态示例数据渲染（如 `ai.local.whisper-voice-agent` 占 `4.82 GB`、`com.updater.telemetry-helper` 释放 `412 MB`），并非采自本机真实进程。自动化验收脚本不启动图形窗口；正常启动（不带 `--demo`）时均实时扫描本机，不载入任何演示数据。

在 macOS 开发环境中，长期驻留的 `LaunchAgents`、全局/系统 `launchd` 配置项以及终端退出后残留的 `PPID == 1` CLI / MCP 进程会持续占用统一内存（RSS）与本地 `localhost` TCP 端口。

**LaunchLens** 是纯 SwiftPM 构建的原生 macOS 14+ 工具（包含主账本窗口、菜单栏弹窗与无头 CLI），支持应用内 `中文 / EN` 实时切换，零第三方依赖、零 `sudo` 提权提示、零网络请求。

> **版本状态说明（已发布 `v0.2.0` vs 未发布 `v0.2.0` 之后）：** 已发布的 `v0.2.0`（`main`）包含中英双语主窗口、菜单栏弹窗与 `--cli list|orphans|frozen`（`--lang zh|en`）。下文标注 **未发布（`v0.2.0` 之后）** 的改动——包括服务进程树去重 RSS 与按 `Program` 反查系统守护进程、精确文件名与目标脚本孤儿判定、6 步可回滚 `freeze` 事务、防覆盖 `restore`、启动完整性恢复、操作前命令确认框、`--demo` 演示开关，以及命令行的 `--json`、`--cli audit|freeze|restore|repair`、`--help` / `-h`、`--agents-dir`、`--ledger-dir` 与退出码 `1`/`2`——位于 `main`（`v0.2.0`）之后的源码中，尚未进入当前 Homebrew Cask 发行二进制。
>
> **`v0.1.0` / `v0.2.0` 用户升级自检提示：** 已发布的 `v0.1.0` 与 `v0.2.0` 在冻结时先删除原 `.plist` 最后才写 `ledger.json`，且未检查 `launchctl` 退出码。升级到 `v0.2.0` 之后的构建版本后，可执行 `build/LaunchLens.app/Contents/MacOS/LaunchLens --cli audit --lang zh`（或直接打开应用），检查 `~/Library/Application Support/LaunchLens/Snapshots/` 中是否存在中断的「进行中」记录或无记录孤儿备份文件，并通过 **修复 / 恢复** 找回。

## 已验证能力

- **去重进程树 RSS 与监听端口关联（未发布，M1，`v0.2.0` 之后）**：扫描 `~/Library/LaunchAgents`、`/Library/LaunchAgents` 与 `/Library/LaunchDaemons`，对每个运行中服务沿 `ppid` 汇总 `{根进程 PID} ∪ 全部子孙进程 PID`（按 PID 去重）的 `ps` 常驻内存（RSS）与 `lsof` 监听 TCP 端口；对用户域 `launchctl list` 不返回 PID 的系统守护进程按 `Program` / `ProgramArguments[0]` 规范化路径精确反查匹配。
- **精确文件名与目标脚本孤儿进程判定（未发布，M1，`v0.2.0` 之后）**：仅针对未被活跃服务进程树认领且满足 `uid == getuid() && ppid == 1` 的进程，按原生开发守护进程精确 basename 以及 `python*`、`node`、`deno`、`bun`、`uv`/`uvx`、`ruby`、`perl`、`java` 与 Shell 的实际运行脚本 / `-m 模块` / `-jar` 目标进行分类与去重——保留 macOS 命令行框架解释器（`Python.app`、`Ruby.app`），同时排除真实 GUI `.app`、`.xpc`、`.appex` 应用包以及父进程仍存活（`PPID > 1`）的正常子进程。
- **可回滚的 6 步事务型冻结 `freeze`（未发布，`v0.2.0` 之后）**：先通过 `lstat` 校验目标为严格位于 `~/Library/LaunchAgents` 下的普通文件（拒绝符号链接与重复 `label`），在写入任何备份文件之前先预检台账目录、子目录与 `ledger.json` 可写性，随后在 `Snapshots/` 写入原字节备份并校验读回 SHA-256，在调用 `/bin/launchctl bootout gui/<uid>` **之前**先向 `ledger.json` 落盘「进行中」（`inProgress`）记录，再校验 `bootout` 退出码为 `0`，随后将原 `.plist` 移入暂存区（不直接删除），最后更新台账为「已冻结」（`frozen`）；任意步骤失败均按逆序回滚并明确报告失败步骤与当前状态。
- **防覆盖与退出码校验的恢复 `restore`（未发布，`v0.2.0` 之后）**：恢复前先校验备份 SHA-256 与台账可写性；若目标位置已存在同名文件（例如软件更新后重建了新配置），拒绝静默覆盖并列出两份文件的路径、字节大小、SHA-256 前缀与键值差异供用户选择；执行 `/bin/launchctl bootstrap` 失败时完整保留备份文件与台账记录。
- **命令确认弹窗与启动完整性恢复（未发布，`v0.2.0` 之后）**：在主窗口和菜单栏弹窗点击「冻结」或「恢复」时均先弹出确认框，展示即将执行的完整 `/bin/launchctl` 命令与文件路径；启动时自动检测「进行中」记录与孤儿备份文件，点击「修复 / 恢复」时先通过只读的 `launchctl print gui/<uid>/<label>` 精确区分 `0`（已加载，直接清理残留备份而不重复 `bootstrap`）、`113`（未加载，重新执行 `launchctl bootstrap` 并校验退出码 `0`）与异常非零退出码（完整保留记录与备份文件并上报 `recoveryPrintFailed`）。
- **系统服务与孤儿进程只读保护（未发布，`v0.2.0` 之后）**：`/Library/LaunchDaemons`、`/Library/LaunchAgents` 与 `com.apple.*` 服务严格只读；界面中孤儿进程行同样保持只读展示（无「终止进程」按钮）。
- **实时 `中文 / EN` 切换（`v0.2.0`）与规范 CLI 退出码（未发布，`v0.2.0` 之后）**：支持自动识别中文系统语言、界面 `中文 | EN` 切换胶囊（`⇧⌘L`）、`--json` 结构化输出及命令行 `--lang zh|en`，严格区分退出码（`0` 成功、`1` 运行或自检异常、`2` 未知子命令或非法参数）。

<p align="center">
  <img src="docs/screenshot-menubar-zh.png" width="420" alt="LaunchLens 中文菜单栏弹窗（演示数据预览）" />
</p>

> **`[演示数据 / DEMO]` 菜单栏图注：** 由 `LaunchLensMonitor.preview()` 静态示例数据导出（`--export-screenshots`）。

## 内存核算口径与本机实测对账（`2026-11-15`）

### 服务内存核算公式（`L7`）
- **单项服务 RSS**：对每个具有活跃根进程的服务（来自 `launchctl list` 返回的 PID，或对无用户域 PID 的配置项按规范化 `Program` / `ProgramArguments[0]` 精确匹配到的未认领 `ps` 根进程），沿 `ppid` 求 `{根进程 PID} ∪ 全部传递子孙进程 PID` 并**按 PID 去重**，累加 `rssKB * 1024`。未运行服务记为 `0 B`。
- **非 Apple 后台常驻内存总计**：全部非 `com.apple.*` 服务去重进程树 RSS 与全部当前用户 `PPID == 1` 孤儿守护进程 RSS 之和。

### 匿名化真机只读对账结果（`2026-11-15`，`Scripts/acceptance/m1-ledger.sh`）
在 Apple Silicon Mac 上通过只读脚本与独立参考实现交叉核验（`2026-11-15`，不记录任何私有服务标签或用户目录路径）：
- **服务数量与 RSS 一致性**：共 **15 / 15** 项 `.plist` 服务 **100%** 对齐（用户域 `LaunchAgents` **9** 项、全局 `LaunchAgents` **3** 项、系统 `LaunchDaemons` **3** 项）；其中 **4** 项运行中非 Apple 服务（含 **1** 棵多进程服务树与 **1** 项按 `Program` 路径匹配的系统守护进程）稳态服务 RSS 合计 **77.02 MB**，与独立去重 `ps` 计算结果的最大实测偏差为 **0.0000%（0.0 KB）**（门限 `<= 5.0%`）。
- **监听 TCP 端口一致性**：与 `lsof -nP -iTCP -sTCP:LISTEN` 端口集合 **100%** 一致（稳态服务端口 **2** 个，注入临时孤儿探针期间追踪端口 **4** 个；排除 **11** 个 GUI `.app` / 系统监听 PID，未归属监听进程 **0** 个）。
- **孤儿进程检出与零误报**：脚本临时启动的 **2 / 2** 个脱离父进程（`PPID == 1`）TCP 监听孤儿（`node` 与框架版 `python3`）全部检出且临时端口精确匹配（探针期间新增 **47.14 MB** 临时孤儿 RSS，合计 **124.16 MB**）；同时运行的父进程存活（`PPID > 1`）`node_modules` TCP 工作进程 **0** 误报，本机 **132** 个运行中 `.app` 应用进程 **0** 误报（本机原有稳态孤儿进程 **0** 个）。

### 当前边界与后续计划（`M2`）
- **显式开关的真环境冻结回环测试（`LAUNCHLENS_REAL_LAUNCHD=1`）**：`Scripts/acceptance/m1-real-launchd.sh`（创建随机后缀临时 `.plist` 验证冻结、恢复及半截 `SIGKILL` 中断恢复）**默认关闭**，确保日常自动化测试绝不对宿主 `launchd` 执行 `bootstrap`/`bootout`。
- **后续计划（`M2`）**：为残留 MCP/开发孤儿进程标注来源 Agent 会话、提供只读端口与服务查询 MCP 工具、对接 ChronoMac 读取历史内存趋势。

## 安装与编译（macOS 14.0+，Apple Silicon）

### Homebrew Cask 安装（`v0.2.0`，已发布版本）

```bash
brew install --cask zxu756/tap/launchlens
```

> 首次打开未经公证的 ad-hoc 签名构建包时，如遇 Gatekeeper 提示，可执行一次 `xattr -cr /Applications/LaunchLens.app`。

### 从源码编译与范围验证（未发布，`v0.2.0` 之后）

```bash
./Scripts/test.sh scope Freeze Scanner CLI UI
./Scripts/build-app.sh
```

编译完成后可在访达中打开 `build/LaunchLens.app`（如需查看带标签的静态演示数据，可传入 `--demo`，属未发布 `v0.2.0` 之后新增参数）。

## 命令行（Headless CLI）用法

### 隔离夹具验证（未发布，`v0.2.0` 之后）

`--agents-dir`、`--ledger-dir`、`--json`、`--cli audit` 与 `--help` 为 `v0.2.0` 之后新增，可在不读取、不触碰本机 `~/Library/LaunchAgents` 的前提下执行隔离验证（由 `Scripts/acceptance/readme-commands.sh` 自动提取并逐条断言）：

```bash
# 指定隔离目录列出后台服务与孤儿进程（--agents-dir、--ledger-dir、--json：未发布，v0.2.0 之后）
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang en
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang zh
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --json --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang en
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli orphans --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang en
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli orphans --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang zh

# 查看已冻结快照与执行台账完整性自检（--cli audit 与 --help：未发布，v0.2.0 之后）
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli frozen --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang en
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli frozen --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang zh
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli audit --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang en
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli audit --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang zh
build/LaunchLens.app/Contents/MacOS/LaunchLens --help --lang en
build/LaunchLens.app/Contents/MacOS/LaunchLens --help --lang zh
```

### 本机交互式只读扫描（默认读取 `~/Library/LaunchAgents`）

不传 `--agents-dir` 时默认只读扫描当前机器的 `~/Library/LaunchAgents`、`/Library/LaunchAgents` 与 `/Library/LaunchDaemons`（`milestone 0` 与隔离 README 校验中跳过，仅在 `release` 模式下回放）：

```bash
# 只读扫描本机真实 LaunchAgents 与后台常驻内存（交互式使用 / release 模式）
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang en
build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang zh
```

## 架构与设计规范

服务内存公式、孤儿进程分类规则、6 步冻结事务、恢复冲突比对、启动恢复与 CLI 退出码约定详见 [docs/SPEC.md](docs/SPEC.md)。

## 开源协议

MIT
