# Which sessions crestore offers once one has been carried on from a handoff. Synthetic registry in a scratch root;
# transcripts are small files written here. Uses -List and -DryRun only, so nothing is spawned or written elsewhere. A
# dry run can still ask `claude --help` whether --effort exists: scratch.ps1 puts the stand-in claude first in PATH.
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scratch.ps1')   # $S, the work folder
$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'Restore-ClaudeSessions.ps1'
$root = Join-Path $S 'taken-root'
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$root\registry", "$root\t", "$root\work" -Force | Out-Null
$fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') { if ($ok) { "ok    $what" } else { $script:fail++; "FAIL  $what  $detail" } }

$turn  = '{"type":"user","message":{"role":"user","content":"hello there"}}' + "`n" + '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}'
$empty = '{"type":"user","message":{"role":"user","content":"never answered"}}'
# Transcripts of the older sessions were last written an hour ago (before the restart); the handoff sessions were
# launched half an hour ago, the way hook.ps1 records it.
$launched = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')
function Transcript([string]$name, [string]$body, [int]$minutesAgo = 60) {
    $p = Join-Path "$root\t" "$name.jsonl"; Set-Content -LiteralPath $p -Value $body -Encoding utf8
    (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddMinutes(-$minutesAgo)
    return $p
}
function Entry([string]$id, [string]$transcript, [hashtable]$more = @{}) {
    $e = [ordered]@{ session_id = $id; cwd = "$root\work"; transcript_path = $transcript; source = 'startup'; started_at = (Get-Date).ToString('o'); pid = 4; claude_cmdline = 'claude.exe --dangerously-skip-permissions' }
    foreach ($k in $more.Keys) { $e[$k] = $more[$k] }
    $e | ConvertTo-Json | Set-Content -LiteralPath (Join-Path "$root\registry" "$id.json") -Encoding utf8
}
function Id([string]$c) { ($c * 8) + '-' + ($c * 4) + '-4' + ($c * 3) + '-8' + ($c * 3) + '-' + ($c * 12) }
# pid 4 is the System process: alive, but not a claude, so the entry counts as closed. An idle hidden node process
# stands in for a claude that is open right now (crestore counts a claude or node process as one); stopped at the end.
$liveProc = Start-Process node -ArgumentList '-e', 'setInterval(()=>0,1e9)' -WindowStyle Hidden -PassThru
$liveClaude = $liveProc.Id
trap { if ($liveProc) { Stop-Process -Id $liveProc.Id -Force -ErrorAction SilentlyContinue }; break }

# A: carried on by a session that took a turn and is closed (not cleanly)      -> A hidden, its successor offered
Entry (Id 'a') (Transcript 'a' $turn)
Entry (Id '1') (Transcript '1' $turn 5) @{ continues = (Id 'a'); continued_at = $launched }
# B: its successor never got a prompt (no transcript), and is gone             -> B offered again, the successor not
Entry (Id 'b') (Transcript 'b' $turn)
Entry (Id '2') (Join-Path "$root\t" 'missing.jsonl') @{ continues = (Id 'b'); continued_at = $launched }
# C: its successor is open in a terminal right now and has not taken a turn    -> C hidden
Entry (Id 'c') (Transcript 'c' $turn)
if ($liveClaude) { Entry (Id '3') (Transcript '3' $empty 5) @{ continues = (Id 'c'); continued_at = $launched; pid = $liveClaude } }
# D: its successor took a turn and was then closed cleanly (/clear, exit)      -> D hidden, the successor not offered
Entry (Id 'd') (Transcript 'd' $turn)
Entry (Id '5') (Transcript '5' $turn 5) @{ continues = (Id 'd'); continued_at = $launched; ended_at = (Get-Date).ToString('o'); end_reason = 'clear' }
# E: nothing carries it on                                                    -> E offered
Entry (Id 'e') (Transcript 'e' $turn)
# F: its successor has a transcript with a prompt but no reply yet, and is gone -> F offered again
Entry (Id 'f') (Transcript 'f' $turn)
Entry (Id '6') (Transcript '6' $empty 5) @{ continues = (Id 'f'); continued_at = $launched }
# G: its successor took a turn, but G itself was resumed by hand and written to after that -> both offered
Entry (Id '0') (Transcript '0' $turn 10)
Entry (Id '7') (Transcript '7' $turn 20) @{ continues = (Id '0'); continued_at = $launched }
# H: as G, and a claude started later from inside the successor carries the link too (same launch time) -> H still offered
Entry (Id '8') (Transcript '8' $turn 10)
Entry (Id '9') (Transcript '9' $turn 20) @{ continues = (Id '8'); continued_at = $launched }
Entry '99999999-0000-4000-8000-999999999999' (Transcript '9w' $turn 2) @{ continues = (Id '8'); continued_at = $launched }
# I: a successor entry from before continued_at existed (no time recorded)     -> the older one stays hidden
Entry 'abababab-abab-4bab-8bab-abababababab' (Transcript 'i' $turn 10)
Entry 'cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd' (Transcript 'i2' $turn 5) @{ continues = 'abababab-abab-4bab-8bab-abababababab' }

# Successors that saved no transcript (a claude that inherited CLAUDE_CODE_CHILD_SESSION): whether one took a turn is
# in its handoff-guard record (a scratch guard folder here, as in the plugin: live/<sid>.json).
$guard = Join-Path $root 'guard'
New-Item -ItemType Directory "$guard\live", "$root\handoffs" -Force | Out-Null
$msNow = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
function Guard([string]$id, [hashtable]$track, [hashtable]$more = @{}) {
    $r = [ordered]@{ v = 1; sid = $id; cwd = "$root\work"; role = $null; startedAt = $msNow - 3600000; updatedAt = $msNow - 60000; upToDate = $true
        track = [ordered]@{ workAt = 0; handoffAt = 0; handoffPath = $null; turnsAfter = 0 }; busy = $false; pending = $null; request = $null
        lastTurnAt = 0; ctxTokens = $null; endedAt = $null; endReason = $null }
    foreach ($k in $track.Keys) { $r.track[$k] = $track[$k] }
    foreach ($k in $more.Keys) { $r[$k] = $more[$k] }
    $r | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path "$guard\live" "$id.json") -Encoding utf8
}
function Handoff([string]$name) { $p = Join-Path "$root\handoffs" "$name.md"; Set-Content -LiteralPath $p -Value "# handoff $name" -Encoding utf8; return ($p -replace '\\', '/') }
$noTx = Join-Path "$root\t" 'never-written.jsonl'
$J = 'cafe0001-0000-4000-8000-00000000000a'; $Js = 'cafe0001-0000-4000-8000-0000000000aa'
$K = 'cafe0002-0000-4000-8000-00000000000a'; $Ks = 'cafe0002-0000-4000-8000-0000000000aa'
$L = 'cafe0003-0000-4000-8000-00000000000a'; $Ls = 'cafe0003-0000-4000-8000-0000000000aa'
$M = 'cafe0004-0000-4000-8000-00000000000a'; $Ms = 'cafe0004-0000-4000-8000-0000000000aa'
$N = 'cafe0005-0000-4000-8000-00000000000a'; $Ns = 'cafe0005-0000-4000-8000-0000000000aa'
# J: its successor saved no transcript, took turns (lastTurnAt) and wrote a handoff  -> J hidden, the successor offered
Entry $J (Transcript 'j' $turn)
Entry $Js $noTx @{ continues = $J; continued_at = $launched }
Guard $Js @{ workAt = $msNow - 600000; handoffAt = $msNow - 300000; handoffPath = (Handoff 'js') } @{ lastTurnAt = $msNow - 300000 }
# K: its successor saved no transcript; only track.workAt says it worked; no handoff -> K hidden, the successor not offered
Entry $K (Transcript 'k' $turn)
Entry $Ks $noTx @{ continues = $K; continued_at = $launched }
Guard $Ks @{ workAt = $msNow - 600000; turnsAfter = 2 }
# L: its successor saved no transcript and its record shows no turn                  -> L offered again, the successor not
Entry $L (Transcript 'l' $turn)
Entry $Ls $noTx @{ continues = $L; continued_at = $launched }
Guard $Ls @{}
# M: the older one saved no transcript and its record has a turn after its successor started -> both offered
Entry $M $noTx
Guard $M @{ workAt = $msNow - 120000; handoffAt = $msNow - 60000; handoffPath = (Handoff 'm') } @{ lastTurnAt = $msNow - 60000 }
Entry $Ms (Transcript 'ms' $turn 20) @{ continues = $M; continued_at = $launched }
# N: its successor saved no transcript and its first turn is still running (busy, no lastTurnAt yet) -> N hidden
Entry $N (Transcript 'n' $turn)
Entry $Ns $noTx @{ continues = $N; continued_at = $launched }
Guard $Ns @{} @{ busy = $true }

$env:CRESTORE_ROOT = $root
$env:CRESTORE_ACCT_SYNC = Join-Path $root 'no-such-acct-sync.mjs'   # the list must also work with no plan at all
$env:CRESTORE_GUARD_DIR = $guard                                      # never the real records
$env:CRESTORE_CACHE_KEEPER_DIR = Join-Path $root 'cache-keeper'
$env:NO_COLOR = '1'
$out = pwsh -NoProfile -File $script -List 2>&1 | ForEach-Object { "$_" }
$out | ForEach-Object { '  ' + $_ }
# with no plan the list prints the title from the transcript, so tell sessions apart by a dry run, which prints one
# command per offered session, with its id (a note about one that is not offered can name an id too)
$ids = @{}
$all = Get-ChildItem "$root\registry" -Filter *.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }
$dry = pwsh -NoProfile -File $script -All -DryRun 2>&1 | ForEach-Object { "$_" }
$cmds = @($dry | Where-Object { $_ -like 'wt -w *' })
foreach ($e in $all) { $ids[$e.session_id] = [bool]($cmds -match [regex]::Escape($e.session_id)) }
function Offered([string]$c) { if ($c.Length -gt 1) { [bool]$ids[$c] } else { [bool]$ids[(Id $c)] } }

Check 'A (successor took a turn): hidden'                    (-not (Offered 'a'))
Check 'A''s successor: offered'                              (Offered '1')
Check 'B (successor never prompted, gone): offered again'    (Offered 'b')
Check 'B''s empty successor: not offered'                    (-not (Offered '2'))
if ($liveClaude) {
    Check 'C (successor open right now): hidden'             (-not (Offered 'c'))
    Check 'C''s live successor: not offered'                 (-not (Offered '3'))
} else { Check 'C: an idle node process stands for a live successor' $false 'node did not start' }
Check 'D (successor took a turn, then closed): hidden'       (-not (Offered 'd'))
Check 'D''s closed successor: not offered'                   (-not (Offered '5'))
Check 'E (nothing carries it on): offered'                   (Offered 'e')
Check 'F (successor got a prompt but no reply): offered'     (Offered 'f')
Check 'G (used again after its successor started): offered'  (Offered '0')
Check 'G''s successor: offered too'                          (Offered '7')
Check 'H (as G, plus a later claude that inherited the link): offered' (Offered '8')
Check 'I (successor has no time recorded): hidden'           (-not [bool]$ids['abababab-abab-4bab-8bab-abababababab'])
Check 'J (successor without a transcript, its record has a last turn): hidden' (-not (Offered $J))
Check 'J''s successor: offered, from its own handoff'          ((Offered $Js) -and ($cmds -match "Start-HandoffSession\.ps1' $Js"))
Check 'K (successor without a transcript, only track.workAt in its record): hidden' (-not (Offered $K))
Check 'K''s successor (worked, no handoff): not offered'      (-not (Offered $Ks))
Check 'L (successor without a transcript, no turn in its record): offered again' (Offered $L)
Check 'L''s unused successor: not offered'                    (-not (Offered $Ls))
Check 'M (no transcript, its record has a turn after its successor started): offered' (Offered $M)
Check 'M''s successor: offered too'                           (Offered $Ms)
Check 'N (successor without a transcript, its first turn still running): hidden' (-not (Offered $N))
$listText = $out -join "`n"
Check 'the list names K''s and N''s successors as ones that cannot be brought back' ($listText -match 'Cannot be brought back: no transcript and no handoff \(2\)' -and $listText -match $Ks.Substring(0, 8) -and $listText -match $Ns.Substring(0, 8))
Check 'and says the older conversation each carried on can still be resumed' ($listText -match "it carried on $($K.Substring(0, 8)).*claude --resume $K")
Check 'the list counts L''s successor as one that never took a turn, started from a handoff' ($listText -match 'Not offered: 2 session\(s\) that saved no transcript and never took a turn' -and $listText -match '2 of them were started from a handoff') ($listText -split "`n" | Select-String 'never took a turn')
Check 'with no acct-sync the list still prints and says nothing odd' (($out -join "`n") -match 'Restorable Claude sessions' -and ($out -join "`n") -notmatch 'acct-sync')
$wantHandoff = pwsh -NoProfile -File $script -All -DryRun -From auto 2>&1 | ForEach-Object { "$_" }
# Only the two that saved no transcript come back from a handoff (their own); every other one is resumed in full.
$fromHandoff = @($wantHandoff | Where-Object { $_ -like 'wt -w *' -and $_ -match 'Start-HandoffSession' } | ForEach-Object { ($_ -split ' ')[-1].Trim('"') } | Sort-Object)
Check '-From auto with no acct-sync: says so and resumes in full' ((($wantHandoff -join "`n") -match 'no plan from acct-sync') -and (($fromHandoff -join ',') -eq ((@($Js, $M) | Sort-Object) -join ','))) ($fromHandoff -join ',')

Remove-Item Env:CRESTORE_ROOT, Env:CRESTORE_ACCT_SYNC, Env:CRESTORE_GUARD_DIR, Env:CRESTORE_CACHE_KEEPER_DIR -ErrorAction SilentlyContinue
if ($liveProc) { Stop-Process -Id $liveProc.Id -Force -ErrorAction SilentlyContinue }
"failures: $fail"
exit $fail
