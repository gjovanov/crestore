# Drives hook.ps1 with synthetic events against a scratch root (CRESTORE_ROOT), never the real registry.
param([string]$Hook = (Join-Path (Split-Path $PSScriptRoot -Parent) 'hook.ps1'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scratch.ps1')
$root = Join-Path $S 'hook-root'
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $root -Force | Out-Null
$env:CRESTORE_ROOT = $root
$reg = Join-Path $root 'registry'

$old = '11111111-1111-4111-8111-111111111111'
$new = '22222222-2222-4222-8222-222222222222'
$cl  = '33333333-3333-4333-8333-333333333333'
$pl  = '44444444-4444-4444-8444-444444444444'

function Send([hashtable]$evt, [string]$wake, [string]$at) {
    if ($wake) { $env:CRESTORE_WAKE = $wake } else { Remove-Item Env:CRESTORE_WAKE -ErrorAction SilentlyContinue }
    if ($at) { $env:CRESTORE_WAKE_AT = $at } else { Remove-Item Env:CRESTORE_WAKE_AT -ErrorAction SilentlyContinue }
    $json = $evt | ConvertTo-Json -Compress
    $out = $json | pwsh -NoProfile -NoLogo -File $Hook
    $code = $LASTEXITCODE
    Remove-Item Env:CRESTORE_WAKE, Env:CRESTORE_WAKE_AT -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw "hook exit $code" }
    if ($out) { throw "hook wrote to stdout: $out" }
}
function Entry([string]$id) { Get-Content (Join-Path $reg "$id.json") -Raw | ConvertFrom-Json }
$fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') { if ($ok) { "ok    $what" } else { $script:fail++; "FAIL  $what  $detail" } }

# 1. a plain start: no link
Send @{ hook_event_name = 'SessionStart'; session_id = $pl; cwd = 'C:\x'; transcript_path = 'C:\x\p.jsonl'; source = 'startup' } $null
$e = Entry $pl
Check 'plain startup is recorded'              ($e.session_id -eq $pl -and $e.source -eq 'startup')
Check 'plain startup has no continues'         (-not $e.PSObject.Properties['continues'])
Check 'entry keeps its seven fields'           ((@($e.PSObject.Properties.Name) -join ',') -eq 'session_id,cwd,transcript_path,source,started_at,pid,claude_cmdline')

# 2. a start under CRESTORE_WAKE: linked, at the launcher's time
$launch = '2026-11-18T09:15:00.0000000Z'
function Utc($x) { ([datetime]$x).ToUniversalTime().ToString('o') }
Send @{ hook_event_name = 'SessionStart'; session_id = $new; cwd = 'C:\x'; transcript_path = 'C:\x\n.jsonl'; source = 'startup' } $old $launch
$e = Entry $new
Check 'woken startup records continues'        ($e.continues -eq $old)
Check 'and the launcher''s time as continued_at' ((Utc $e.continued_at) -eq $launch) "$($e.continued_at)"
Check 'a linked entry has nine fields'         ((@($e.PSObject.Properties.Name) -join ',') -eq 'session_id,cwd,transcript_path,source,started_at,pid,claude_cmdline,continues,continued_at')

# 3. the same session resumed later, with no variable: the link and its time stay
Send @{ hook_event_name = 'SessionStart'; session_id = $new; cwd = 'C:\x'; transcript_path = 'C:\x\n.jsonl'; source = 'resume' } $null
$e = Entry $new
Check 'a later resume keeps continues'         ($e.continues -eq $old -and $e.source -eq 'resume')
Check 'a later resume keeps continued_at'      ((Utc $e.continued_at) -eq $launch) "$($e.continued_at)"
Send @{ hook_event_name = 'SessionStart'; session_id = $new; cwd = 'C:\x'; transcript_path = 'C:\x\n.jsonl'; source = 'resume' } $null
Check 'and a second resume still does'         ((Utc (Entry $new).continued_at) -eq $launch)

# 3b. a claude started from inside the woken session inherits both variables: the same moment, not its own
$child = '66666666-6666-4666-8666-666666666666'
Send @{ hook_event_name = 'SessionStart'; session_id = $child; cwd = 'C:\x'; transcript_path = 'C:\x\w.jsonl'; source = 'startup' } $old $launch
Check 'an inheriting start records the launch time' ((Utc (Entry $child).continued_at) -eq $launch)

# 3c. no time, or one that is not a time: now
$odd = '77777777-7777-4777-8777-777777777777'
$before = (Get-Date).ToUniversalTime().AddSeconds(-2)
Send @{ hook_event_name = 'SessionStart'; session_id = $odd; cwd = 'C:\x'; transcript_path = 'C:\x\o.jsonl'; source = 'startup' } $old 'yesterday-ish'
$got = ([datetime](Entry $odd).continued_at).ToUniversalTime()
Check 'a time that is not one falls back to now' ($got -ge $before -and $got -le (Get-Date).ToUniversalTime().AddSeconds(2)) "$got"

# 4. /clear inside the woken process: the new id is not a successor
Send @{ hook_event_name = 'SessionStart'; session_id = $cl; cwd = 'C:\x'; transcript_path = 'C:\x\c.jsonl'; source = 'clear' } $old
$e = Entry $cl
Check 'a /clear under the variable is not linked' (-not $e.PSObject.Properties['continues'])

# 5. a variable that is not a session id, or names the session itself, is ignored
Send @{ hook_event_name = 'SessionStart'; session_id = $pl; cwd = 'C:\x'; transcript_path = 'C:\x\p.jsonl'; source = 'startup' } 'not-an-id'
Check 'a malformed variable is ignored'        (-not (Entry $pl).PSObject.Properties['continues'])
Send @{ hook_event_name = 'SessionStart'; session_id = $pl; cwd = 'C:\x'; transcript_path = 'C:\x\p.jsonl'; source = 'startup' } $pl
Check 'a self-reference is ignored'            (-not (Entry $pl).PSObject.Properties['continues'])

# 6. SessionEnd still closes an entry and keeps the link
Send @{ hook_event_name = 'SessionEnd'; session_id = $new; reason = 'prompt_input_exit' } $null
$e = Entry $new
Check 'SessionEnd marks the entry ended'       ([bool]$e.ended_at -and $e.end_reason -eq 'prompt_input_exit' -and $e.continues -eq $old)

# 7. a subagent event writes nothing
Send @{ hook_event_name = 'SessionStart'; session_id = '55555555-5555-4555-8555-555555555555'; agent_id = 'a1'; cwd = 'C:\x'; transcript_path = 'C:\x\s.jsonl'; source = 'startup' } $null
Check 'a subagent start is not recorded'       (-not (Test-Path (Join-Path $reg '55555555-5555-4555-8555-555555555555.json')))

# 8. /clear in a woken process, as Cache Keeper's Pack & Clear and Use Latest Handoff run it. Both variables stay set
#    for the whole process, so every event below has them. Only the conversation the process started with carries on
#    the old session: a SessionStart for `clear` is not a wake, and neither is a later resume or compaction of it.
$w8  = '88888888-8888-4888-8888-888888888888'   # the woken session
$c8  = '99999999-9999-4999-8999-999999999999'   # the conversation the /clear starts
$c8b = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa8'   # a second /clear in the same process
$at8 = '2026-11-20T08:30:00.0000000Z'
Send @{ hook_event_name = 'SessionStart'; session_id = $w8; cwd = 'C:\x'; transcript_path = 'C:\x\w8.jsonl'; source = 'startup' } $old $at8
Send @{ hook_event_name = 'SessionStart'; session_id = $w8; cwd = 'C:\x'; transcript_path = 'C:\x\w8.jsonl'; source = 'compact' } $old $at8
$e = Entry $w8
Check 'a compaction in the woken conversation keeps its link and its time' ($e.continues -eq $old -and (Utc $e.continued_at) -eq $at8 -and $e.source -eq 'compact') "$($e.continues) $($e.continued_at) $($e.source)"
Send @{ hook_event_name = 'SessionEnd'; session_id = $w8; reason = 'clear' } $old $at8
Send @{ hook_event_name = 'SessionStart'; session_id = $c8; cwd = 'C:\x'; transcript_path = 'C:\x\c8.jsonl'; source = 'clear' } $old $at8
$e = Entry $c8
Check 'the /clear conversation is recorded, as a clear'            ($e.session_id -eq $c8 -and $e.source -eq 'clear')
Check 'it does not carry on the old session: no continues, no continued_at' (-not $e.PSObject.Properties['continues'] -and -not $e.PSObject.Properties['continued_at']) (($e.PSObject.Properties.Name) -join ',')
Check 'it has the seven fields of a plain start'                   ((@($e.PSObject.Properties.Name) -join ',') -eq 'session_id,cwd,transcript_path,source,started_at,pid,claude_cmdline') (($e.PSObject.Properties.Name) -join ',')
$e = Entry $w8
Check 'the woken conversation ends with the clear and keeps its link' ([bool]$e.ended_at -and $e.end_reason -eq 'clear' -and $e.continues -eq $old -and (Utc $e.continued_at) -eq $at8) "$($e.end_reason) $($e.continues)"
Send @{ hook_event_name = 'SessionStart'; session_id = $c8; cwd = 'C:\x'; transcript_path = 'C:\x\c8.jsonl'; source = 'compact' } $old $at8
Check 'a compaction of the /clear conversation does not link it'   (-not (Entry $c8).PSObject.Properties['continues'])
Send @{ hook_event_name = 'SessionStart'; session_id = $c8; cwd = 'C:\x'; transcript_path = 'C:\x\c8.jsonl'; source = 'resume' } $old $at8
Check 'a resume of it under the same variables does not link it'   (-not (Entry $c8).PSObject.Properties['continues'] -and (Entry $c8).source -eq 'resume')
Send @{ hook_event_name = 'SessionEnd'; session_id = $c8; reason = 'clear' } $old $at8
Send @{ hook_event_name = 'SessionStart'; session_id = $c8b; cwd = 'C:\x'; transcript_path = 'C:\x\c8b.jsonl'; source = 'clear' } $old $at8
Check 'nor does a second /clear in the same process'              (-not (Entry $c8b).PSObject.Properties['continues'])
$linked = @(Get-ChildItem $reg -Filter *.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.continues -eq $old -and $_.session_id -in @($w8, $c8, $c8b) })
Check 'of the three conversations in that process, only the first carries on the old session' ($linked.Count -eq 1 -and $linked[0].session_id -eq $w8) (($linked | ForEach-Object session_id) -join ',')

$log = Join-Path $root 'hook.log'
Check 'hook.log has no error'                  (-not (Test-Path $log))
if (Test-Path $log) { Get-Content $log }
Remove-Item Env:CRESTORE_ROOT -ErrorAction SilentlyContinue
"failures: $fail"
exit $fail
