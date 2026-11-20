# End-to-end test of crestore's real (non-dry) path on a synthetic set of closed sessions, with nothing real started:
#   - synth-sessions.mjs builds the set in the work folder: transcripts in a config folder of its own
#     (CLAUDE_CONFIG_DIR), crestore's registry (CRESTORE_ROOT), a handoff-guard record and a Cache Keeper record. Four
#     sessions: big (large and cold, with a handoff of its own), small, stray (a transcript acct-sync cannot find) and
#     notx (no transcript, but a handoff its handoff-guard record names)
#   - stand-in wt.exe and claude.exe first in PATH: each only appends its argv, cwd and CRESTORE_WAKE to a log
#   - the "tab" is then run here the way Windows Terminal would start it (same command line, minus -NoExit)
# acct-sync, where one is installed (scratch.ps1 finds it), runs for real on that set with a scratch state file, and
# writes its packs into the set's config folder. How each session should come back is asked of it first, so the test
# checks that crestore does what acct-sync plans. Without acct-sync the sessions with a transcript are resumed (or stay
# closed with -HandoffOnly), and notx still comes back from its own handoff. -NoAcctSync runs it so where acct-sync is
# installed too.
param([string]$Filter = '', [string]$From = 'auto', [int]$MaxAgeHours = 400, [switch]$KeepPacks, [switch]$HandoffOnly, [switch]$NoAcctSync)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scratch.ps1')
if ($NoAcctSync) { $AcctSyncTool = $null }
$real = Split-Path $PSScriptRoot -Parent                           # the scripts under test
$set  = Join-Path $S 'e2e'
$fake = Join-Path $S 'fake'
$log  = Join-Path $S 'fake.log'
$fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') { if ($ok) { "ok    $what" } else { $script:fail++; "FAIL  $what  $detail" } }
if ($HandoffOnly) { $From = 'handoff' }

# ---- stand-in executables
& (Join-Path $PSScriptRoot 'fake-exe.ps1') -Dir $fake

# ---- the synthetic sessions
$m = (& node (Join-Path $PSScriptRoot 'synth-sessions.mjs') $set) | ConvertFrom-Json
if (-not $m -or -not $m.sids) { 'FAIL  synth-sessions.mjs built no session set'; 'failures: 1'; exit 1 }
$names = @{}; foreach ($p in $m.sids.PSObject.Properties) { $names[$p.Value] = $p.Name }
Remove-Item $log -ErrorAction SilentlyContinue

$env:CRESTORE_ROOT              = $m.root
$env:CLAUDE_CONFIG_DIR          = $m.config
$env:CRESTORE_GUARD_DIR         = Join-Path $m.config 'handoff-guard'
$env:CRESTORE_CACHE_KEEPER_DIR  = Join-Path $m.config 'cache-keeper'
$env:CRESTORE_ACCT_SYNC         = if ($AcctSyncTool) { $AcctSyncTool } else { Join-Path $set 'no-acct-sync.mjs' }
$env:ACCT_SYNC_STATE            = Join-Path $set 'state.json'
$env:FAKE_EXE_LOG               = $log
$env:NO_COLOR                   = '1'
"acct-sync: $(if ($AcctSyncTool) { 'found, run on the synthetic set' } else { 'none found (CRESTORE_ACCT_SYNC names one): the sessions with a transcript get no plan' })"

# ---- how each session should come back. acct-sync's own plan for the ones with a transcript (a separate state file,
# so this call leaves crestore's run as it would be); notx has none and comes back from its own handoff whatever -From
# says. A session acct-sync cannot find has no plan: resumed in full, or with -HandoffOnly left closed.
$planned = @{}
if ($AcctSyncTool) {
    $ids = @('big', 'small', 'stray' | ForEach-Object { $m.sids.$_ })
    $env:ACCT_SYNC_STATE = Join-Path $set 'state.expect.json'
    $raw = (& node $AcctSyncTool wake --json --mode $From @ids 2>$null) -join "`n"
    $env:ACCT_SYNC_STATE = Join-Path $set 'state.json'
    $j = $null; try { $j = $raw | ConvertFrom-Json } catch {}
    Check "acct-sync plans the three sessions with a transcript ($(@($j.sessions).Count))" (@($j.sessions).Count -eq 3) $raw
    # (not $s: PowerShell's names ignore case, and $S is the work folder)
    foreach ($one in @($j.sessions)) { if ($one.sid -and -not $one.missing) { $planned["$($one.sid)"] = "$($one.route)" } }
    Check 'it finds big and small, and not stray, whose transcript is outside the projects folder' ($planned.ContainsKey($m.sids.big) -and $planned.ContainsKey($m.sids.small) -and -not $planned.ContainsKey($m.sids.stray)) (($planned.Keys | ForEach-Object { $names[$_] }) -join ',')
    if ($From -eq 'auto') { Check 'its plan: big from a pack, small resumed (the cases this set was built for)' ($planned[$m.sids.big] -eq 'handoff' -and $planned[$m.sids.small] -eq 'resume') "big=$($planned[$m.sids.big]) small=$($planned[$m.sids.small])" }
}
$expect = @{}   # name -> pack | own | resume | closed
foreach ($n in 'big', 'small', 'stray') {
    $p = $planned[$m.sids.$n]
    $expect[$n] = if (-not $p) { $(if ($HandoffOnly) { 'closed' } else { 'resume' }) } elseif ($p -eq 'handoff') { 'pack' } else { 'resume' }
}
$expect['notx'] = 'own'
"expected: $(($expect.Keys | Sort-Object | ForEach-Object { "$_=$($expect[$_])" }) -join ' ')"

# A parent Claude Code session's markers, as when crestore runs from a session's Bash tool or from a terminal that a
# session started. crestore drops them before it starts anything, and the handoff launcher drops them again inside a
# tab that still has them (below, every tab is started from this process, markers and all). Any other CLAUDE*
# variable stays. A resume tab is claude itself: what it inherits is Windows Terminal's or the extension's business.
$markers = [ordered]@{
    CLAUDECODE = '1'; CLAUDE_CODE_CHILD_SESSION = '1'; CLAUDE_CODE_SESSION_ID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    CLAUDE_CODE_SESSION_ATTENDED = '1'; CLAUDE_PID = '4242'; CLAUDE_CODE_MESSAGING_SOCKET = 'test'; CLAUDE_CODE_SSE_PORT = '1'
    CLAUDE_EFFORT = 'low'; HUB_CALL = 'test'; HUB_WORKER = 'w9'
}
foreach ($k in $markers.Keys) { Set-Item -LiteralPath "Env:$k" -Value $markers[$k] }
$env:CLAUDE_CRESTORE_TEST_KEEP = '1'
function Get-Leaked($block) { @($block.seen | Where-Object { $markers.Contains($_) }) }
# And as when crestore runs from a session that a handoff started: that session's link to the one it carries on.
$env:CRESTORE_WAKE    = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
$env:CRESTORE_WAKE_AT = '2026-01-01T00:00:00.0000000Z'
$oldPath = $env:PATH
$env:PATH = "$fake;$env:PATH"
$standIns = ((Get-Command wt.exe -ErrorAction SilentlyContinue).Source -eq "$fake\wt.exe" -and (Get-Command claude -ErrorAction SilentlyContinue).Source -eq "$fake\claude.exe")
Check 'the stand-ins are the ones found in PATH' $standIns
# A real run follows: without the stand-ins it would open real tabs and start real sessions, so it stops here.
if (-not $standIns) { $env:PATH = $oldPath; "failures: $fail"; exit ([Math]::Max(1, $fail)) }

$wakeBefore = @(Get-ChildItem (Join-Path $real 'wake') -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) $($_.LastWriteTimeUtc.Ticks)" }) -join ';'

# ---- run the restore for real
$sel = @(); if ($Filter) { $sel += $Filter }
if ($HandoffOnly) { $sel += '-HandoffOnly' }   # with -From handoff: a session with no pack stays closed
$out = pwsh -NoProfile -File "$real\Restore-ClaudeSessions.ps1" @sel -All -MaxAgeHours $MaxAgeHours -From $From 2>&1 | ForEach-Object { "$_" }
'--- crestore output ---'; $out | ForEach-Object { '  ' + $_ }
$outText = $out -join "`n"

function Read-Blocks {
    $blocks = @(); $cur = $null
    if (-not (Test-Path -LiteralPath $log)) { return $blocks }
    foreach ($line in (Get-Content -LiteralPath $log -Encoding UTF8)) {
        if ($line.StartsWith('### ')) { $h = $line.Substring(4).Split([char]0x1f); $cur = [pscustomobject]@{ exe = $h[0]; cwd = $h[1]; wake = $h[2]; at = $h[3]; seen = @("$($h[4])" -split ',' | Where-Object { $_ }); args = [System.Collections.Generic.List[string]]::new() } }
        elseif ($line -eq '###end') { $blocks += $cur; $cur = $null }
        elseif ($cur) { $cur.args.Add($line) }
    }
    return $blocks
}
$wtCalls = @(Read-Blocks | Where-Object exe -eq 'wt')
$nOpen = @($expect.Values | Where-Object { $_ -ne 'closed' }).Count
Check "wt was called once per session that comes back ($($wtCalls.Count) of $nOpen)" ($wtCalls.Count -eq $nOpen)
$wtLeaked = @($wtCalls | ForEach-Object { Get-Leaked $_ } | Sort-Object -Unique)
Check "Windows Terminal is started without the parent session's markers ($($wtCalls.Count) calls)" ($wtLeaked.Count -eq 0) ("leaked: " + ($wtLeaked -join ', '))
Check 'any other CLAUDE* variable reaches Windows Terminal' (@($wtCalls | Where-Object { $_.seen -notcontains 'CLAUDE_CRESTORE_TEST_KEEP' }).Count -eq 0)
Check "Windows Terminal is started without the link of the session crestore runs from" (@($wtCalls | Where-Object { $_.wake -or $_.at }).Count -eq 0) (@($wtCalls | ForEach-Object { "$($_.wake)|$($_.at)" } | Sort-Object -Unique) -join ' ')
foreach ($n in @($expect.Keys | Where-Object { $expect[$_] -eq 'closed' })) {
    Check "${n}: stays closed (-HandoffOnly, no plan), and its resume line is printed" ($outText -match "stays closed.*claude --resume $($m.sids.$n)") ($out | Select-String 'stays closed' | Out-String)
}
# The tabs below start from this process; what crestore puts on a resume tab must be all it gets of a link.
Remove-Item Env:CRESTORE_WAKE, Env:CRESTORE_WAKE_AT -ErrorAction SilentlyContinue

# ---- start each "tab" as Windows Terminal would: the args after `nt ...` joined, an arg with a space in quotes
Remove-Item $log -ErrorAction SilentlyContinue
$tabs = @()
foreach ($w in $wtCalls) {
    $a = $w.args
    $i = $a.IndexOf('pwsh')
    $cwd = $a[$a.IndexOf('-d') + 1]
    $tab = @($a.GetRange($i, $a.Count - $i) | Where-Object { $_ -ne '-NoExit' })
    Check 'the tab command is one argument after -Command' ($tab.Count -eq 4 -and $tab[2] -eq '-Command') ($tab -join ' | ')
    $cmdline = ($tab | Select-Object -Skip 1 | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi = [System.Diagnostics.ProcessStartInfo]::new('pwsh', $cmdline)
    $psi.WorkingDirectory = $cwd; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi); $so = $p.StandardOutput.ReadToEnd(); $se = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    $tabs += [pscustomobject]@{ cwd = $cwd; cmd = $tab[3]; out = $so; err = $se; code = $p.ExitCode }
}
$claudeCalls = @(Read-Blocks | Where-Object exe -eq 'claude')
Check "every tab started claude ($($claudeCalls.Count) of $($tabs.Count))" ($claudeCalls.Count -eq $tabs.Count) (($tabs | Where-Object err | ForEach-Object err) -join ' / ')

$nHandoff = 0; $nResume = 0; $packs = @(); $got = @{}
for ($k = 0; $k -lt $claudeCalls.Count; $k++) {
    $c = $claudeCalls[$k]; $t = $tabs[$k]; $a = $c.args
    if ($t.cmd -like '*Start-HandoffSession.ps1*') {
        $nHandoff++
        $old = ($t.cmd -split ' ')[-1]
        $who = if ($names[$old]) { $names[$old] } else { $old.Substring(0, 8) }
        $wf = Join-Path $m.root "wake\$old.json"
        Check "handoff ${who}: wake file written" (Test-Path $wf)
        $j = Get-Content $wf -Raw | ConvertFrom-Json
        # A session that saved no transcript comes back from its OWN handoff, a file of its own: never deleted here.
        $own = $j.no_transcript -eq $true
        $got[$who] = if ($own) { 'own' } else { 'pack' }
        if (-not $own) { $packs += $j.pack }
        Check "handoff ${who}: the pack exists" (Test-Path -LiteralPath $j.pack) $j.pack
        Check "handoff ${who}: claude got exactly the wake file's arguments" ((@($a) -join "`n") -eq (@($j.args) -join "`n")) ("got: " + ($a -join ' | '))
        $ip = $a.IndexOf('--append-system-prompt')
        $named = if ($own) { $j.pack -replace '\\', '/' } else { $j.pack }
        Check "handoff ${who}: the pointer is one argument, the last, and names the pack" ($ip -eq $a.Count - 2 -and $a[$ip + 1] -like "*'$named'*" -and $a[$ip + 1] -notmatch '["`$]')
        Check "handoff ${who}: no --resume, and a session name" (-not $a.Contains('--resume') -and $a.Contains('-n'))
        Check "handoff ${who}: CRESTORE_WAKE = the old id, cwd = the session's folder" ($c.wake -eq $old -and $c.cwd -eq $t.cwd) "wake=$($c.wake) cwd=$($c.cwd)"
        $atOk = $false; try { $atOk = [Math]::Abs(((Get-Date).ToUniversalTime() - ([datetime]$c.at).ToUniversalTime()).TotalMinutes) -lt 5 } catch {}
        Check "handoff ${who}: CRESTORE_WAKE_AT = the launch time" $atOk "at=$($c.at)"
        if ($own) {
            $gr = try { Get-Content -LiteralPath (Join-Path $env:CRESTORE_GUARD_DIR "live\$old.json") -Raw | ConvertFrom-Json } catch { $null }
            Check "handoff ${who}: no transcript, so the pack is its own handoff, the one its handoff-guard record names" ($gr -and (("$($gr.track.handoffPath)" -replace '\\', '/') -eq ($j.pack -replace '\\', '/'))) $j.pack
        } else {
            Check "handoff ${who}: the pack is a restart or switch pack for that session" ((Get-Content -LiteralPath $j.pack -TotalCount 3) -join ' ' -match "acct-sync pack: session=$old kind=(restart|switch)")
            Check "handoff ${who}: the pack lies in the set's own config folder" (($j.pack -replace '/', '\').StartsWith($m.config, [StringComparison]::OrdinalIgnoreCase)) $j.pack
        }
        Check "handoff ${who}: claude gets none of the markers its tab has, so it saves a transcript" ((Get-Leaked $c).Count -eq 0) ("leaked: " + ((Get-Leaked $c) -join ', '))
    } else {
        $nResume++
        $sid = "$($a[-1])"
        $who = if ($names[$sid]) { $names[$sid] } else { $sid }
        $got[$who] = 'resume'
        Check "resume ${who}: claude --resume <id> with flags ($($a -join ' '))" ($a.Contains('--resume') -and $sid -match '^[0-9a-f-]{36}$' -and -not $c.wake -and -not $c.at)
    }
}
"handoff tabs: $nHandoff, resume tabs: $nResume"
Check 'the run restored something each way or says why not' ($nHandoff + $nResume -eq $tabs.Count)
foreach ($n in 'big', 'small', 'stray', 'notx') {
    $want = $expect[$n]; $have = if ($got.ContainsKey($n)) { $got[$n] } else { 'closed' }
    Check "${n}: comes back as planned ($want)" ($have -eq $want) "got $have"
}
$wakeAfter = @(Get-ChildItem (Join-Path $real 'wake') -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) $($_.LastWriteTimeUtc.Ticks)" }) -join ';'
Check 'the wake folder beside the scripts was not touched' ($wakeAfter -eq $wakeBefore)

# ---- the VS Code target: the command the extension types into a terminal, typed here into each shell it can be.
# Taken from a dry run (so no VS Code window opens and the extension folder is not touched); the wake files are
# the ones the run above wrote.
function Invoke-Typed([string]$exe, [string[]]$exeArgs, [string]$text) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new($exe)
    foreach ($x in $exeArgs) { $psi.ArgumentList.Add($x) }
    $psi.WorkingDirectory = $S; $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    $p.StandardInput.WriteLine($text); $p.StandardInput.Close()
    if (-not $p.WaitForExit(90000)) { $p.Kill($true); return 'TIMEOUT' }
    return ($so.Result + $se.Result)
}
$gitBash = Get-Command bash -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -like '*\Git\*' } | Select-Object -First 1
$shells = [ordered]@{
    'PowerShell 7'           = @('pwsh', @('-NoProfile', '-NoLogo', '-Command', '-'))
    'Windows PowerShell 5.1' = @('powershell', @('-NoProfile', '-NoLogo', '-Command', '-'))
    'cmd'                    = @('cmd', @('/d', '/q'))
}
if ($gitBash) { $shells['Git Bash'] = @($gitBash.Source, @()) } else { 'skip  Git Bash: no bash.exe of Git for Windows on PATH' }
$vs = pwsh -NoProfile -File "$real\Restore-ClaudeSessions.ps1" @sel -All -DryRun -MaxAgeHours $MaxAgeHours -From $From -Target vscode 2>&1 | ForEach-Object { "$_" }
$queued = @($vs | ForEach-Object { if ($_ -match '^queue for VS Code: \[(.*)\] (.+?) :: (.+)$') { [pscustomobject]@{ cwd = $Matches[2]; cmd = $Matches[3] } } })
Check "VS Code target: one queued command per session ($($queued.Count))" ($queued.Count -eq $tabs.Count)
$vsHandoff = @($queued | Where-Object { $_.cmd -like '*Start-HandoffSession.ps1*' })
Check "VS Code target: the same sessions come back from a handoff ($($vsHandoff.Count))" ($vsHandoff.Count -eq $nHandoff)
foreach ($q in ($vsHandoff | Select-Object -First 2)) {
    $old = ($q.cmd -split ' ')[-1]
    $who = if ($names[$old]) { $names[$old] } else { $old.Substring(0, 8) }
    Check "VS Code ${who}: the command starts pwsh itself and holds no single quote, dollar or backtick" ($q.cmd -match '^pwsh -NoLogo -NoProfile -File "[^"]+Start-HandoffSession\.ps1" [0-9a-f-]{36}$' -and $q.cmd -notmatch "['`$``]") $q.cmd
    $j = Get-Content (Join-Path $m.root "wake\$old.json") -Raw | ConvertFrom-Json
    foreach ($name in $shells.Keys) {
        Remove-Item $log -ErrorAction SilentlyContinue
        $o = Invoke-Typed $shells[$name][0] $shells[$name][1] $q.cmd
        $calls = @(Read-Blocks | Where-Object exe -eq 'claude')
        $ok = $calls.Count -eq 1 -and ((@($calls[0].args) -join "`n") -eq (@($j.args) -join "`n")) -and $calls[0].wake -eq $old -and $calls[0].cwd -eq $q.cwd
        Check "VS Code $who typed into ${name}: claude starts once with the wake file's arguments, in the session's folder" $ok (($o -replace '\s+', ' ').Trim())
        if ($calls.Count -eq 1) {
            Check "VS Code $who typed into ${name}: claude gets none of the markers the terminal has" ((Get-Leaked $calls[0]).Count -eq 0) ("leaked: " + ((Get-Leaked $calls[0]) -join ', '))
        }
    }
}

if (-not $KeepPacks) { foreach ($p in $packs) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }; "removed $($packs.Count) test pack(s)" }
$env:PATH = $oldPath
Remove-Item Env:CRESTORE_ROOT, Env:CRESTORE_GUARD_DIR, Env:CRESTORE_CACHE_KEEPER_DIR, Env:CRESTORE_ACCT_SYNC, Env:FAKE_EXE_LOG, Env:ACCT_SYNC_STATE, Env:CLAUDE_CRESTORE_TEST_KEEP -ErrorAction SilentlyContinue
foreach ($k in $markers.Keys) { Remove-Item -LiteralPath "Env:$k" -ErrorAction SilentlyContinue }
"failures: $fail"
exit $fail
