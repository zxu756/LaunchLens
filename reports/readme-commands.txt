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
    ... (101 lines omitted) ...
    ✔ Test run with 47 tests in 4 suites passed after 3.543 seconds.
    
    Building for debugging...
    [1 / 12]
    Build complete! (0.36秒)
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [3/16] ./Scripts/build-app.sh
    ==> Building LaunchLens (release, arm64, macOS 14.0+)...
    Building for production...
    [3 / 11] LaunchLensCore
    [5 / 12] LaunchLensCore
    Build complete! (7.17秒)
    ==> Assembling <REPO_ROOT>/build/LaunchLens.app...
    ==> Generating AppIcon.icns...
    ==> Ad-hoc signing & verifying...
    ✓ Built <REPO_ROOT>/build/LaunchLens.app
    
    <REPO_ROOT>/build/LaunchLens.app: replacing existing signature
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [4/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang en
    Total Non-Apple Background RSS (service trees + orphans): 2.2 MB (1 running, 1 orphans)
    2.2 MB      PID 74202   [Orphan daemon]  python3 / <SCRUBBED_TARGET> (PID 74202)
    0 MB        IDLE        [User agent]  io.fixture.readme-agent
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [5/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang zh
    非 Apple 后台常驻内存总计（服务进程树 + 孤儿进程）：2.2 MB（1 项运行中，1 个孤儿进程）
    2.2 MB      PID 74202   [孤儿进程]  python3 / <SCRUBBED_TARGET> (PID 74202)
    0 MB        空闲          [用户代理]  io.fixture.readme-agent
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [6/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --json --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang en
    {
      "capturedAt" : "2026-11-15T11:03:07Z",
      "frozenRecords" : [
    
      ],
    ... (70 lines omitted) ...
        }
      ],
      "totalBackgroundRSSBytes" : 2277376,
      "totalListeningPortCount" : 1
    }
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [7/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli orphans --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang en
    2.2 MB      PID 74202    python3 / <SCRUBBED_TARGET> (PID 74202)  :55381
    [ASSERT PASS] exit=0, verified output pattern (regex)

==> [8/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli orphans --agents-dir "${AGENTS_DIR:-.}" --ledger-dir "${LEDGER_DIR:-${TMPDIR:-/tmp}}" --lang zh
    2.2 MB      PID 74202    python3 / <SCRUBBED_TARGET> (PID 74202)  :55381
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
           LaunchLens --cli [freeze <label>|restore <id-or-label>|repair] --confirm [--json] [--lang en|zh] [--ledger-dir <dir>] [--agents-dir <dir>]
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [14/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --help --lang zh
    用法：LaunchLens --cli [list|orphans|frozen|audit] [--json] [--lang en|zh] [--ledger-dir <目录>] [--agents-dir <目录>]
          LaunchLens --cli [freeze <服务标识>|restore <记录ID或服务标识>|repair] --confirm [--json] [--lang en|zh] [--ledger-dir <目录>] [--agents-dir <目录>]
    [ASSERT PASS] exit=0, verified output pattern (exact_all)

==> [15/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang en
SKIPPED in milestone 0 (reads host ~/Library/LaunchAgents; runs in release mode only): build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang en

==> [16/16] build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang zh
SKIPPED in milestone 0 (reads host ~/Library/LaunchAgents; runs in release mode only): build/LaunchLens.app/Contents/MacOS/LaunchLens --cli list --lang zh

[Summary] mode=milestone0 total=16 passed=13 skipped=3
================================================================
EXECUTED README COMMAND CHECKS PASSED; SKIPPED CHECKS COUNTED SEPARATELY (EXIT 0)
================================================================
