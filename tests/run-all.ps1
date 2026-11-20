# Every test of crestore, in order.
#
#   pwsh -NoProfile -File tests/run-all.ps1 [-KeepWork] [-Full]
#
# Nothing real is started or read. Windows Terminal and claude are stand-ins that record their arguments (fake-exe.ps1),
# first in PATH for every test (scratch.ps1).
# Every registry, transcript, handoff-guard record and Cache Keeper record a test reads is made up by that test, in the
# work folder (scratch.ps1: CRESTORE_TEST_DIR, else %TEMP%\crestore-tests; removed at the end unless -KeepWork), and
# CLAUDE_CONFIG_DIR points crestore's default paths at an empty folder there. Where acct-sync is installed
# (CRESTORE_ACCT_SYNC, else <config folder>\tools\account-sync\acct-sync.mjs), the restore and pointer tests run it on
# their synthetic sessions with a scratch state file, and its packs land in the work folder. Without it the pointer test
# is skipped and the restore lanes check what needs no plan. With LongPathsEnabled=0, keep the work folder's path short.
# The VS Code extension runs under node with a stand-in `vscode` module, so what VS Code itself does with a terminal's
# env is not covered, and neither is a turn in a session started from a handoff (that spends usage).
param([switch]$KeepWork, [switch]$Full)
$here = $PSScriptRoot
$tool = Split-Path $here -Parent
$total = 0
function Run([string]$title, [string]$file, [string[]]$more = @()) {
    "=== $title"
    $lines = & pwsh -NoProfile -File (Join-Path $here $file) @more 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $show = if ($Full) { $lines } else { $lines | Where-Object { $_ -notmatch '^(ok |parse ok|lint ok|  |--- crestore output|failures: 0$|handoff tabs:|removed \d+ test pack|expected: )' } }
    $show | ForEach-Object { "  $_" }
    "  $(@($lines | Where-Object { $_ -match '^(ok |parse ok)' }).Count) ok, exit $code"
    $script:total += $code
}
Run 'the scripts parse' 'parse-check.ps1' @("$tool\Restore-ClaudeSessions.ps1", "$tool\Start-HandoffSession.ps1", "$tool\hook.ps1", "$tool\close-terminal.ps1")
Run 'hook.ps1: what it records for a session started from a handoff' 'test-hook.ps1'
Run 'Start-HandoffSession.ps1: what claude is started with' 'test-launcher.ps1'
Run 'the pointer a handoff session is started with: only for its first conversation, not after a /clear' 'test-pointer.ps1'
Run 'bring-back.mjs: what claude is started with; list, CRESTORE_LIST_MATCH and CRESTORE_SKIP_NAME' 'test-bring-back.ps1'
Run 'the launch flags a session comes back with: its own, the same from crestore and bring-back.mjs; -Effort inherit' 'test-launch-flags.ps1'
Run 'the VS Code extension: what each terminal is opened with' 'test-extension.ps1'
Run 'Restore-ClaudeSessions.ps1: which sessions are offered once one was carried on' 'test-taken-over.ps1'
Run 'Restore-ClaudeSessions.ps1: -Today and the window by last turn, several folders, -HandoffOnly without acct-sync' 'test-window.ps1'
Run 'Restore-ClaudeSessions.ps1: a session that saved no transcript comes back from its own handoff or is listed; -AsIfRestarted' 'test-no-transcript.ps1'
Run 'Restore-ClaudeSessions.ps1 -Prepare: asks the open sessions for a handoff, reads the answers, asks before a restart' 'test-prepare.ps1'
Run 'Restore-ClaudeSessions.ps1 -Prepare: what a restart leaves of a session that saved no transcript' 'test-prepare-no-transcript.ps1'
Run 'Restore-ClaudeSessions.ps1 -From auto: the real path with stand-ins on synthetic sessions, both targets' 'test-restore.ps1' @('-From', 'auto')
Run 'Restore-ClaudeSessions.ps1 -From handoff' 'test-restore.ps1' @('-From', 'handoff')
Run 'Restore-ClaudeSessions.ps1 -HandoffOnly' 'test-restore.ps1' @('-From', 'handoff', '-HandoffOnly')
Run 'Restore-ClaudeSessions.ps1 -From auto, as without acct-sync' 'test-restore.ps1' @('-From', 'auto', '-NoAcctSync')
$work = if ($env:CRESTORE_TEST_DIR) { $env:CRESTORE_TEST_DIR } else { Join-Path ([IO.Path]::GetTempPath()) 'crestore-tests' }
if (-not $KeepWork) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
if ($total) { "FAILED: $total" } else { 'all passed' }
exit $total
