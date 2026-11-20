# crestore -Prepare and open sessions that saved no transcript: none of them has a pack to come back from, so each
# one says what a restart leaves of it, and the summary lines say only what is true. As test-prepare.ps1: a scratch
# registry and a scratch guard folder (CRESTORE_GUARD_DIR), idle hidden node processes for the live claude processes,
# and the answers written here the way handoff-guard writes them. No -Reboot.
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scratch.ps1')   # $S, the work folder; an empty config folder (no handoff-guard settings)
$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'Restore-ClaudeSessions.ps1'
$root   = Join-Path $S 'prepare-notx-root'
$guard  = Join-Path $root 'guard'
$ck     = Join-Path $root 'cache-keeper'
$root2  = Join-Path $S 'prepare-notx-root2'
Remove-Item $root, $root2 -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$root\registry", "$root\t", "$root\work", "$root\handoffs", "$guard\live", "$ck\live", "$root2\registry", "$root2\guard\live" -Force | Out-Null
$fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') { if ($ok) { "ok    $what" } else { $script:fail++; "FAIL  $what  $detail" } }

$procs = @(1..7 | ForEach-Object { Start-Process node -ArgumentList '-e', 'setInterval(()=>0,1e9)' -WindowStyle Hidden -PassThru })
Start-Sleep -Milliseconds 500
if (@($procs | Where-Object { $_.HasExited }).Count) { throw 'a stand-in node process exited at once' }
try {
    $inv = [cultureinfo]::InvariantCulture
    function Id([string]$c) { ($c * 8) + '-' + ($c * 4) + '-4' + ($c * 3) + '-8' + ($c * 3) + '-' + ($c * 12) }
    function Short([string]$c) { (Id $c).Substring(0, 8) }
    $msNow = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    function Ms([double]$minutesAgo) { [long]($msNow - $minutesAgo * 60000) }
    function Day([long]$ms) { [DateTimeOffset]::FromUnixTimeMilliseconds($ms).LocalDateTime.ToString('yyyy-MM-dd HH:mm', $inv) }
    $noTx = Join-Path "$root\t" 'never-written.jsonl'
    function Entry([string]$reg, [string]$c, [int]$procId, [bool]$transcript) {
        $tp = $noTx
        if ($transcript) { $tp = Join-Path "$root\t" "$c.jsonl"; Set-Content -LiteralPath $tp -Value ('{"type":"user","message":{"role":"user","content":"session ' + $c + '"}}') -Encoding utf8 }
        [ordered]@{ session_id = (Id $c); cwd = "$root\work"; transcript_path = $tp; source = 'startup'; started_at = (Get-Date).ToString('o'); pid = $procId; claude_cmdline = 'claude.exe' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $reg "$(Id $c).json") -Encoding utf8
    }
    function Handoff([string]$name) { $p = Join-Path "$root\handoffs" "$name.md"; Set-Content -LiteralPath $p -Value "# $name" -Encoding utf8; return ($p -replace '\\', '/') }
    # a record with its answer to request test-nt
    function Put([string]$dir, [string]$c, [hashtable]$request, [hashtable]$track = @{}, [hashtable]$more = @{}) {
        $r = [ordered]@{ v = 1; sid = (Id $c); role = $null; upToDate = $false; updatedAt = (Ms 1)
            track = [ordered]@{ workAt = 0; handoffAt = 0; handoffPath = $null; turnsAfter = 0 }; busy = $false
            request = $request; lastTurnAt = 0; endedAt = $null; endReason = $null }
        foreach ($k in $track.Keys) { $r.track[$k] = $track[$k] }
        foreach ($k in $more.Keys) { $r[$k] = $more[$k] }
        $r | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dir "$(Id $c).json") -Encoding utf8
    }
    $cold = 'its prompt cache is cold, so a handoff now re-reads 250k tokens at the full price (a request with includeCold writes it anyway)'
    $at = $msNow
    $hA = Handoff 'a'; $hC = Handoff 'c'
    # a: no transcript, cold, its own handoff from an hour ago and two turns after it
    Entry "$root\registry" 'a' $procs[0].Id $false
    Put "$guard\live" 'a' @{ id = 'test-nt'; state = 'skipped'; at = $at; why = $cold } @{ workAt = (Ms 20); handoffAt = (Ms 60); handoffPath = $hA; turnsAfter = 2 } @{ lastTurnAt = (Ms 20) }
    # b: no transcript, cold, took turns, no handoff
    Entry "$root\registry" 'b' $procs[1].Id $false
    Put "$guard\live" 'b' @{ id = 'test-nt'; state = 'skipped'; at = $at; why = $cold } @{ workAt = (Ms 30) } @{ lastTurnAt = (Ms 30) }
    # c: no transcript, its handoff written for this request
    Entry "$root\registry" 'c' $procs[2].Id $false
    Put "$guard\live" 'c' @{ id = 'test-nt'; state = 'written'; at = $at; path = $hC } @{ workAt = (Ms 10); handoffAt = (Ms 2); handoffPath = $hC } @{ lastTurnAt = (Ms 2); upToDate = $true }
    # d: an ordinary session with a transcript, cold
    Entry "$root\registry" 'd' $procs[3].Id $true
    Put "$guard\live" 'd' @{ id = 'test-nt'; state = 'skipped'; at = $at; why = $cold } @{ workAt = (Ms 30) } @{ lastTurnAt = (Ms 30) }
    # e: a hub worker without a transcript
    Entry "$root\registry" 'e' $procs[4].Id $false
    Put "$guard\live" 'e' @{ id = 'test-nt'; state = 'skipped'; at = $at; why = 'a worker session: whatever runs it hands it off and brings it back' } @{ workAt = (Ms 30) } @{ lastTurnAt = (Ms 30); role = 'worker' }
    # u: no transcript, never took a turn
    Entry "$root\registry" 'u' $procs[5].Id $false
    Put "$guard\live" 'u' @{ id = 'test-nt'; state = 'current'; at = $at; why = 'nothing to hand off: no work since it started' } @{} @{ upToDate = $true }
    # g: no transcript, took turns, its guard judged its handoff current though no file was ever named
    Entry "$root\registry" 'g' $procs[6].Id $false
    Put "$guard\live" 'g' @{ id = 'test-nt'; state = 'current'; at = $at } @{ workAt = (Ms 30); handoffAt = (Ms 20) } @{ lastTurnAt = (Ms 20); upToDate = $true }

    $env:CRESTORE_ROOT = $root
    $env:CRESTORE_GUARD_DIR = $guard
    $env:CRESTORE_CACHE_KEEPER_DIR = $ck
    $env:CRESTORE_ACCT_SYNC = Join-Path $root 'no-such-acct-sync.mjs'
    $env:CRESTORE_PREPARE_ID = 'test-nt'
    $env:CRESTORE_PREPARE_GRACE_S = '1'
    $env:NO_COLOR = '1'
    Remove-Item Env:CRESTORE_REBOOT_ANSWER, Env:CRESTORE_REBOOT_CMD -ErrorAction SilentlyContinue
    # -Prepare writes its request into the guard folder: never the real one
    if (-not "$env:CRESTORE_GUARD_DIR".StartsWith($S) -or -not "$env:CRESTORE_ROOT".StartsWith($S)) { throw 'the guard folder or the root is not a scratch one' }

    # ---- the dry run marks the ones without a transcript
    $dry = pwsh -NoProfile -File $script -Prepare -DryRun 2>&1 | ForEach-Object { "$_" }
    $dryText = $dry -join "`n"
    Check '-DryRun marks each session without a transcript' (@('a', 'b', 'c', 'e', 'u', 'g' | Where-Object { $dryText -match "$(Short $_)\s.*\[no transcript\]" }).Count -eq 6 -and $dryText -notmatch "$(Short 'd')\s.*\[no transcript\]")
    Check '-DryRun says what that means' ($dryText -match '\[no transcript\]: the session saved no transcript, so after a restart only its newest handoff can bring it back')

    # ---- the run
    $out = pwsh -NoProfile -File $script -Prepare -PrepareMinutes 0.05 2>&1 | ForEach-Object { "$_" }
    $out | ForEach-Object { '  ' + $_ }
    $text = $out -join "`n"
    $fix = 'crestore -Prepare -IncludeCold fixes that, at the full price of re-reading it.'
    Check 'a (cold, no transcript): only its handoff remains, how far behind, and what fixes that' ($text -match [regex]::Escape("no transcript on disk: after a restart only its handoff from $(Day (Ms 60)) remains, 2 turns behind. $fix"))
    Check 'b (cold, no transcript, no handoff): nothing remains, and what fixes that' ($text -match [regex]::Escape("no transcript on disk and no handoff: after a restart nothing remains. $fix"))
    Check 'c (written): no warning under it' (-not ($text -match "(?s)written\s+$(Short 'c')[^\n]*\n[^\n]*\n\s+no transcript on disk"))
    Check 'no promise of a pack to a skipped session without a transcript' ($text -notmatch 'Skipped ones come back from a pack of their transcript')
    Check 'the skipped line tells the two kinds apart' ($text -match [regex]::Escape("Skipped ones with a transcript come back from a pack of it. 2 skipped one(s) saved no transcript: what remains of each after a restart is said under it. -IncludeCold writes the cold ones' handoffs too"))
    # The command it names is handoff-guard's default: the config folder sets no other (test-prepare.ps1 sets one).
    Check 'g (current, no transcript, no handoff file): nothing remains, and what fixes that' ($text -match ("(?s)current\s+$(Short 'g')[^\n]*\n\s+" + [regex]::Escape('no transcript on disk and no handoff: after a restart nothing remains. A handoff written in that session (/hub-handoff) fixes that.')))
    Check 'no advice to Pack & Clear (its pack is not a handoff to handoff-guard)' ($text -notmatch 'Pack & Clear')
    Check 'the count leaves g out, and says why' ($text -match [regex]::Escape('2 of 7 have an up-to-date handoff. 1 more answered current, but saved no transcript and have no handoff file: nothing of them remains after a restart.'))
    Check 'the closing line says what comes back of the ones without a transcript' ($text -match [regex]::Escape('After the restart: crestore -From auto brings each one with a transcript back from its handoff or its conversation, whichever fits.') -and $text -match [regex]::Escape('Of the 5 without a transcript: 2 come back from their own newest handoff, whatever -From says (1 of them without the work done after it); 2 cannot be brought back (no handoff either); 1 never took a turn, so nothing in them is lost.'))
    Check 'the hub worker gets no warning and is not counted' (-not ($text -match "(?s)skipped\s+$(Short 'e')[^\n]*\n[^\n]*\n\s+no transcript on disk"))

    # ---- only sessions with a transcript: the lines are as they were
    Entry "$root2\registry" 'd' $procs[3].Id $true
    Put "$root2\guard\live" 'd' @{ id = 'test-nt'; state = 'skipped'; at = $at; why = $cold } @{ workAt = (Ms 30) } @{ lastTurnAt = (Ms 30) }
    $env:CRESTORE_ROOT = $root2
    $env:CRESTORE_GUARD_DIR = Join-Path $root2 'guard'
    $two = (pwsh -NoProfile -File $script -Prepare -PrepareMinutes 0.05 2>&1 | ForEach-Object { "$_" }) -join "`n"
    Check 'with transcripts only: the skipped line as before' ($two -match [regex]::Escape("Skipped ones come back from a pack of their transcript. -IncludeCold writes the cold ones' handoffs too, each re-reading its conversation at the full price."))
    Check 'with transcripts only: the closing line as before, and no count of ones without' ($two -match [regex]::Escape('After the restart: crestore -From auto brings each back from its handoff or its conversation, whichever fits.') -and $two -notmatch 'without a transcript|no transcript on disk')
} finally {
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:CRESTORE_ROOT, Env:CRESTORE_GUARD_DIR, Env:CRESTORE_CACHE_KEEPER_DIR, Env:CRESTORE_ACCT_SYNC, Env:CRESTORE_PREPARE_ID, Env:CRESTORE_PREPARE_GRACE_S -ErrorAction SilentlyContinue
}
"failures: $fail"
exit $fail
