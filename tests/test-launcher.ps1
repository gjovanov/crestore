# Start-HandoffSession.ps1 on its own: a hand-written wake file with awkward text (Cyrillic, an apostrophe, an
# ampersand, a percent sign, a semicolon, paths with spaces). claude is the stand-in from fake-exe.ps1.
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scratch.ps1')   # $S, the work folder
$launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-HandoffSession.ps1'
$fake = Join-Path $S 'fake'
& (Join-Path $PSScriptRoot 'fake-exe.ps1') -Dir $fake
$root = Join-Path $S 'launcher-root'
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$root\wake" -Force | Out-Null
$log = Join-Path $S 'launcher.log'
$fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') { if ($ok) { "ok    $what" } else { $script:fail++; "FAIL  $what  $detail" } }

$sid  = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
$pack = Join-Path $root 'pack with space.md'
Set-Content -LiteralPath $pack -Value '# pack' -Encoding utf8
$cwd  = Join-Path $root 'work dir'
New-Item -ItemType Directory $cwd -Force | Out-Null
# A name in Cyrillic with an apostrophe, an ampersand, a percent sign and a semicolon; a flag value with a space.
$name = "Тестова сесия: Иван & Мария's 100% run; ep 15"
$pointer = "This session was started to carry on the work of an earlier Claude Code session (aaaaaaaa, named 'x'). Its handoff is the file '$($pack -replace '\\','/')'. Read it once."
$wakeArgs = @('--dangerously-skip-permissions', '--add-dir', 'C:\some dir\with space', '--effort', 'max', '-n', $name, '--append-system-prompt', $pointer)
[ordered]@{ session_id = $sid; cwd = $cwd; name = $name; pack = $pack; args = $wakeArgs; created_at = (Get-Date).ToString('o') } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root "wake\$sid.json") -Encoding utf8

$env:CRESTORE_ROOT = $root
$env:FAKE_EXE_LOG  = $log
$oldPath = $env:PATH
$env:PATH = "$fake;$env:PATH"
# The launcher runs `claude`: never the real one.
if ((Get-Command claude -ErrorAction SilentlyContinue).Source -ne "$fake\claude.exe") { $env:PATH = $oldPath; 'FAIL  the stand-in claude is not the one found in PATH'; 'failures: 1'; exit 1 }

# What a terminal that a Claude Code session started passes on (a VS Code window crestore cold-started from one):
# the parent session's markers. The launcher drops them; any other CLAUDE* variable stays.
$markers = [ordered]@{
    CLAUDECODE = '1'; CLAUDE_CODE_CHILD_SESSION = '1'; CLAUDE_CODE_SESSION_ID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    CLAUDE_CODE_SESSION_ATTENDED = '1'; CLAUDE_PID = '4242'; CLAUDE_CODE_MESSAGING_SOCKET = 'test'; CLAUDE_CODE_SSE_PORT = '1'
    CLAUDE_EFFORT = 'low'; HUB_CALL = 'test'; HUB_WORKER = 'w9'
}
foreach ($k in $markers.Keys) { Set-Item -LiteralPath "Env:$k" -Value $markers[$k] }
$env:CLAUDE_CRESTORE_TEST_KEEP = '1'

function Read-Call {
    $lines = @(Get-Content -LiteralPath $log -Encoding UTF8)
    $h = $lines[0].Substring(4).Split([char]0x1f)
    [pscustomobject]@{ cwd = $h[1]; wake = $h[2]; at = $h[3]; seen = @("$($h[4])" -split ',' | Where-Object { $_ }); args = @($lines[1..($lines.Count - 2)]) }
}
foreach ($shell in @('pwsh')) {   # the launcher always runs in PowerShell 7: both tab commands start it there
    Remove-Item $log -ErrorAction SilentlyContinue
    $o = & $shell -NoProfile -Command "& '$launcher' $sid; 'after:' + [string]`$env:CRESTORE_WAKE + '|' + [string]`$env:CRESTORE_WAKE_AT" 2>&1 | ForEach-Object { "$_" }
    Check "${shell}: claude was started" (Test-Path $log) ($o -join ' / ')
    if (-not (Test-Path $log)) { continue }
    $c = Read-Call
    Check "${shell}: every argument arrives intact, in order ($($c.args.Count))" ((@($c.args) -join "`n") -eq (@($wakeArgs) -join "`n")) ("got: " + ($c.args -join ' | '))
    Check "${shell}: CRESTORE_WAKE is set for claude" ($c.wake -eq $sid)
    $atOk = $false; try { $atOk = [Math]::Abs(((Get-Date).ToUniversalTime() - ([datetime]$c.at).ToUniversalTime()).TotalMinutes) -lt 5 } catch {}
    Check "${shell}: CRESTORE_WAKE_AT is the launch time, in UTC" ($atOk -and $c.at -match 'Z$') $c.at
    Check "${shell}: claude runs in the session's folder" ($c.cwd -eq $cwd) $c.cwd
    Check "${shell}: both variables are cleared afterwards" (($o | Select-Object -Last 1) -eq 'after:|') ($o | Select-Object -Last 1)
    $leaked = @($c.seen | Where-Object { $markers.Contains($_) })
    Check "${shell}: claude gets none of the parent session's markers, so it saves a transcript" ($leaked.Count -eq 0) ("leaked: " + ($leaked -join ', '))
    Check "${shell}: any other CLAUDE* variable reaches claude" ($c.seen -contains 'CLAUDE_CRESTORE_TEST_KEEP') ($c.seen -join ', ')
}

# what it says when it cannot start from a handoff
Remove-Item $log -ErrorAction SilentlyContinue
$o = (pwsh -NoProfile -Command "& '$launcher' bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" 2>&1 | ForEach-Object { "$_" }) -join ' / '
Check 'no wake file: says so, offers the full resume, starts nothing' ($o -match 'no wake file' -and $o -match 'claude --resume bbbbbbbb' -and -not (Test-Path $log)) $o
Remove-Item -LiteralPath $pack
$o = (pwsh -NoProfile -Command "& '$launcher' $sid" 2>&1 | ForEach-Object { "$_" }) -join ' / '
Check 'pack gone: says so, offers the full resume, starts nothing' ($o -match 'handoff file is gone' -and $o -match "claude --resume $sid" -and -not (Test-Path $log)) $o

# A session that saved no transcript comes back from its own handoff (no_transcript in the wake file): it cannot be
# resumed, so the tab never offers `claude --resume`, whether it starts or its handoff is gone.
$sid2 = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
$own = Join-Path $root 'own handoff.md'
Set-Content -LiteralPath $own -Value '# its own handoff' -Encoding utf8
$args2 = @('--effort', 'max', '-n', 'own', '--append-system-prompt', "Its handoff is the file '$($own -replace '\\','/')'.")
[ordered]@{ session_id = $sid2; cwd = $cwd; name = 'own'; pack = $own; args = $args2; created_at = (Get-Date).ToString('o'); no_transcript = $true } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root "wake\$sid2.json") -Encoding utf8
Remove-Item $log -ErrorAction SilentlyContinue
$o = (pwsh -NoProfile -Command "& '$launcher' $sid2" 2>&1 | ForEach-Object { "$_" }) -join ' / '
$c2 = if (Test-Path $log) { Read-Call } else { $null }
Check 'no transcript: claude starts with the wake file''s arguments, in the session''s folder' ($c2 -and (@($c2.args) -join "`n") -eq (@($args2) -join "`n") -and $c2.wake -eq $sid2 -and $c2.cwd -eq $cwd) $o
Check 'no transcript: the tab says the handoff is all there is, and offers no resume' ($o -match 'never saved' -and $o -notmatch 'claude --resume') $o
Remove-Item -LiteralPath $own
Remove-Item $log -ErrorAction SilentlyContinue
$o = (pwsh -NoProfile -Command "& '$launcher' $sid2" 2>&1 | ForEach-Object { "$_" }) -join ' / '
Check 'no transcript, handoff gone: says so, offers no resume, starts nothing' ($o -match 'handoff file is gone' -and $o -match 'nothing else can bring it back' -and $o -notmatch 'claude --resume' -and -not (Test-Path $log)) $o

$env:PATH = $oldPath
Remove-Item Env:CRESTORE_ROOT, Env:FAKE_EXE_LOG, Env:CLAUDE_CRESTORE_TEST_KEEP -ErrorAction SilentlyContinue
foreach ($k in $markers.Keys) { Remove-Item -LiteralPath "Env:$k" -ErrorAction SilentlyContinue }
"failures: $fail"
exit $fail
