# bring-back.mjs starts claude (`claude agents`, `claude --bg --resume`) without the markers of the session it runs
# from. Its `list` mode with a stand-in claude (fake-exe.ps1) in a scratch home whose registry is empty: the stand-in
# records what it was started with, and nothing else happens. Then `list` on three closed sessions: every one is listed,
# the one started in the default permission mode too; CRESTORE_SKIP_NAME keeps the one whose name it matches out, and
# CRESTORE_LIST_MATCH keeps only those whose command line it matches. The launch flags `resume` passes are checked in
# test-launch-flags.ps1.
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scratch.ps1')   # $S, the work folder
$tool = Split-Path $PSScriptRoot -Parent
$fake = Join-Path $S 'fake'
& (Join-Path $PSScriptRoot 'fake-exe.ps1') -Dir $fake
$home2 = Join-Path $S 'bring-back-home'
Remove-Item $home2 -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory (Join-Path $home2 '.claude\session-restore\registry') -Force | Out-Null
$log = Join-Path $S 'bring-back.log'
Remove-Item $log -ErrorAction SilentlyContinue
$fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') { if ($ok) { "ok    $what" } else { $script:fail++; "FAIL  $what  $detail" } }

$markers = [ordered]@{
    CLAUDECODE = '1'; CLAUDE_CODE_CHILD_SESSION = '1'; CLAUDE_CODE_SESSION_ID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    CLAUDE_CODE_SESSION_ATTENDED = '1'; CLAUDE_PID = '4242'; CLAUDE_CODE_MESSAGING_SOCKET = 'test'; CLAUDE_CODE_SSE_PORT = '1'
    CLAUDE_EFFORT = 'low'; HUB_CALL = 'test'; HUB_WORKER = 'w9'
}
$saved = @{ USERPROFILE = $env:USERPROFILE; HOME = $env:HOME; PATH = $env:PATH }
foreach ($k in $markers.Keys) { Set-Item -LiteralPath "Env:$k" -Value $markers[$k] }
$env:CLAUDE_CRESTORE_TEST_KEEP = '1'
$env:FAKE_EXE_LOG = $log
$env:USERPROFILE = $home2
$env:HOME = $home2
$env:PATH = "$fake;$env:PATH"
try {
    # bring-back.mjs runs `claude`: never the real one. node finds a claude.exe on PATH the way this does.
    $found = (Get-Command claude -ErrorAction SilentlyContinue).Source
    if ($found -ne "$fake\claude.exe") { throw "FAIL  the stand-in claude is not the one found in PATH ($found)" }
    $o = & node (Join-Path $tool 'bring-back.mjs') list 2>&1 | ForEach-Object { "$_" }
    Check 'list ran' ($LASTEXITCODE -eq 0) ($o -join ' / ')
    $lines = @(if (Test-Path $log) { Get-Content -LiteralPath $log -Encoding UTF8 })
    $heads = @($lines | Where-Object { $_.StartsWith('### claude') })
    Check "claude was started once, for the live sessions ($($heads.Count))" ($heads.Count -eq 1 -and $lines -contains 'agents')
    if ($heads.Count -ge 1) {
        $seen = @("$($heads[0].Substring(4).Split([char]0x1f)[4])" -split ',' | Where-Object { $_ })
        $leaked = @($seen | Where-Object { $markers.Contains($_) })
        Check "claude gets none of the parent session's markers" ($leaked.Count -eq 0) ("leaked: " + ($leaked -join ', '))
        Check 'any other CLAUDE* variable reaches claude' ($seen -contains 'CLAUDE_CRESTORE_TEST_KEEP') ($seen -join ', ')
    }
    # A session that saved no transcript (a claude that inherited CLAUDE_CODE_CHILD_SESSION): resume skips it with a
    # reason, and the run goes on, instead of stopping at a missing file.
    $nt = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
    [ordered]@{ session_id = $nt; cwd = $home2; transcript_path = (Join-Path $home2 'never-written.jsonl'); pid = 4; claude_cmdline = 'claude.exe' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $home2 ".claude\session-restore\registry\$nt.json") -Encoding utf8
    Remove-Item $log -ErrorAction SilentlyContinue
    $r = & node (Join-Path $tool 'bring-back.mjs') resume --dry $nt.Substring(0, 8) 2>&1 | ForEach-Object { "$_" }
    $rt = $r -join ' / '
    $resumed = @(if (Test-Path $log) { Get-Content -LiteralPath $log -Encoding UTF8 | Where-Object { $_ -eq '--resume' } })
    Check 'resume: a session that saved no transcript is skipped with the reason, and nothing is resumed' ($LASTEXITCODE -eq 0 -and $rt -match 'skipped eeeeeeee: saved no transcript' -and $resumed.Count -eq 0) $rt

    # `list`: three closed sessions with a transcript. Two were started with --dangerously-skip-permissions, as
    # `-n worker-3` and `-n "api fix"`, and one in the default permission mode, as `-n plain`.
    $w3 = 'f1f1f1f1-1111-4111-8111-111111111111'; $api = 'f2f2f2f2-2222-4222-8222-222222222222'
    $plain = ('f3' * 4) + '-3333-4333-8333-' + ('3' * 12)
    $at = [datetime]::UtcNow.AddMinutes(-30).ToString('o')
    foreach ($s2 in @(
            @{ id = $w3; cmd = 'claude.exe --dangerously-skip-permissions -n worker-3'; title = 'worker three' }
            @{ id = $api; cmd = 'claude.exe --dangerously-skip-permissions -n "api fix"'; title = 'api fix' }
            @{ id = $plain; cmd = 'claude.exe -n plain'; title = 'plain one' })) {
        $tx = Join-Path $home2 "$($s2.id).jsonl"
        $recs = @(
            (@{ type = 'user'; timestamp = $at; message = @{ role = 'user'; content = 'go on' } } | ConvertTo-Json -Compress -Depth 5),
            (@{ type = 'assistant'; timestamp = $at; message = @{ role = 'assistant'; stop_reason = 'end_turn'; content = @(@{ type = 'text'; text = 'done' }) } } | ConvertTo-Json -Compress -Depth 5),
            (@{ type = 'custom-title'; customTitle = $s2.title } | ConvertTo-Json -Compress)
        )
        [IO.File]::WriteAllText($tx, ($recs -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        [ordered]@{ session_id = $s2.id; cwd = $home2; transcript_path = $tx; pid = 4; claude_cmdline = $s2.cmd } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $home2 ".claude\session-restore\registry\$($s2.id).json") -Encoding utf8
    }
    # From here on each is the part of its id that `list` prints: the first 8 characters.
    $w3 = $w3.Substring(0, 8); $api = $api.Substring(0, 8); $plain = $plain.Substring(0, 8)
    $all = (& node (Join-Path $tool 'bring-back.mjs') list 2>&1 | ForEach-Object { "$_" }) -join ' / '
    Check 'list: every closed session is listed, the one in the default permission mode too' ($all -match $w3 -and $all -match $api -and $all -match $plain) $all
    $env:CRESTORE_SKIP_NAME = '^worker-\d+$'
    $some = (& node (Join-Path $tool 'bring-back.mjs') list 2>&1 | ForEach-Object { "$_" }) -join ' / '
    Check 'list with CRESTORE_SKIP_NAME: the session it names stays out, the others are listed' ($some -notmatch $w3 -and $some -match $api -and $some -match $plain) $some
    Remove-Item Env:CRESTORE_SKIP_NAME
    $env:CRESTORE_LIST_MATCH = '--dangerously-skip-permissions'
    $matched = (& node (Join-Path $tool 'bring-back.mjs') list 2>&1 | ForEach-Object { "$_" }) -join ' / '
    Check 'list with CRESTORE_LIST_MATCH: only the sessions whose command line it matches are listed' ($matched -match $w3 -and $matched -match $api -and $matched -notmatch $plain) $matched
    $env:CRESTORE_SKIP_NAME = '^worker-\d+$'
    $both = (& node (Join-Path $tool 'bring-back.mjs') list 2>&1 | ForEach-Object { "$_" }) -join ' / '
    Check 'list with both: a session must match CRESTORE_LIST_MATCH, and its name not CRESTORE_SKIP_NAME' ($both -notmatch $w3 -and $both -match $api -and $both -notmatch $plain) $both
} finally {
    Remove-Item Env:CRESTORE_SKIP_NAME, Env:CRESTORE_LIST_MATCH -ErrorAction SilentlyContinue
    $env:USERPROFILE = $saved.USERPROFILE; $env:HOME = $saved.HOME; $env:PATH = $saved.PATH
    Remove-Item Env:FAKE_EXE_LOG, Env:CLAUDE_CRESTORE_TEST_KEEP -ErrorAction SilentlyContinue
    foreach ($k in $markers.Keys) { Remove-Item -LiteralPath "Env:$k" -ErrorAction SilentlyContinue }
    Remove-Item $home2 -Recurse -Force -ErrorAction SilentlyContinue
}
"failures: $fail"
exit $fail
