# The window and the folder filter. -Today and -MaxAgeHours go by each session's last turn, not by its file's time
# (Claude Code appends bookkeeping to every open transcript); several folders can be named at once; -HandoffOnly starts
# nothing when acct-sync gives no plan. Synthetic registry and transcripts in a scratch root. The stand-in wt.exe and
# claude.exe are first in PATH, and the runs that could start something are checked against them first.
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scratch.ps1')   # $S, the work folder
$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'Restore-ClaudeSessions.ps1'
$root = Join-Path $S 'window-root'
$fake = Join-Path $S 'fake'
$log  = Join-Path $S 'fake-window.log'
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$root\registry", "$root\t" -Force | Out-Null
Remove-Item $log -ErrorAction SilentlyContinue
$fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') { if ($ok) { "ok    $what" } else { $script:fail++; "FAIL  $what  $detail" } }

$now = Get-Date
if ($now.TimeOfDay.TotalMinutes -lt 15) { 'skip  less than 15 minutes after midnight: too little of today to place the cases in'; 'failures: 0'; exit 0 }

function Iso([datetime]$t) { $t.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }
function Turn([datetime]$t) {
    '{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"hello"},"timestamp":"' + (Iso $t) + '"}' + "`n" +
    '{"parentUuid":"x","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]},"timestamp":"' + (Iso $t.AddSeconds(5)) + '"}'
}
# What Claude Code appends to an open transcript without a turn: a notice with a time, a bridge record without one.
$bookkeeping = '{"type":"system","subtype":"informational","content":"Remote Control disconnected","timestamp":"' + (Iso $now.AddMinutes(-3)) + '"}' + "`n" +
    '{"type":"bridge-session","sessionId":"x","bridgeSessionId":"cse_x"}'
# A record whose NESTED object says user, with today's time: not a turn.
$nested = '{"type":"attachment","attachment":{"type":"user","timestamp":"' + (Iso $now.AddMinutes(-2)) + '"},"timestamp":"' + (Iso $now.AddMinutes(-2)) + '"}'

function Id([string]$c) { ($c * 8) + '-' + ($c * 4) + '-4' + ($c * 3) + '-8' + ($c * 3) + '-' + ($c * 12) }
function Case([string]$c, [string]$folder, [string]$body, [datetime]$fileTime) {
    $cwd = Join-Path "$root\work" $folder
    New-Item -ItemType Directory $cwd -Force | Out-Null
    $p = Join-Path "$root\t" "$c.jsonl"
    Set-Content -LiteralPath $p -Value $body -Encoding utf8
    (Get-Item -LiteralPath $p).LastWriteTime = $fileTime
    # pid 4 is the System process: alive, but not a claude, so the entry counts as closed
    [ordered]@{ session_id = (Id $c); cwd = $cwd; transcript_path = $p; source = 'startup'; started_at = $now.AddDays(-6).ToString('o'); pid = 4; claude_cmdline = 'claude.exe --dangerously-skip-permissions' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path "$root\registry" "$(Id $c).json") -Encoding utf8
}
$midnight = $now.Date
Case 'a' 'alpha'         (Turn $now.AddMinutes(-10))                         $now.AddMinutes(-9)   # used today
Case 'b' 'beta'          ((Turn $now.AddDays(-5)) + "`n" + $bookkeeping)     $now.AddMinutes(-2)   # idle 5 days, file written now
Case 'c' 'gamma_classic' (Turn $now.AddMinutes(-12))                         $now.AddMinutes(-11)  # used today
Case 'd' 'delta'         '{"type":"user","message":{"role":"user","content":"no times here"}}' $now.AddMinutes(-13)   # no time in it: the file's
Case 'e' 'alpha'         (Turn $midnight.AddMinutes(-60))                    $midnight.AddMinutes(-59)   # yesterday 23:00, file then too
Case 'f' 'epsilon'       ((Turn $midnight.AddMinutes(-120)) + "`n" + $bookkeeping) $now.AddMinutes(-2)   # yesterday 22:00, file written now
Case 'g' 'zeta'          ((Turn $now.AddDays(-4)) + "`n" + $nested)          $now.AddMinutes(-1)   # idle 4 days, a nested "user" now

& (Join-Path $PSScriptRoot 'fake-exe.ps1') -Dir $fake
$env:CRESTORE_ROOT = $root
$env:CRESTORE_ACCT_SYNC = Join-Path $root 'no-such-acct-sync.mjs'   # no plan: titles come from the transcripts
$env:CRESTORE_GUARD_DIR = Join-Path $root 'guard'                     # -Prepare tidies this folder: not the real one
$env:FAKE_EXE_LOG = $log
$env:NO_COLOR = '1'
$oldPath = $env:PATH
$env:PATH = "$fake;$env:PATH"
$standIns = ((Get-Command wt.exe).Source -eq "$fake\wt.exe" -and (Get-Command claude).Source -eq "$fake\claude.exe")
Check 'the stand-ins are the ones found in PATH' $standIns
if (-not $standIns) { $env:PATH = $oldPath; "failures: $fail"; exit $fail }

function Run([string[]]$a) { pwsh -NoProfile -File $script @a 2>&1 | ForEach-Object { "$_" } }
# Which sessions a run offers: a dry run prints each one's command, with its id.
function Offered([string[]]$a) {
    $o = (Run ($a + @('-All', '-DryRun'))) -join "`n"
    $set = @{}; foreach ($c in 'a', 'b', 'c', 'd', 'e', 'f', 'g') { if ($o -match (Id $c)) { $set[$c] = $true } }
    return (($set.Keys | Sort-Object) -join '')
}

$got = Offered @('-Today')
Check "-Today: a turn today (a, c), and a transcript with no time in it by its file's time (d) ($got)" ($got -eq 'acd')
$list = (Run @('-Today', '-List')) -join "`n"
Check '-Today: the header says used today' ($list -match 'Restorable Claude sessions \(used today\)')
Check '-Today: the note names the three whose files were written today but whose last turn was not (b, f, g)' ($list -match 'Not offered: 3 session\(s\)' -and $list -match 'beta 1' -and $list -match 'epsilon 1' -and $list -match 'zeta 1' -and $list -match 'in place of -Today') ($list -split "`n" | Select-String 'Not offered')
$got = Offered @()
Check "default window (72h, by last turn): a, c, d, e, f, not b (5 days) or g (4 days) ($got)" ($got -eq 'acdef')
$list = (Run @('-List')) -join "`n"
Check 'default window: the note counts b and g, and asks for no -Today' ($list -match 'Not offered: 2 session\(s\)' -and $list -notmatch 'in place of -Today') ($list -split "`n" | Select-String 'Not offered')
Check 'default window: the header is unchanged' ($list -match 'Restorable Claude sessions \(last 72h\)')
$got = Offered @('-MaxAgeHours', '200')
Check "-MaxAgeHours 200: all seven ($got)" ($got -eq 'abcdefg')

$got = Offered @('alpha,gamma', '-Today')
Check "two folders in one argument (as pwsh -File passes them): a and c ($got)" ($got -eq 'ac')
$got = Offered @('-Project', 'gamma')
Check "a fragment still matches inside a folder name (gamma in gamma_classic) ($got)" ($got -eq 'c')
$o = (pwsh -NoProfile -Command "& '$($script -replace "'", "''")' alpha,delta -All -DryRun" 2>&1 | ForEach-Object { "$_" }) -join "`n"
$set = @(foreach ($c in 'a', 'b', 'c', 'd', 'e', 'f', 'g') { if ($o -match (Id $c)) { $c } }) -join ''
Check "two folders as an array (crestore alpha,delta): a, d, e ($set)" ($set -eq 'ade')
$o = (Run @('-Prepare', '-DryRun', 'nothing-matches-this')) -join "`n"
Check '-Prepare runs with a folder list' ($o -match 'No open Claude sessions')

# -HandoffOnly with no acct-sync: nothing starts, and it says why. A real run against the stand-ins, not a dry run.
$o = (Run @('-Today', '-HandoffOnly', '-All')) -join "`n"
$calls = if (Test-Path $log) { @(Get-Content -LiteralPath $log | Where-Object { $_ -like '### *' }) } else { @() }
Check '-HandoffOnly, no acct-sync: says nothing is started' ($o -match 'with -HandoffOnly nothing is started') $o
Check "-HandoffOnly, no acct-sync: nothing was started ($($calls.Count) stand-in calls)" ($calls.Count -eq 0)
$o = (Run @('-Today', '-HandoffOnly', '-All', '-DryRun', '-Target', 'vscode')) -join "`n"
Check '-HandoffOnly, no acct-sync, VS Code target: nothing queued' ($o -notmatch 'queue for VS Code' -and $o -match 'nothing is started')
$o = (Run @('-Today', '-HandoffOnly', '-From', 'auto', '-List')) -join "`n"
Check '-HandoffOnly with -From auto: says -From is ignored' ($o -match '-From auto is ignored')
$o = (Run @('-Today', '-From', 'handoff', '-All', '-DryRun')) -join "`n"
Check 'without -HandoffOnly the old fallback stands: resumed in full, and says so' ($o -match 'resumed in full' -and $o -match '--resume')

$env:PATH = $oldPath
Remove-Item Env:CRESTORE_ROOT, Env:CRESTORE_ACCT_SYNC, Env:CRESTORE_GUARD_DIR, Env:FAKE_EXE_LOG -ErrorAction SilentlyContinue
"failures: $fail"
exit $fail
