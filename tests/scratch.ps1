# Dot-sourced by the tests (. "$PSScriptRoot\scratch.ps1"): the work folder, and an environment that reaches nothing
# real. It sets:
#   $S             the work folder: CRESTORE_TEST_DIR, else <temp>\crestore-tests. run-all.ps1 removes it at the end.
#   $AcctSyncTool  the acct-sync.mjs a test may run against its own fixture: CRESTORE_ACCT_SYNC when it is set (set it to
#                  a path with no file, such as 'none', to run the suite as without acct-sync), else where acct-sync's
#                  README installs it (<config folder>\tools\account-sync\acct-sync.mjs); $null when there is none.
#   $TestConfig    a config folder of the tests' own, empty, and CLAUDE_CONFIG_DIR pointing at it: a default path of
#                  crestore's (handoff-guard's records, Cache Keeper's, settings.json, projects, acct-sync) lands there.
#   PATH           the stand-in claude.exe and wt.exe first (below).
# Every CRESTORE_* variable of the caller's environment is removed (CRESTORE_TARGET, CRESTORE_FROM and CRESTORE_EFFORT
# change what a run does, CRESTORE_WAKE what the hook records), and so are acct-sync's: a test sets what it uses.
$S = if ($env:CRESTORE_TEST_DIR) { $env:CRESTORE_TEST_DIR } else { Join-Path ([IO.Path]::GetTempPath()) 'crestore-tests' }
New-Item -ItemType Directory $S -Force | Out-Null

$AcctSyncTool = $null
$cfgNow = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$c = if ($env:CRESTORE_ACCT_SYNC) { $env:CRESTORE_ACCT_SYNC } else { Join-Path $cfgNow 'tools\account-sync\acct-sync.mjs' }
if (Test-Path -LiteralPath $c -PathType Leaf) { $AcctSyncTool = (Resolve-Path -LiteralPath $c).Path }

foreach ($n in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'CRESTORE_*' -and $_.Name -ne 'CRESTORE_TEST_DIR' } | ForEach-Object Name)) {
    Remove-Item -LiteralPath "Env:$n" -ErrorAction SilentlyContinue
}
Remove-Item Env:ACCT_SYNC_STATE, Env:ACCT_SYNC_HANDOFF_COMMAND -ErrorAction SilentlyContinue

$TestConfig = Join-Path $S 'config\.claude'
New-Item -ItemType Directory $TestConfig -Force | Out-Null
$env:CLAUDE_CONFIG_DIR = $TestConfig

# The stand-ins for claude.exe and wt.exe (fake-exe.ps1) go first in PATH for every test, so a `claude` or `wt` that
# a script under test runs, on purpose or not (a dry run can ask `claude --help` whether --effort exists), is never the
# real one. A test that checks what they were started with sets FAKE_EXE_LOG and checks PATH again itself.
$StandInDir = Join-Path $S 'fake'
& (Join-Path $PSScriptRoot 'fake-exe.ps1') -Dir $StandInDir
$env:PATH = "$StandInDir;$env:PATH"
if ((Get-Command claude -ErrorAction SilentlyContinue).Source -ne "$StandInDir\claude.exe" -or (Get-Command wt.exe -ErrorAction SilentlyContinue).Source -ne "$StandInDir\wt.exe") {
    throw 'the stand-in claude.exe and wt.exe are not the ones found in PATH'
}
