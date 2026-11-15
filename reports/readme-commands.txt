================================================================
LaunchLens README.md & README.zh-CN.md Command Verification (mode=milestone0)
================================================================
[Parity OK] Extracted 16 identical commands from README.md and README.zh-CN.md.

==> [1/16] brew install --cask zxu756/tap/launchlens
SKIPPED (external Homebrew Cask install requires network and modifies /Applications): brew install --cask zxu756/tap/launchlens

==> [2/16] ./Scripts/test.sh scope Freeze Scanner CLI UI
    ==> Running scoped tests (--filter FreezeLedgerTests|ScannerCorrelationTests|CLIRunnerTests|UIAndLocalizationTests)...
    ◇ Test run started.
    ↳ Testing Library Version: 2403
    ↳ Target Platform: arm64e-apple-macos14.0
    ◇ Suite "CLIRunnerTests" started.
    ... (93 lines omitted) ...
    ✔ Test run with 43 tests in 4 suites passed after 10.701 seconds.
    
    Building for debugging...
    [1 / 12]
    Build complete! (0.26秒)
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [3/16] ./Scripts/build-app.sh
    ==> Building LaunchLens (release, arm64, macOS 14.0+)...
    Building for production...
    [3 / 11] LaunchLensCore
    [5 / 12] LaunchLensCore
    Build complete! (8.91秒)
    ==> Assembling <REPO_ROOT>/build/LaunchLens.app...
    ==> Generating AppIcon.icns...
    ==> Ad-hoc signing & verifying...
    ✓ Built <REPO_ROOT>/build/LaunchLens.app
    
    <REPO_ROOT>/build/LaunchLens.app: replacing existing signature
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [4/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang en
    Total Non-Apple Background RSS (service trees + orphans): 0 MB (0 running, 0 orphans)
    0 MB        IDLE        [User agent]  io.fixture.readme-agent
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [5/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang zh
    非 Apple 后台常驻内存总计（服务进程树 + 孤儿进程）：0 MB（0 项运行中，0 个孤儿进程）
    0 MB        空闲          [用户代理]  io.fixture.readme-agent
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [6/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --json --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang en
    {
      "capturedAt" : "2026-11-15T04:51:46Z",
      "frozenRecords" : [
    
      ],
    ... (39 lines omitted) ...
        }
      ],
      "totalBackgroundRSSBytes" : 0,
      "totalListeningPortCount" : 0
    }
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [7/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli orphans --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang en
    No orphaned developer/AI daemons detected.
    [ASSERT PASS] exit=0, verified output pattern (regex)

==> [8/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli orphans --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang zh
    未检测到脱离终端的开发/AI 孤儿守护进程。
    [ASSERT PASS] exit=0, verified output pattern (regex)

==> [9/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli frozen --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang en
    No frozen LaunchAgents in snapshot vault.
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [10/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli frozen --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang zh
    快照保险库中暂无已冻结的 LaunchAgents。
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [11/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli audit --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang en
    Ledger audit OK: 0 interrupted transactions, 0 orphaned backups.
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [12/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli audit --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang zh
    台账完整性检查通过：0 条中断事务，0 个孤儿备份文件。
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [13/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --help --lang en
    Usage: LaunchLens --cli [list|orphans|frozen|audit] [--json] [--lang en|zh] [--ledger-dir <dir>] [--agents-dir <dir>]
           LaunchLens --cli [freeze <label>|restore <id-or-label>|repair] [--json] [--lang en|zh] [--ledger-dir <dir>] [--agents-dir <dir>]
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [14/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --help --lang zh
    用法：LaunchLens --cli [list|orphans|frozen|audit] [--json] [--lang en|zh] [--ledger-dir <目录>] [--agents-dir <目录>]
          LaunchLens --cli [freeze <服务标识>|restore <记录ID或服务标识>|repair] [--json] [--lang en|zh] [--ledger-dir <目录>] [--agents-dir <目录>]
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [15/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang en
SKIPPED in milestone 0 (reads host ~/Library/LaunchAgents; runs in release mode only): build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang en

==> [16/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang zh
SKIPPED in milestone 0 (reads host ~/Library/LaunchAgents; runs in release mode only): build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang zh

[Summary] mode=milestone0 total=16 passed=13 skipped=3
================================================================
EXECUTED README COMMAND CHECKS PASSED; SKIPPED CHECKS COUNTED SEPARATELY (EXIT 0)
================================================================
