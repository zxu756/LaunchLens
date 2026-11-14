================================================================
LaunchLens README.md & README.zh-CN.md Command Verification
================================================================

==> 1) ./Scripts/test.sh scope Freeze Scanner CLI UI
==> Running scoped tests (--filter FreezeLedgerTests|ScannerCorrelationTests|CLIRunnerTests|UIAndLocalizationTests)...
◇ Test run started.
↳ Testing Library Version: 2403
↳ Target Platform: arm64e-apple-macos14.0
◇ Suite "CLIRunnerTests" started.
◇ Test "Row 7 (L9): Compiled LaunchLens --cli nosuchcmd exits with code 2 on en and zh" started.
✔ Test "Row 7 (L9): Compiled LaunchLens --cli nosuchcmd exits with code 2 on en and zh" passed after 0.088 seconds.
◇ Test "L9: Rejects unknown flags, invalid --lang, and extra positional arguments with exit code 2" started.
✔ Test "L9: Rejects unknown flags, invalid --lang, and extra positional arguments with exit code 2" passed after 0.001 seconds.
◇ Test "L9: Corrupted ledger or missing --agents-dir returns exit code 1; audit reports issues with exit code 1" started.
✔ Test "L9: Corrupted ledger or missing --agents-dir returns exit code 1; audit reports issues with exit code 1" passed after 0.003 seconds.
✔ Suite "CLIRunnerTests" passed after 0.094 seconds.
◇ Suite "FreezeLedgerTests" started.
◇ Test "Hermetic FreezeLedgerStore byte-exact freeze, SHA-256 verification, and restore round-trip" started.
✔ Test "Hermetic FreezeLedgerStore byte-exact freeze, SHA-256 verification, and restore round-trip" passed after 0.003 seconds.
◇ Test "Rejects freezing system daemons or com.apple.* services" started.
✔ Test "Rejects freezing system daemons or com.apple.* services" passed after 0.001 seconds.
◇ Test "Row 1 (L1, L2): Non-zero bootout throws, leaves original plist intact, cleans ledger and backup" started.
✔ Test "Row 1 (L1, L2): Non-zero bootout throws, leaves original plist intact, cleans ledger and backup" passed after 0.001 seconds.
◇ Test "Row 2 (L1): Unwritable ledger aborts before bootout and leaves original plist untouched" started.
✔ Test "Row 2 (L1): Unwritable ledger aborts before bootout and leaves original plist untouched" passed after 0.001 seconds.
◇ Test "L1 Step 6 Finalize Failure: Rolls back staged plist to LaunchAgents and re-bootstraps" started.
✔ Test "L1 Step 6 Finalize Failure: Rolls back staged plist to LaunchAgents and re-bootstraps" passed after 0.002 seconds.
◇ Test "Row 3 (L2): Non-zero bootstrap throws and preserves both backup file and frozen ledger record" started.
✔ Test "Row 3 (L2): Non-zero bootstrap throws and preserves both backup file and frozen ledger record" passed after 0.002 seconds.
◇ Test "Row 4 (L3): Restore refuses to overwrite an existing modified file and reports diff; supports explicit resolution" started.
✔ Test "Row 4 (L3): Restore refuses to overwrite an existing modified file and reports diff; supports explicit resolution" passed after 0.003 seconds.
◇ Test "Row 5 & Row 8 (L10): 1-byte corrupted backup is rejected on restore without writing plist or calling bootstrap" started.
✔ Test "Row 5 & Row 8 (L10): 1-byte corrupted backup is rejected on restore without writing plist or calling bootstrap" passed after 0.002 seconds.
◇ Test "Row 6 & L8: Freeze rejects paths outside LaunchAgents, symlinks, symlinked subdirs, and duplicate labels" started.
✔ Test "Row 6 & L8: Freeze rejects paths outside LaunchAgents, symlinks, symlinked subdirs, and duplicate labels" passed after 0.003 seconds.
◇ Test "M0 Item 3: Startup integrity check detects inProgress records & orphaned backups and recovers both losslessly" started.
✔ Test "M0 Item 3: Startup integrity check detects inProgress records & orphaned backups and recovers both losslessly" passed after 0.002 seconds.
◇ Test "SystemLaunchctlExecutor captures exitCode, stdout, and stderr from programmable fake script" started.
✔ Test "SystemLaunchctlExecutor captures exitCode, stdout, and stderr from programmable fake script" passed after 0.117 seconds.
◇ Test "Step 5 Stage Move Failure: Re-bootstraps service, cleans ledger & backup, leaves original plist intact" started.
✔ Test "Step 5 Stage Move Failure: Re-bootstraps service, cleans ledger & backup, leaves original plist intact" passed after 0.019 seconds.
✔ Suite "FreezeLedgerTests" passed after 0.161 seconds.
◇ Suite "ScannerCorrelationTests" started.
◇ Test "Parses launchctl list output with active PIDs and idle dashes" started.
✔ Test "Parses launchctl list output with active PIDs and idle dashes" passed after 0.001 seconds.
◇ Test "Parses ps RSS in KB, PPID, UID, CPU, and full command arguments" started.
✔ Test "Parses ps RSS in KB, PPID, UID, CPU, and full command arguments" passed after 0.001 seconds.
◇ Test "Parses lsof machine-readable listening TCP port lines" started.
✔ Test "Parses lsof machine-readable listening TCP port lines" passed after 0.001 seconds.
◇ Test "Correlates LaunchAgents with live RSS and isolates PPID==1 developer orphan daemons" started.
✔ Test "Correlates LaunchAgents with live RSS and isolates PPID==1 developer orphan daemons" passed after 0.001 seconds.
◇ Test "L10 & M0 Item 1: Does not mark inProgress records as frozen; enforces PPID==1, UID==currentUID, and launchctl claim" started.
✔ Test "L10 & M0 Item 1: Does not mark inProgress records as frozen; enforces PPID==1, UID==currentUID, and launchctl claim" passed after 0.001 seconds.
✔ Suite "ScannerCorrelationTests" passed after 0.001 seconds.
◇ Suite "UIAndLocalizationTests" started.
◇ Test "Exports non-empty 2x Retina marketing screenshots" started.
✔ Test "Exports non-empty 2x Retina marketing screenshots" passed after 0.257 seconds.
◇ Test "Toggles live between zh-Hans and en and localizes freeze banners" started.
✔ Test "Toggles live between zh-Hans and en and localizes freeze banners" passed after 0.002 seconds.
◇ Test "Auto-detects Chinese system locale and respects UserDefaults & --lang flag" started.
✔ Test "Auto-detects Chinese system locale and respects UserDefaults & --lang flag" passed after 0.144 seconds.
◇ Test "M0 Item 7 (L5): Orphan rows are strictly read-only in UI with zero terminate/kill buttons" started.
✔ Test "M0 Item 7 (L5): Orphan rows are strictly read-only in UI with zero terminate/kill buttons" passed after 0.003 seconds.
◇ Test "M0 Item 5 (L6) & Item 2 (L3): Confirmation dialogs show exact launchctl commands & paths and handle conflict resolution in EN & ZH" started.
✔ Test "M0 Item 5 (L6) & Item 2 (L3): Confirmation dialogs show exact launchctl commands & paths and handle conflict resolution in EN & ZH" passed after 0.539 seconds.
◇ Test "M0 Item 3: Startup integrity banner surfaces interrupted records & orphan backups in EN & ZH and repairs cleanly" started.
✔ Test "M0 Item 3: Startup integrity banner surfaces interrupted records & orphan backups in EN & ZH and repairs cleanly" passed after 0.284 seconds.
✔ Suite "UIAndLocalizationTests" passed after 1.231 seconds.
✔ Test run with 26 tests in 4 suites passed after 1.488 seconds.

==> 2) Ensure build/LaunchLens.app exists (./Scripts/build-app.sh if missing)

==> 3) Headless CLI list (--lang en & --lang zh)
Total Non-Apple Background RSS (user-domain launchctl + orphans): 27 MB (3 running, 0 orphans)
17 MB       PID 895     [User agent]  local.rclone.gdrive-mount
7.7 MB      PID 24819   [Global agent]  com.netease.uuremote.agent
2.4 MB      PID 896     [User agent]  local.airi.opencode-proxy
0 MB        IDLE        [User agent]  com.google.GoogleUpdater.wake
0 MB        IDLE        [System daemon]  com.google.GoogleUpdater.wake.system
0 MB        IDLE        [User agent]  com.google.keystone.agent
0 MB        IDLE        [Global agent]  com.google.keystone.agent
0 MB        IDLE        [System daemon]  com.google.keystone.daemon
0 MB        IDLE        [User agent]  com.google.keystone.xpcservice
0 MB        IDLE        [Global agent]  com.google.keystone.xpcservice
0 MB        IDLE        [System daemon]  com.netease.uuremote.daemon
0 MB        IDLE        [User agent]  com.riot.riotclient.checkinstalls
0 MB        IDLE        [User agent]  local.folia.proxy-env
0 MB        IDLE        [User agent]  local.folia.vps-tunnel
0 MB        IDLE        [User agent]  local.jokebear.voice
非 Apple 后台常驻内存总计（用户域 launchctl + 孤儿进程）：27 MB（3 项运行中，0 个孤儿进程）
17 MB       PID 895     [用户代理]  local.rclone.gdrive-mount
7.7 MB      PID 24819   [全局代理]  com.netease.uuremote.agent
2.4 MB      PID 896     [用户代理]  local.airi.opencode-proxy
0 MB        空闲          [用户代理]  com.google.GoogleUpdater.wake
0 MB        空闲          [系统守护进程]  com.google.GoogleUpdater.wake.system
0 MB        空闲          [用户代理]  com.google.keystone.agent
0 MB        空闲          [全局代理]  com.google.keystone.agent
0 MB        空闲          [系统守护进程]  com.google.keystone.daemon
0 MB        空闲          [用户代理]  com.google.keystone.xpcservice
0 MB        空闲          [全局代理]  com.google.keystone.xpcservice
0 MB        空闲          [系统守护进程]  com.netease.uuremote.daemon
0 MB        空闲          [用户代理]  com.riot.riotclient.checkinstalls
0 MB        空闲          [用户代理]  local.folia.proxy-env
0 MB        空闲          [用户代理]  local.folia.vps-tunnel
0 MB        空闲          [用户代理]  local.jokebear.voice

==> 4) Headless CLI orphans (--lang en & --lang zh)
No orphaned developer/AI daemons detected.
未检测到脱离终端的开发/AI 孤儿守护进程。

==> 5) Headless CLI frozen (--lang en & --lang zh)
No frozen LaunchAgents in snapshot vault.
快照保险库中暂无已冻结的 LaunchAgents。

==> 6) Headless CLI audit (--lang en & --lang zh)
Ledger audit OK: 0 interrupted transactions, 0 orphaned backups.
台账完整性检查通过：0 条中断事务，0 个孤儿备份文件。

==> 7) Headless CLI --help (--lang en & --lang zh)
Usage: LaunchLens --cli [list|orphans|frozen|audit] [--lang en|zh] [--ledger-dir <dir>] [--agents-dir <dir>]
用法：LaunchLens --cli [list|orphans|frozen|audit] [--lang en|zh] [--ledger-dir <目录>] [--agents-dir <目录>]

==> 8) Isolated --export-screenshots check to temp directory (--lang en & --lang zh)
Exported 2x Retina screenshots (en) to <mktemp>/shots
Exported 2x Retina screenshots (zh-Hans) to <mktemp>/shots

================================================================
ALL README & README.zh-CN COMMANDS SUCCEEDED (EXIT 0)
================================================================
