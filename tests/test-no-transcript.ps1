# Sessions that saved no transcript (a claude that inherited CLAUDE_CODE_CHILD_SESSION saves none): which come back
# from their own newest handoff, the one handoff-guard's record names, whatever -From says; which are listed as ones
# that cannot be brought back, or as never used, or left to their hub; and -AsIfRestarted. A scratch registry, guard
# folder and Cache Keeper folder; acct-sync, Windows Terminal and claude are stand-ins; an idle hidden node process
# stands in for a session that is running. One real run, into the scratch root, with the stand-ins.
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scratch.ps1')   # $S, the work folder; an empty config folder (no handoff-guard settings)
$tool     = Split-Path $PSScriptRoot -Parent
$script   = Join-Path $tool 'Restore-ClaudeSessions.ps1'
$launcher = Join-Path $tool 'Start-HandoffSession.ps1'
$root  = Join-Path $S 'notx-root'
$guard = Join-Path $root 'guard'
$ck    = Join-Path $root 'cache-keeper'
$fake  = Join-Path $S 'fake'
$log   = Join-Path $S 'notx-fake.log'
$acctLog = Join-Path $S 'notx-acct.log'
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $log, $acctLog -Force -ErrorAction SilentlyContinue
$wk = Join-Path $root 'work'
$lf = Join-Path $root 'proj-lost'
New-Item -ItemType Directory "$root\registry", "$root\t", "$root\handoffs", "$guard\live", "$ck\live", $wk, $lf -Force | Out-Null
$fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') { if ($ok) { "ok    $what" } else { $script:fail++; "FAIL  $what  $detail" } }

# ---- stand-ins: Windows Terminal and claude first in PATH, or nothing runs
& (Join-Path $PSScriptRoot 'fake-exe.ps1') -Dir $fake
$oldPath = $env:PATH
$env:PATH = "$fake;$env:PATH"
if ((Get-Command wt.exe -ErrorAction SilentlyContinue).Source -ne "$fake\wt.exe" -or (Get-Command claude -ErrorAction SilentlyContinue).Source -ne "$fake\claude.exe") {
    $env:PATH = $oldPath; 'FAIL  the stand-ins are not the ones found in PATH'; 'failures: 1'; exit 1
}
# acct-sync: logs what it is asked, and plans every session it is given as a resume
$fakeAcct = Join-Path $root 'fake-acct-sync.mjs'
@'
import fs from 'node:fs'
const a = process.argv.slice(2)
fs.appendFileSync(process.env.NOTX_ACCT_LOG, a.join(' ') + '\n')
const ids = a.filter((x) => /^[0-9a-f]{8}-[0-9a-f]{4}-/.test(x))
process.stdout.write(JSON.stringify({ login: { fp: 'test' }, sessions: ids.map((sid) => ({ sid, route: 'resume', auto: 'resume', ctx: 12000, cache: 'warm', sameLogin: true, name: 'planned by the stand-in' })) }))
'@ | Set-Content -LiteralPath $fakeAcct -Encoding utf8

$proc = Start-Process node -ArgumentList '-e', 'setInterval(()=>0,1e9)' -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 500
try {
    function Id([string]$c) { ($c * 8) + '-' + ($c * 4) + '-4' + ($c * 3) + '-8' + ($c * 3) + '-' + ($c * 12) }
    function Short([string]$c) { (Id $c).Substring(0, 8) }
    $msNow = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    function Ms([double]$minutesAgo) { [long]($msNow - $minutesAgo * 60000) }
    # how crestore shows a time on a list line: HH:mm today, MM-dd HH:mm another day
    function Clock([long]$ms) {
        $t = [DateTimeOffset]::FromUnixTimeMilliseconds($ms).LocalDateTime
        if ($t.Date -eq (Get-Date).Date) { $t.ToString('HH:mm', [cultureinfo]::InvariantCulture) } else { $t.ToString('MM-dd HH:mm', [cultureinfo]::InvariantCulture) }
    }
    $noTx = Join-Path "$root\t" 'never-written.jsonl'
    $turn = '{"type":"user","message":{"role":"user","content":"hello there"}}' + "`n" + '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}'
    function Transcript([string]$name, [int]$minutesAgo = 30) {
        $p = Join-Path "$root\t" "$name.jsonl"; Set-Content -LiteralPath $p -Value $turn -Encoding utf8
        (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddMinutes(-$minutesAgo)
        return $p
    }
    function Entry([string]$c, [string]$cwd, [string]$transcript = $noTx, [hashtable]$more = @{}) {
        $e = [ordered]@{ session_id = (Id $c); cwd = $cwd; transcript_path = $transcript; source = 'startup'; started_at = (Get-Date).AddHours(-5).ToString('o'); pid = 4; claude_cmdline = 'claude.exe --dangerously-skip-permissions' }
        foreach ($k in $more.Keys) { $e[$k] = $more[$k] }
        $e | ConvertTo-Json | Set-Content -LiteralPath (Join-Path "$root\registry" "$(Id $c).json") -Encoding utf8
    }
    # a handoff-guard record (live/<sid>.json), as the plugin writes it
    function Guard([string]$c, [string]$cwd, [hashtable]$track = @{}, [hashtable]$more = @{}) {
        $r = [ordered]@{ v = 1; sid = (Id $c); cwd = ($cwd -replace '\\', '/'); role = $null; startedAt = (Ms 300); updatedAt = (Ms 1); upToDate = $true
            track = [ordered]@{ workAt = 0; handoffAt = 0; handoffPath = $null; turnsAfter = 0 }; busy = $false; pending = $null; request = $null
            lastTurnAt = 0; ctxTokens = $null; endedAt = $null; endReason = $null }
        foreach ($k in $track.Keys) { $r.track[$k] = $track[$k] }
        foreach ($k in $more.Keys) { $r[$k] = $more[$k] }
        $r | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path "$guard\live" "$(Id $c).json") -Encoding utf8
    }
    function Handoff([string]$name, [string]$heading = '') {
        $p = Join-Path "$root\handoffs" "$name.md"
        Set-Content -LiteralPath $p -Value $(if ($heading) { "# $heading`n`nwhere the work stands" } else { 'where the work stands' }) -Encoding utf8
        return ($p -replace '\\', '/')
    }
    function CkRecord([string]$c, [string]$name, [int]$tokens = 0) {
        [ordered]@{ sessionName = $name; context = [ordered]@{ tokens = $tokens } } | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path "$ck\live" "$(Id $c).json") -Encoding utf8
    }

    # a: its own handoff, written after its last work; Cache Keeper has its name              -> offered from that handoff
    $hA = Handoff 'a' 'Heading of a'
    Entry 'a' $wk; Guard 'a' $wk @{ workAt = (Ms 20); handoffAt = (Ms 10); handoffPath = $hA } @{ lastTurnAt = (Ms 10) }; CkRecord 'a' 'Fix the widget' 120000
    # b: its handoff, then three turns of work; no Cache Keeper record, so its handoff's heading names it -> offered, says so
    $hB = Handoff 'b' 'Tune the parser'
    Entry 'b' $wk; Guard 'b' $wk @{ workAt = (Ms 15); handoffAt = (Ms 60); handoffPath = $hB; turnsAfter = 3 } @{ lastTurnAt = (Ms 15) }
    # c: took turns, wrote no handoff                                                            -> cannot be brought back
    Entry 'c' $lf; Guard 'c' $lf @{ workAt = (Ms 30) } @{ lastTurnAt = (Ms 30) }; CkRecord 'c' 'Lost work' 50000
    # d: never took a turn                                                                       -> counted as never used
    Entry 'd' $wk; Guard 'd' $wk
    # e: a hub worker with a handoff                                                             -> left to its hub
    Entry 'e' $wk; Guard 'e' $wk @{ workAt = (Ms 20); handoffAt = (Ms 10); handoffPath = (Handoff 'e') } @{ lastTurnAt = (Ms 10); role = 'worker' }
    # f: its record names a handoff that is gone, and it took turns                              -> cannot be brought back, says why
    Entry 'f' $lf; Guard 'f' $lf @{ workAt = (Ms 40); handoffAt = (Ms 45); handoffPath = "$($root -replace '\\', '/')/handoffs/gone.md" } @{ lastTurnAt = (Ms 40) }
    # 1: its record was last written 110 h ago                                                   -> out of the window, as an old transcript is
    Entry '1' $wk; Guard '1' $wk @{ workAt = (Ms 6620); handoffAt = (Ms 6610); handoffPath = (Handoff 'o') } @{ lastTurnAt = (Ms 6610); updatedAt = (Ms 6600) }
    # 2: its record written an hour ago, its last turn 80 h ago, with a handoff                  -> the idle note; -MaxAgeHours 90 offers it
    Entry '2' $wk; Guard '2' $wk @{ workAt = (Ms 4820); handoffAt = (Ms 4810); handoffPath = (Handoff 'i') } @{ lastTurnAt = (Ms 4800); updatedAt = (Ms 60) }
    # 3: its record says it ended, though the registry missed that                               -> not offered
    Entry '3' $wk; Guard '3' $wk @{ workAt = (Ms 20); handoffAt = (Ms 10); handoffPath = (Handoff 'x') } @{ lastTurnAt = (Ms 10); endedAt = (Ms 5); endReason = 'other' }
    # 4: running right now, with a handoff                                                       -> offered only -AsIfRestarted
    Entry '4' $wk $noTx @{ pid = $proc.Id }; Guard '4' $wk @{ workAt = (Ms 20); handoffAt = (Ms 10); handoffPath = (Handoff 'l') } @{ lastTurnAt = (Ms 10) }
    # 5: an ordinary session with a transcript                                                   -> planned by acct-sync, resumed
    Entry '5' $wk (Transcript '5')
    # 6: no turn in its record, but Cache Keeper saw 213k of context: it worked, no handoff      -> cannot be brought back
    Entry '6' $lf; Guard '6' $lf; CkRecord '6' 'Big first turn' 213000
    # 7: its first turn was still running when it stopped (busy, no lastTurnAt yet), no handoff  -> cannot be brought back
    Entry '7' $lf; Guard '7' $lf @{} @{ busy = $true }

    $env:CRESTORE_ROOT = $root
    $env:CRESTORE_GUARD_DIR = $guard
    $env:CRESTORE_CACHE_KEEPER_DIR = $ck
    $env:CRESTORE_ACCT_SYNC = $fakeAcct
    $env:NOTX_ACCT_LOG = $acctLog
    $env:FAKE_EXE_LOG = $log
    $env:NO_COLOR = '1'
    function Run([string[]]$a) { pwsh -NoProfile -File $script @a 2>&1 | ForEach-Object { "$_" } }
    # the sessions a dry run would start: one command line each, with the id at its end
    function Started([string[]]$out) { @($out | Where-Object { $_ -like 'wt -w *' } | ForEach-Object { if ($_ -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})[^0-9a-f]*$') { $Matches[1] } } | Sort-Object) }
    function Want([string[]]$cs) { @($cs | ForEach-Object { Id $_ } | Sort-Object) }

    # ---- the list
    $list = Run @('-List')
    $list | ForEach-Object { '  ' + $_ }
    $lt = $list -join "`n"
    Check 'a: offered from its own handoff, named by Cache Keeper, with the handoff''s time' ($lt -match ([regex]::Escape('"Fix the widget"  from its handoff (no transcript), handoff from ' + (Clock (Ms 10))) + '\s'))
    Check 'b: offered from its own handoff, named by its heading, with the turns after it' ($lt -match [regex]::Escape('"Tune the parser"  from its handoff (no transcript), handoff from ' + (Clock (Ms 60)) + ', 3 turns after it'))
    Check '5: the session with a transcript is listed as before' ($lt -match '"planned by the stand-in"')
    Check 'what "from its handoff (no transcript)" means is said once' (@($list | Where-Object { $_ -like 'from its handoff (no transcript) = *' }).Count -eq 1)
    Check 'the ones that cannot be brought back are listed, with a count' ($lt -match 'Cannot be brought back: no transcript and no handoff \(4\):')
    foreach ($c in 'c', 'f', '6', '7') {
        Check "${c}: listed with its folder and last-active time" (@($list | Where-Object { $_ -match "^\s+proj-lost\s+last active .+\)\s+$(Short $c)" }).Count -eq 1)
    }
    Check 'c: its last-active time is its last turn' ($lt -match "last active $([regex]::Escape((Clock (Ms 30)))) \(30m ago\)\s+$(Short 'c') `"Lost work`"")
    Check 'f: says the handoff its record names is gone' ($lt -match 'the handoff its handoff-guard record names is gone: .+/handoffs/gone\.md')
    # (handoff-guard's default command: the config folder sets no other)
    Check 'and what keeps a session from that while it is open' ($lt -match 'a handoff written in it \(/hub-handoff there, or crestore -Prepare: -IncludeCold when its cache is cold\) is what can bring it back')
    Check 'd: counted as never used' ($lt -match 'Not offered: 1 session\(s\) that saved no transcript and never took a turn, so nothing is in them \(work 1\)\.')
    Check 'e: the hub worker is left to its hub' ($lt -match 'Not offered: 1 hub worker session\(s\) that saved no transcript')
    Check '2: the idle note counts it, and names a window that offers it' ($lt -match 'Not offered: 1 session\(s\) whose last turn was before the window.+-MaxAgeHours 8[1-3] offers them too')
    Check '1, 3 and 4 are not named anywhere (out of the window, ended, running)' (-not ($lt -match "$(Short '1')|$(Short '3')|$(Short '4')"))

    # ---- a dry run with -From resume: a session that saved no transcript still comes back from its handoff
    Remove-Item $acctLog -ErrorAction SilentlyContinue
    $dry = Run @('-All', '-DryRun', '-From', 'resume')
    $dt = $dry -join "`n"
    Check 'the dry run starts a, b and 5, nothing else' ((Started $dry) -join ',' -eq ((Want 'a', 'b', '5') -join ',')) ((Started $dry) -join ',')
    Check 'a and b by the handoff launcher, whatever -From says' (@($dry | Where-Object { $_ -like 'wt -w *' -and $_ -match "Start-HandoffSession\.ps1' ($(Id 'a')|$(Id 'b'))" }).Count -eq 2)
    Check '5 by claude --resume' ($dt -match "-Command `"claude [^`"]*--resume $(Id '5')`"")
    $runsA = @($dry | Where-Object { $_ -like '*which runs: claude*' -and $_ -like "*$hA*" })
    Check 'a: its claude gets its name and a pointer to its own handoff' ($runsA.Count -eq 1 -and $runsA[0] -match "-n 'Fix the widget'" -and $runsA[0] -match 'whose conversation was not saved') ($dry | Where-Object { $_ -like '*which runs*' })
    $runsB = @($dry | Where-Object { $_ -like '*which runs: claude*' -and $_ -like "*$hB*" })
    Check 'b: its pointer says the handoff can be behind (3 turns)' ($runsB.Count -eq 1 -and $runsB[0] -match 'went on for 3 turns after it wrote that file')
    $asked = if (Test-Path $acctLog) { Get-Content -LiteralPath $acctLog -Raw } else { '' }
    Check 'acct-sync is asked about 5 only: it reads transcripts' ($asked -match "--mode resume $(Id '5')" -and $asked -notmatch "$(Id 'a')|$(Id 'b')") $asked

    # ---- the window
    $w90 = Run @('-All', '-DryRun', '-MaxAgeHours', '90')
    Check '-MaxAgeHours 90: 2 is offered too, 1 is not' ((Started $w90) -join ',' -eq ((Want 'a', 'b', '2', '5') -join ',')) ((Started $w90) -join ',')
    $w200 = Run @('-All', '-DryRun', '-MaxAgeHours', '200')
    Check '-MaxAgeHours 200: 1 as well' ((Started $w200) -join ',' -eq ((Want 'a', 'b', '1', '2', '5') -join ',')) ((Started $w200) -join ',')

    # ---- -AsIfRestarted: running sessions count as closed; it never starts anything
    $air = Run @('-AsIfRestarted', '-List')
    $airText = $air -join "`n"
    Check '-AsIfRestarted -List: says what it does' ($airText -match 'As if this machine had just restarted')
    Check '-AsIfRestarted -List: the running one is offered from its handoff' ($airText -match "$(Short '4')  from its handoff \(no transcript\)")
    Remove-Item $log -ErrorAction SilentlyContinue
    $airRun = Run @('-AsIfRestarted', '-All')
    Check '-AsIfRestarted without -DryRun: runs as a dry run, says so, starts nothing' ((($airRun -join "`n") -match 'starts nothing: it runs as -DryRun') -and -not (Test-Path $log) -and -not (Test-Path "$root\wake"))
    Check '-AsIfRestarted: the running one is among those it would start' ((Started $airRun) -contains (Id '4'))
    $airPrep = Run @('-AsIfRestarted', '-Prepare')
    Check '-AsIfRestarted -Prepare: refused, nothing asked' ((($airPrep -join "`n") -match '-AsIfRestarted goes with a restore listing') -and -not (Test-Path "$guard\request.json"))

    # ---- -HandoffOnly with no acct-sync: the ones with their own handoff still start
    $env:CRESTORE_ACCT_SYNC = Join-Path $root 'no-such-acct-sync.mjs'
    $ho = Run @('-All', '-DryRun', '-From', 'handoff', '-HandoffOnly')
    $hoText = $ho -join "`n"
    Check '-HandoffOnly, no acct-sync: says only the ones with their own handoff start' ($hoText -match 'with -HandoffOnly only the 2 that come back from their own handoff are started')
    Check '-HandoffOnly, no acct-sync: a and b start, 5 stays closed' ((Started $ho) -join ',' -eq ((Want 'a', 'b') -join ',') -and $hoText -match 'stays closed: acct-sync has no plan for it') ((Started $ho) -join ',')
    $env:CRESTORE_ACCT_SYNC = $fakeAcct

    # ---- the real run, into the scratch root: wake files, tabs, and what a tab starts
    Remove-Item $log -ErrorAction SilentlyContinue
    $real = Run @('-All', '-From', 'resume')
    $real | ForEach-Object { '  ' + $_ }
    $realText = $real -join "`n"
    function Read-Blocks {
        $blocks = @(); $cur = $null
        foreach ($line in (Get-Content -LiteralPath $log -Encoding UTF8)) {
            if ($line.StartsWith('### ')) { $h = $line.Substring(4).Split([char]0x1f); $cur = [pscustomobject]@{ exe = $h[0]; cwd = $h[1]; wake = $h[2]; args = [System.Collections.Generic.List[string]]::new() } }
            elseif ($line -eq '###end') { $blocks += $cur; $cur = $null }
            elseif ($cur) { $cur.args.Add($line) }
        }
        return $blocks
    }
    $wtCalls = @(if (Test-Path $log) { Read-Blocks | Where-Object exe -eq 'wt' })
    Check 'the real run opens a tab for a, b and 5' ($wtCalls.Count -eq 3) "$($wtCalls.Count) tabs"
    Check 'and says how each came back' ($realText -match '1 resumed, 2 from a handoff \(2 of them from their own, having saved no transcript\)')
    foreach ($c in 'a', 'b') {
        $wf = Join-Path "$root\wake" "$(Id $c).json"
        $j = if (Test-Path $wf) { Get-Content -LiteralPath $wf -Raw | ConvertFrom-Json } else { $null }
        $want = if ($c -eq 'a') { $hA } else { $hB }
        Check "${c}: its wake file names its own handoff and says it saved no transcript" ($j -and $j.no_transcript -eq $true -and "$($j.pack)" -eq $want -and $j.session_id -eq (Id $c) -and $j.cwd -eq $wk)
        Check "${c}: the last argument is the pointer to that handoff" ($j -and @($j.args)[-2] -eq '--append-system-prompt' -and @($j.args)[-1] -like "*'$want'*" -and @($j.args)[-1] -notmatch '["`$]')
    }
    Check '5: no wake file: it is resumed' (-not (Test-Path (Join-Path "$root\wake" "$(Id '5').json")))
    # a's tab, as Windows Terminal would start it
    Remove-Item $log -ErrorAction SilentlyContinue
    $tab = (pwsh -NoProfile -Command "& '$launcher' $(Id 'a')" 2>&1 | ForEach-Object { "$_" }) -join ' / '
    $cl = @(if (Test-Path $log) { Read-Blocks | Where-Object exe -eq 'claude' })
    $ja = Get-Content -LiteralPath (Join-Path "$root\wake" "$(Id 'a').json") -Raw | ConvertFrom-Json
    Check 'a''s tab starts claude once, with the wake file''s arguments, in its folder' ($cl.Count -eq 1 -and ((@($cl[0].args) -join "`n") -eq (@($ja.args) -join "`n")) -and $cl[0].wake -eq (Id 'a') -and $cl[0].cwd -eq $wk) $tab
    Check 'a''s tab offers no resume: its conversation was never saved' ($tab -match 'never saved' -and $tab -notmatch 'claude --resume') $tab
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    $env:PATH = $oldPath
    Remove-Item Env:CRESTORE_ROOT, Env:CRESTORE_GUARD_DIR, Env:CRESTORE_CACHE_KEEPER_DIR, Env:CRESTORE_ACCT_SYNC, Env:NOTX_ACCT_LOG, Env:FAKE_EXE_LOG -ErrorAction SilentlyContinue
}
"failures: $fail"
exit $fail
