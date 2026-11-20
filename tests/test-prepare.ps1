# crestore -Prepare: which open sessions it asks, how it reads their handoff-guard answers, what it says, and its
# restart question. Nothing real is asked or restarted: a scratch registry and a scratch guard folder
# (CRESTORE_GUARD_DIR) stand in for the real ones, idle hidden node processes stand in for live claude processes,
# the answers are written here the way the plugin writes them, and the restart command is the stand-in exe. A config
# folder of its own (CLAUDE_CONFIG_DIR) holds a settings.json that sets handoff-guard's `command`, which the lines that
# tell you to write a handoff by hand name; -HandoffCommand overrides it.
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scratch.ps1')   # $S, the work folder; $TestConfig
$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'Restore-ClaudeSessions.ps1'
$root   = Join-Path $S 'prepare-root'
$guard  = Join-Path $root 'guard'
$reboot = Join-Path $S 'fake-reboot'
$log    = Join-Path $S 'fake-reboot.log'
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $log -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$root\registry", "$root\t", "$root\work", "$guard\live" -Force | Out-Null
$fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') { if ($ok) { "ok    $what" } else { $script:fail++; "FAIL  $what  $detail" } }

# The restart stand-in: the shared stand-in exe, copied under the name the script runs, in a folder of its own and
# never on PATH.
& (Join-Path $PSScriptRoot 'fake-exe.ps1') -Dir (Join-Path $S 'fake')
New-Item -ItemType Directory $reboot -Force | Out-Null
Copy-Item (Join-Path $S 'fake\wt.exe') (Join-Path $reboot 'shutdown.exe') -Force

# Six live "claude" processes: node sitting idle, hidden. Ended by their own ids at the end. (Start-Process joins its
# arguments with spaces and quotes none, so the script has no space in it.)
$procs = @(1..6 | ForEach-Object { Start-Process node -ArgumentList '-e', 'setInterval(()=>0,1e9)' -WindowStyle Hidden -PassThru })
Start-Sleep -Milliseconds 500
if (@($procs | Where-Object { $_.HasExited }).Count) { throw 'a stand-in node process exited at once' }
try {
    $turn = '{"type":"user","message":{"role":"user","content":"hello there"}}'
    function Id([string]$c) { ($c * 8) + '-' + ($c * 4) + '-4' + ($c * 3) + '-8' + ($c * 3) + '-' + ($c * 12) }
    function Entry([string]$c, [int]$procId, [hashtable]$more = @{}) {
        $p = Join-Path "$root\t" "$c.jsonl"; Set-Content -LiteralPath $p -Value ($turn -replace 'hello there', "session $c") -Encoding utf8
        $e = [ordered]@{ session_id = (Id $c); cwd = "$root\work"; transcript_path = $p; source = 'startup'; started_at = (Get-Date).ToString('o'); pid = $procId; claude_cmdline = 'claude.exe' }
        foreach ($k in $more.Keys) { $e[$k] = $more[$k] }
        $e | ConvertTo-Json | Set-Content -LiteralPath (Join-Path "$root\registry" "$(Id $c).json") -Encoding utf8
    }
    function Record([string]$c, [hashtable]$request, [bool]$upToDate = $true) {
        $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $r = [ordered]@{
            v = 1; sid = (Id $c); upToDate = $upToDate; updatedAt = $ms
            track = [ordered]@{ workAt = $ms - 60000; handoffAt = $ms; handoffPath = "C:/Users/test/.claude/handoffs/x/$c.md"; turnsAfter = 0 }
            request = $request; endedAt = $null; endReason = $null
        }
        return ($r | ConvertTo-Json -Depth 4)
    }
    function Put([string]$c, [string]$text) { Set-Content -LiteralPath (Join-Path "$guard\live" "$(Id $c).json") -Value $text -Encoding utf8 }

    # a: written (its record a week old) · b: current · c: skipped (cold) · d: no guard · e: writing, then written ·
    # h: answers late, after its grace, while e still holds the wait open · f: an older session in a's process (not
    # asked) · 1: ended (not asked) · 2: its process is no claude (not asked)
    Entry 'a' $procs[0].Id
    Entry 'b' $procs[1].Id
    Entry 'c' $procs[2].Id
    Entry 'd' $procs[3].Id
    Entry 'e' $procs[4].Id
    Entry 'h' $procs[5].Id
    Entry 'f' $procs[0].Id @{ started_at = (Get-Date).AddHours(-2).ToString('o') }
    Entry '1' $procs[1].Id @{ ended_at = (Get-Date).ToString('o'); end_reason = 'prompt_input_exit' }
    Entry '2' 4
    $at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Put 'a' (Record 'a' @{ id = 'test-r1'; state = 'written'; at = $at; path = 'C:/Users/test/.claude/handoffs/x/a.md' })
    Put 'b' (Record 'b' @{ id = 'test-r1'; state = 'current'; at = $at; path = 'C:/Users/test/.claude/handoffs/x/b.md' })
    Put 'c' (Record 'c' @{ id = 'test-r1'; state = 'skipped'; at = $at; why = 'its prompt cache is cold, so a handoff now re-reads 250k tokens at the full price' } $false)
    Put 'e' (Record 'e' @{ id = 'test-r1'; state = 'writing'; at = $at })
    Put 'h' (Record 'h' @{ id = 'an-older-request'; state = 'current'; at = 1 })
    # a week-old record of a session long gone: removed; a's, as old but its session open: kept
    Put 'z' (Record 'z' @{ id = 'old'; state = 'current'; at = 1 })
    (Get-Item (Join-Path "$guard\live" "$(Id 'z').json")).LastWriteTime = (Get-Date).AddDays(-8)
    (Get-Item (Join-Path "$guard\live" "$(Id 'a').json")).LastWriteTime = (Get-Date).AddDays(-9)

    # handoff-guard's settings as Claude Code keeps them: pluginConfigs."<plugin>@<marketplace>".options.
    $cfg = Join-Path $root 'config'
    New-Item -ItemType Directory $cfg -Force | Out-Null
    '{ "pluginConfigs": { "other@market": { "options": { "command": "not-this" } }, "handoff-guard@some-market": { "options": { "command": "session-handoff" } } } }' |
        Set-Content -LiteralPath (Join-Path $cfg 'settings.json') -Encoding utf8
    $env:CLAUDE_CONFIG_DIR = $cfg
    $env:CRESTORE_ROOT = $root
    $env:CRESTORE_GUARD_DIR = $guard
    $env:CRESTORE_ACCT_SYNC = Join-Path $root 'no-such-acct-sync.mjs'
    $env:CRESTORE_REBOOT_CMD = Join-Path $reboot 'shutdown.exe'
    $env:FAKE_EXE_LOG = $log
    $env:NO_COLOR = '1'
    Remove-Item Env:CRESTORE_REBOOT_ANSWER -ErrorAction SilentlyContinue

    # ---- the dry run asks nothing
    $dry = pwsh -NoProfile -File $script -Prepare -DryRun -Reboot 2>&1 | ForEach-Object { "$_" }
    $dryText = $dry -join "`n"
    Check '-DryRun writes no request'                    (-not (Test-Path (Join-Path $guard 'request.json')))
    Check '-DryRun shows a session with no guard'        ($dryText -match "no guard\s+$((Id 'd').Substring(0, 8))")
    Check '-DryRun shows a stale one'                    ($dryText -match "stale\s+$((Id 'c').Substring(0, 8))")
    Check '-DryRun shows its last handoff'               ($dryText -match 'last handoff .*handoffs/x/a\.md')
    Check '-DryRun never restarts'                       (($dryText -match 'Not restarting: -DryRun') -and -not (Test-Path $log))

    # ---- the real run, with a 2 s grace: h answers 4 s in (late), e turns final 6 s in, d never answers
    $ePath = Join-Path "$guard\live" "$(Id 'e').json"
    $eDone = Record 'e' @{ id = 'test-r1'; state = 'written'; at = $at; path = 'C:/Users/test/.claude/handoffs/x/e.md' }
    $hPath = Join-Path "$guard\live" "$(Id 'h').json"
    $hDone = Record 'h' @{ id = 'test-r1'; state = 'written'; at = $at; path = 'C:/Users/test/.claude/handoffs/x/h.md' }
    $job = Start-Job -ScriptBlock {
        param($hp, $ht, $ep, $et)
        Start-Sleep -Milliseconds 4000; Set-Content -LiteralPath $hp -Value $ht -Encoding utf8
        Start-Sleep -Milliseconds 2000; Set-Content -LiteralPath $ep -Value $et -Encoding utf8
    } -ArgumentList $hPath, $hDone, $ePath, $eDone
    $env:CRESTORE_PREPARE_ID = 'test-r1'
    $env:CRESTORE_PREPARE_GRACE_S = '2'
    $t0 = Get-Date
    $out = pwsh -NoProfile -File $script -Prepare -PrepareMinutes 0.15 2>&1 | ForEach-Object { "$_" }
    $took = ((Get-Date) - $t0).TotalSeconds
    $job | Wait-Job -Timeout 20 | Out-Null; $job | Remove-Job -Force
    $out | ForEach-Object { '  ' + $_ }
    $text = $out -join "`n"
    $req = Get-Content -Raw (Join-Path $guard 'request.json') | ConvertFrom-Json
    $want = @('a', 'b', 'c', 'd', 'e', 'h' | ForEach-Object { Id $_ }) | Sort-Object
    Check 'the request names this run'                   ($req.id -eq 'test-r1' -and $req.reason -eq 'restart' -and $req.includeCold -eq $false)
    Check 'it asks the open sessions, one per process'   ((@($req.sids | Sort-Object) -join ',') -eq ($want -join ',')) "asked: $($req.sids -join ',')"
    Check 'its time is UTC with milliseconds'            ((Get-Content -Raw (Join-Path $guard 'request.json')) -match '"at":\s*"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z"')
    Check 'a: written, with its path'                    ($text -match "written\s+$((Id 'a').Substring(0, 8))" -and $text -match 'handoffs/x/a\.md')
    Check 'b: current'                                   ($text -match "current\s+$((Id 'b').Substring(0, 8))")
    Check 'c: skipped, with why'                         ($text -match "skipped\s+$((Id 'c').Substring(0, 8))" -and $text -match 'prompt cache is cold')
    Check 'd: no answer, no guard in it'                 ($text -match "NO ANSWER\s+$((Id 'd').Substring(0, 8))" -and $text -match 'no handoff-guard in it')
    Check 'e: waited for, then written'                  ($text -match "written\s+$((Id 'e').Substring(0, 8))")
    Check 'h: answered after its grace, and still read'  ($text -match "written\s+$((Id 'h').Substring(0, 8))" -and $text -match 'handoffs/x/h\.md')
    Check 'the count'                                    ($text -match '4 of 6 have an up-to-date handoff')
    Check 'what to do about the rest, naming handoff-guard''s command setting' ($text -match '-IncludeCold' -and $text -match 'run /session-handoff in that session by hand') ($out | Select-String 'by hand' | Out-String)
    Check 'it waited for d no longer than the run allows' ($took -lt 25) "took $took s"
    Check 'no restart question without -Reboot'          (-not (Test-Path $log))
    Check 'a week-old record goes, an open session keeps its own' ((-not (Test-Path (Join-Path "$guard\live" "$(Id 'z').json"))) -and (Test-Path (Join-Path "$guard\live" "$(Id 'a').json")))

    # ---- -IncludeCold -Reboot, answered no
    $env:CRESTORE_PREPARE_ID = 'test-r2'
    $env:CRESTORE_REBOOT_ANSWER = 'n'
    $no = pwsh -NoProfile -File $script -Prepare -IncludeCold -Reboot -PrepareMinutes 0.05 -HandoffCommand /my-handoff 2>&1 | ForEach-Object { "$_" }
    $req2 = Get-Content -Raw (Join-Path $guard 'request.json') | ConvertFrom-Json
    Check '-IncludeCold goes in the request'             ($req2.id -eq 'test-r2' -and $req2.includeCold -eq $true)
    Check 'an answer to another request is no answer'    (($no -join "`n") -match "NO ANSWER\s+$((Id 'a').Substring(0, 8))" -and ($no -join "`n") -match 'its handoff-guard did not answer')
    Check '-HandoffCommand wins over the setting, without its slash' (($no -join "`n") -match 'run /my-handoff in that session by hand') ($no | Select-String 'by hand' | Out-String)
    Check 'answered no: nothing restarts'                ((($no -join "`n") -match 'Not restarting\.') -and -not (Test-Path $log))

    # ---- answered yes: the restart command runs, in 60 s, with the way to cancel it
    $env:CRESTORE_PREPARE_ID = 'test-r3'
    $env:CRESTORE_REBOOT_ANSWER = 'y'
    $yes = pwsh -NoProfile -File $script -Prepare -Reboot -PrepareMinutes 0.05 2>&1 | ForEach-Object { "$_" }
    $ran = if (Test-Path $log) { Get-Content -Raw $log } else { '' }
    Check 'answered yes: shutdown /r /t 60 runs'         ($ran -match '### shutdown' -and $ran -match "(?m)^/r\r?$" -and $ran -match "(?m)^60\r?$") $ran
    Check 'and it says how to cancel'                    (($yes -join "`n") -match 'shutdown /a cancels')

    # ---- nothing open: nothing asked
    $empty = Join-Path $S 'prepare-empty'
    Remove-Item $empty -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory "$empty\registry" -Force | Out-Null
    $env:CRESTORE_ROOT = $empty
    $env:CRESTORE_GUARD_DIR = Join-Path $empty 'guard'
    Remove-Item Env:CRESTORE_REBOOT_ANSWER -ErrorAction SilentlyContinue
    $none = pwsh -NoProfile -File $script -Prepare 2>&1 | ForEach-Object { "$_" }
    Check 'no open session: says so and asks nothing'    ((($none -join "`n") -match 'No open Claude sessions') -and -not (Test-Path (Join-Path $empty 'guard\request.json')))
} finally {
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:CRESTORE_ROOT, Env:CRESTORE_GUARD_DIR, Env:CRESTORE_ACCT_SYNC, Env:CRESTORE_REBOOT_CMD, Env:CRESTORE_REBOOT_ANSWER, Env:CRESTORE_PREPARE_ID, Env:CRESTORE_PREPARE_GRACE_S, Env:FAKE_EXE_LOG -ErrorAction SilentlyContinue
    $env:CLAUDE_CONFIG_DIR = $TestConfig
}
"failures: $fail"
exit $fail
