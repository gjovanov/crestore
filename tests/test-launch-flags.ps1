# The launch flags a closed session comes back with: its own, read from the claude command line the hook recorded.
# Restore-ClaudeSessions.ps1 (a dry run, which prints each tab's command) and bring-back.mjs (`resume`, with the
# stand-in claude recording what it was started with) read one synthetic registry, and give each session the same:
#   - the permission mode it ran in: the default mode (no permission flag), --permission-mode plan, or
#     --dangerously-skip-permissions; --model and --add-dir too, as `--flag value` or `--flag=value`; no other flag
#   - --effort as -Effort and CRESTORE_EFFORT say: inherit by default (the session's own level, or none when it
#     recorded none); a level gives every session that one, once; none gives none.
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scratch.ps1')   # $S, the work folder; the stand-in claude first in PATH
$tool = Split-Path $PSScriptRoot -Parent
$home2 = Join-Path $S 'flags-home'
$root = Join-Path $home2 '.claude\session-restore'   # bring-back.mjs's folder in that home, and crestore's CRESTORE_ROOT
Remove-Item $home2 -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$root\registry", "$home2\t", "$home2\work" -Force | Out-Null
$log = Join-Path $S 'flags.log'
$fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') { if ($ok) { "ok    $what" } else { $script:fail++; "FAIL  $what  $detail" } }
function Id([string]$c) { ($c * 8) + '-' + ($c * 4) + '-4' + ($c * 3) + '-8' + ($c * 3) + '-' + ($c * 12) }
function Show([string[]]$a) { if ($a.Count) { ($a | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' ' } else { 'no launch flag' } }
function Same($a, $b) { (@($a) -join "`n") -ceq (@($b) -join "`n") }
# A session's flags with its --effort pair replaced by the one a setting gives ($null: none). The comma keeps an empty
# list a list.
function With-Effort($want, [string]$level) {
    $f = @(); for ($i = 0; $i -lt $want.Count; $i++) { if ($want[$i] -eq '--effort') { $i++; continue }; $f += $want[$i] }
    if ($level) { $f += '--effort', $level }
    return , $f
}

# Each session: the command line the hook recorded, and the launch flags it comes back with by default.
$cases = [ordered]@{
    default = @{ id = (Id 'a'); cmd = 'claude.exe'; want = @() }
    other   = @{ id = (Id 'b'); cmd = 'claude.exe -n "api fix" --verbose --append-system-prompt "be brief"'; want = @() }
    plan    = @{ id = (Id 'c'); cmd = 'claude.exe --permission-mode plan'; want = @('--permission-mode', 'plan') }
    bypass  = @{ id = (Id 'd'); cmd = 'claude.exe --dangerously-skip-permissions'; want = @('--dangerously-skip-permissions') }
    effort  = @{ id = (Id 'e'); cmd = 'claude.exe --dangerously-skip-permissions --effort high --model opus'; want = @('--dangerously-skip-permissions', '--model', 'opus', '--effort', 'high') }
    equals  = @{ id = (Id 'f'); cmd = '"C:\Program Files\claude\claude.exe" --permission-mode=acceptEdits --add-dir "C:\some dir" --effort=low'; want = @('--permission-mode', 'acceptEdits', '--add-dir', 'C:\some dir', '--effort', 'low') }
}
$at = [datetime]::UtcNow.AddMinutes(-30).ToString('o')
foreach ($n in $cases.Keys) {
    $c = $cases[$n]
    $tx = Join-Path "$home2\t" "$n.jsonl"
    $recs = @(
        (@{ type = 'user'; timestamp = $at; message = @{ role = 'user'; content = "the $n session" } } | ConvertTo-Json -Compress -Depth 5),
        (@{ type = 'assistant'; timestamp = $at; message = @{ role = 'assistant'; stop_reason = 'end_turn'; content = @(@{ type = 'text'; text = 'done' }) } } | ConvertTo-Json -Compress -Depth 5),
        (@{ type = 'custom-title'; customTitle = "$n session" } | ConvertTo-Json -Compress)
    )
    [IO.File]::WriteAllText($tx, ($recs -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    # pid 4 is the System process: alive, but not a claude, so the session counts as closed.
    [ordered]@{ session_id = $c.id; cwd = "$home2\work"; transcript_path = $tx; source = 'startup'; started_at = $at; pid = 4; claude_cmdline = $c.cmd } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path "$root\registry" "$($c.id).json") -Encoding utf8
}
$prefixes = @($cases.Values | ForEach-Object { $_.id.Substring(0, 8) })

# crestore -All -DryRun: the flags in each tab's command, `claude <flags> --resume <id>`, by session id.
function Get-CrestoreFlags([string[]]$more = @()) {
    $out = pwsh -NoProfile -File (Join-Path $tool 'Restore-ClaudeSessions.ps1') -All -DryRun @more 2>&1 | ForEach-Object { "$_" }
    $script:restoreOut = @($out)
    $got = @{}
    foreach ($l in $out) {
        if ($l -cmatch '-Command "claude (.*?)--resume ([0-9a-f-]{36})"$') {
            $sid = $Matches[2]; $flags = $Matches[1]
            $got[$sid] = @([regex]::Matches($flags, "'([^']*)'|(\S+)") | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } })
        }
    }
    return $got
}
# bring-back.mjs resume in that home (USERPROFILE), with the stand-in claude, for every session (or $more): the
# arguments each `claude --bg` got, by session id. The stand-in prints nothing, so bring-back reports each resume as one
# that did not land, and opens no viewer. $script:resumeOut keeps what it printed.
function Get-BringBackArgs([string]$effort, [string[]]$more = $prefixes) {
    Remove-Item $log -ErrorAction SilentlyContinue
    $keep = @{ USERPROFILE = $env:USERPROFILE; HOME = $env:HOME }
    $env:USERPROFILE = $home2; $env:HOME = $home2; $env:FAKE_EXE_LOG = $log
    if ($effort) { $env:CRESTORE_EFFORT = $effort } else { Remove-Item Env:CRESTORE_EFFORT -ErrorAction SilentlyContinue }
    try {
        $script:resumeOut = @(& node (Join-Path $tool 'bring-back.mjs') resume --min-free-gb 0 @more 2>&1 | ForEach-Object { "$_" })
    } finally {
        $env:USERPROFILE = $keep.USERPROFILE; $env:HOME = $keep.HOME
        Remove-Item Env:FAKE_EXE_LOG, Env:CRESTORE_EFFORT -ErrorAction SilentlyContinue
    }
    $got = @{}; $cur = $null
    if (Test-Path -LiteralPath $log) {
        foreach ($line in (Get-Content -LiteralPath $log -Encoding UTF8)) {
            if ($line.StartsWith('### ')) { $cur = [System.Collections.Generic.List[string]]::new() }
            elseif ($line -eq '###end') {
                if ($null -ne $cur -and $cur.Count -gt 0 -and $cur[0] -eq '--bg') { $got[$cur[$cur.IndexOf('--resume') + 1]] = @($cur) }
                $cur = $null
            } elseif ($null -ne $cur) { $cur.Add($line) }
        }
    }
    return $got
}
# What bring-back.mjs starts a session with: its own arguments, then the launch flags.
function Resume-Args($n, $flags) { @('--bg', '--resume', $cases[$n].id, '-n', "$n session") + @($flags | Where-Object { $null -ne $_ }) }

$env:CRESTORE_ROOT = $root
$env:CRESTORE_ACCT_SYNC = Join-Path $home2 'no-acct-sync.mjs'   # no plan: every session is resumed
$env:CRESTORE_GUARD_DIR = Join-Path $home2 'guard'              # never the real records
$env:CRESTORE_CACHE_KEEPER_DIR = Join-Path $home2 'cache-keeper'
$env:NO_COLOR = '1'
try {
    # ---- the default, -Effort inherit: each session's own flags
    $restored = Get-CrestoreFlags
    $resumed = Get-BringBackArgs ''
    foreach ($n in $cases.Keys) {
        $c = $cases[$n]
        Check "crestore, the $n session ($($c.cmd)): comes back with $(Show $c.want)" ($restored.ContainsKey($c.id) -and (Same $restored[$c.id] $c.want)) "got: $(Show $restored[$c.id])"
        Check "bring-back.mjs, the $n session: the same" ($resumed.ContainsKey($c.id) -and (Same $resumed[$c.id] (Resume-Args $n $c.want))) "got: $(Show $resumed[$c.id])"
    }

    # ---- a level from CRESTORE_EFFORT: every session gets it, once, in place of its own
    $env:CRESTORE_EFFORT = 'max'
    $restored = Get-CrestoreFlags
    Remove-Item Env:CRESTORE_EFFORT
    $resumed = Get-BringBackArgs 'max'
    $badRestored = @($cases.Keys | Where-Object { -not ($restored.ContainsKey($cases[$_].id) -and (Same $restored[$cases[$_].id] (With-Effort $cases[$_].want 'max'))) })
    $badResumed = @($cases.Keys | Where-Object { -not ($resumed.ContainsKey($cases[$_].id) -and (Same $resumed[$cases[$_].id] (Resume-Args $_ (With-Effort $cases[$_].want 'max')))) })
    Check 'CRESTORE_EFFORT=max: crestore gives every session --effort max, once, in place of its own' ($badRestored.Count -eq 0) ("wrong: " + ($badRestored -join ', '))
    Check 'CRESTORE_EFFORT=max: bring-back.mjs does the same' ($badResumed.Count -eq 0) ("wrong: " + ($badResumed -join ', '))

    # ---- none: no --effort at all
    $restored = Get-CrestoreFlags @('-Effort', 'none')
    $resumed = Get-BringBackArgs 'none'
    $badRestored = @($cases.Keys | Where-Object { -not ($restored.ContainsKey($cases[$_].id) -and (Same $restored[$cases[$_].id] (With-Effort $cases[$_].want $null))) })
    $badResumed = @($cases.Keys | Where-Object { -not ($resumed.ContainsKey($cases[$_].id) -and (Same $resumed[$cases[$_].id] (Resume-Args $_ (With-Effort $cases[$_].want $null)))) })
    Check '-Effort none: crestore passes no --effort, and the other flags as before' ($badRestored.Count -eq 0) ("wrong: " + ($badRestored -join ', '))
    Check 'CRESTORE_EFFORT=none: bring-back.mjs does the same' ($badResumed.Count -eq 0) ("wrong: " + ($badResumed -join ', '))

    # ---- bring-back.mjs with a CRESTORE_EFFORT it does not know: it says so, and inherits
    $resumed = Get-BringBackArgs 'highest'
    $badResumed = @($cases.Keys | Where-Object { -not ($resumed.ContainsKey($cases[$_].id) -and (Same $resumed[$cases[$_].id] (Resume-Args $_ $cases[$_].want))) })
    Check 'bring-back.mjs, an unknown CRESTORE_EFFORT: a note, and each session''s own level' ($badResumed.Count -eq 0 -and ($script:resumeOut -join ' ') -match "CRESTORE_EFFORT='highest' is not one of") (($badResumed -join ', ') + ' / ' + ($script:resumeOut -join ' / '))

    # ---- crestore with a CRESTORE_EFFORT it does not know: the same (ValidateSet does not check a default from the
    # environment)
    $env:CRESTORE_EFFORT = 'highest'
    $restored = Get-CrestoreFlags
    Remove-Item Env:CRESTORE_EFFORT
    $badRestored = @($cases.Keys | Where-Object { -not ($restored.ContainsKey($cases[$_].id) -and (Same $restored[$cases[$_].id] $cases[$_].want)) })
    Check 'crestore, an unknown CRESTORE_EFFORT: a note, and each session''s own level' ($badRestored.Count -eq 0 -and ($script:restoreOut -join ' ') -match "CRESTORE_EFFORT='highest' is not low") (($badRestored -join ', ') + ' / ' + ($script:restoreOut -join ' / '))

    # ---- a level in capitals reaches claude in lower case
    $env:CRESTORE_EFFORT = 'MAX'
    $restored = Get-CrestoreFlags
    Remove-Item Env:CRESTORE_EFFORT
    $resumed = Get-BringBackArgs 'MAX'
    $badRestored = @($cases.Keys | Where-Object { -not ($restored.ContainsKey($cases[$_].id) -and (Same $restored[$cases[$_].id] (With-Effort $cases[$_].want 'max'))) })
    $badResumed = @($cases.Keys | Where-Object { -not ($resumed.ContainsKey($cases[$_].id) -and (Same $resumed[$cases[$_].id] (Resume-Args $_ (With-Effort $cases[$_].want 'max')))) })
    Check 'CRESTORE_EFFORT=MAX: crestore passes --effort max, in lower case' ($badRestored.Count -eq 0) ("wrong: " + ($badRestored -join ', '))
    Check 'CRESTORE_EFFORT=MAX: bring-back.mjs does the same' ($badResumed.Count -eq 0) ("wrong: " + ($badResumed -join ', '))

    # ---- bring-back.mjs resume --dry: prints the command, and starts nothing
    $resumed = Get-BringBackArgs '' @('--dry', $cases.plan.id.Substring(0, 8))
    $line = "claude --bg --resume $($cases.plan.id) -n `"plan session`" --permission-mode plan"
    Check 'bring-back.mjs resume --dry: prints the command with the session''s own flags, and starts no claude --bg' (($script:resumeOut -join "`n").Contains($line) -and $resumed.Count -eq 0) ($script:resumeOut -join ' / ')
} finally {
    Remove-Item Env:CRESTORE_ROOT, Env:CRESTORE_ACCT_SYNC, Env:CRESTORE_GUARD_DIR, Env:CRESTORE_CACHE_KEEPER_DIR, Env:CRESTORE_EFFORT -ErrorAction SilentlyContinue
    Remove-Item $home2 -Recurse -Force -ErrorAction SilentlyContinue
}
"failures: $fail"
exit $fail
