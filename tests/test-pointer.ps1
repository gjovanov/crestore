# The pointer a session woken from a pack is started with: acct-sync's `wake --json` builds it (`append`), crestore
# puts it in the wake file as --append-system-prompt, and Start-HandoffSession.ps1 starts claude with it. It stays in
# the system prompt for as long as the process runs, so the conversation a /clear starts in that process sees it too.
# Cache Keeper's Pack & Clear and Use Latest Handoff each run a /clear and give the new conversation a brief of its
# own, so the pointer must say that it holds only for the conversation the process started with, and how a
# conversation that began with /clear can tell (the engine records <command-name>/clear</command-name> at its start).
#
# acct-sync runs for real on a synthetic closed session in a scratch config dir (CLAUDE_CONFIG_DIR), with a scratch
# state file, so the pack it writes lands there too. claude is the stand-in from fake-exe.ps1. No model is called.
#   -AcctSync <file>   the acct-sync.mjs to test (a backup copy, to see these checks fail on the old wording). The
#                      default is the one scratch.ps1 finds; without one the test is skipped: the pointer is its text.
param(
    [string]$AcctSync,
    [string]$Launcher = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-HandoffSession.ps1')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scratch.ps1')   # $S, the work folder; $AcctSyncTool; $TestConfig
if (-not $AcctSync) { $AcctSync = $AcctSyncTool }
if (-not $AcctSync -or -not (Test-Path -LiteralPath $AcctSync -PathType Leaf)) {
    'skip  acct-sync is not installed (CRESTORE_ACCT_SYNC or -AcctSync names one): the pointer under test is its text'
    'failures: 0'; exit 0
}
$root = Join-Path $S 'pointer-root'
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$root\wake" -Force | Out-Null
$fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') { if ($ok) { "ok    $what" } else { $script:fail++; "FAIL  $what  $detail" } }

# ---- a closed session large enough to come back from a pack (150k of context), in a config dir of its own
$cfg = Join-Path $root 'cfg'
$cwd = Join-Path $root 'work'
New-Item -ItemType Directory $cwd -Force | Out-Null
$sid = 'c1ea4001-0000-4000-8000-000000000001'
$name = "Alex's retry fix"
$proj = Join-Path (Join-Path $cfg 'projects') ($cwd -replace '[^a-zA-Z0-9]', '-')
New-Item -ItemType Directory $proj -Force | Out-Null
$base = [ordered]@{ isSidechain = $false; userType = 'external'; entrypoint = 'cli'; cwd = $cwd; sessionId = $sid; version = '2.1.322'; gitBranch = 'main' }
$usage = [ordered]@{ input_tokens = 6; cache_creation_input_tokens = 2000; cache_read_input_tokens = 148000; output_tokens = 80; cache_creation = [ordered]@{ ephemeral_1h_input_tokens = 2000; ephemeral_5m_input_tokens = 0 } }
$t0 = [datetime]::UtcNow.AddHours(-3)
function Rec([hashtable]$more) { $r = [ordered]@{}; foreach ($k in $base.Keys) { $r[$k] = $base[$k] }; foreach ($k in $more.Keys) { $r[$k] = $more[$k] }; $r | ConvertTo-Json -Depth 10 -Compress }
$recs = @(
    (Rec @{ parentUuid = $null; type = 'user'; uuid = 'u1'; timestamp = $t0.ToString('o'); message = @{ role = 'user'; content = 'Fix the retry in the uploader.' } }),
    (Rec @{ parentUuid = 'u1'; type = 'assistant'; uuid = 'u2'; timestamp = $t0.AddSeconds(30).ToString('o'); message = [ordered]@{ model = 'claude-opus-5-5'; id = 'msg_c1'; type = 'message'; role = 'assistant'; stop_reason = 'end_turn'; usage = $usage; content = @(@{ type = 'text'; text = 'The retry is fixed; the unit tests pass.' }) } }),
    ([ordered]@{ type = 'custom-title'; customTitle = $name; sessionId = $sid } | ConvertTo-Json -Compress)
)
$transcript = Join-Path $proj "$sid.jsonl"
[IO.File]::WriteAllText($transcript, ($recs -join "`n") + "`n", [Text.UTF8Encoding]::new($false))

# ---- the pointer, as crestore asks for it: wake --mode handoff --write --json
$env:CLAUDE_CONFIG_DIR = $cfg
$env:ACCT_SYNC_STATE = Join-Path $root 'state.json'
try { $raw = (& node $AcctSync wake $sid --mode handoff --write --json 2>&1 | ForEach-Object { "$_" }) -join "`n" }
finally { $env:CLAUDE_CONFIG_DIR = $TestConfig; Remove-Item Env:ACCT_SYNC_STATE -ErrorAction SilentlyContinue }
$plan = $null; try { $plan = $raw.Substring($raw.IndexOf('{')) | ConvertFrom-Json } catch {}
$w = if ($plan) { @($plan.sessions)[0] } else { $null }
Check 'wake chose a pack for the session and wrote it under the scratch config dir' ($w -and $w.route -eq 'handoff' -and $w.pack.path -and (Test-Path -LiteralPath $w.pack.path) -and ($w.pack.path -replace '/', '\').StartsWith($cfg, [StringComparison]::OrdinalIgnoreCase)) ($raw -replace '\s+', ' ')
$p = if ($w) { "$($w.append)" } else { '' }
$packFwd = if ($w) { "$($w.pack.path)" } else { '?' }

# The wording it had: who it carries on, the pack, read in full on the first message, once.
Check 'the pointer names the old session and its pack' ($p.Contains("an earlier Claude Code session ($($sid.Substring(0, 8)), named 'Alex s retry fix') whose conversation is not loaded here") -and $p.Contains("Its handoff is the file '$packFwd'.")) $p
Check 'it still has the session read the file in full on the first message, and once' ($p.Contains('When the first message of this conversation arrives, read that file in full before you act on the message, then act on it with the handoff as the record of the work so far.') -and $p.Contains('Do this once: later in the conversation, also after a compaction, open the file again only when you need a detail from it.')) $p
# What is new: it holds only for the conversation the process started with; one that began with /clear can tell.
Check 'it holds only for the conversation the session started with' ($p -match 'holds only for the conversation the session started with') $p
Check 'a conversation that begins with /clear: it names the engine''s marker, says the pointer is spent and not to read the file' ($p.Contains('<command-name>/clear</command-name>') -and $p -match 'begins with /clear' -and $p -match 'pointer is spent' -and $p -match 'do not read the file there') $p
$iScope = $p.IndexOf('holds only for'); $iRead = $p.IndexOf('When the first message')
Check 'the condition comes before the instruction to read the file' ($iScope -ge 0 -and $iRead -gt $iScope) "scope at $iScope, read at $iRead"
Check 'it is one line with no double quote, backtick, dollar or percent sign (it may pass through a shell)' ($p -and $p -notmatch '["`$%\r\n]') $p

# ---- what reaches claude: the wake file crestore writes, run by the launcher, with the stand-in claude
$fake = Join-Path $S 'fake'
& (Join-Path $PSScriptRoot 'fake-exe.ps1') -Dir $fake
$log = Join-Path $root 'claude.log'
$wakeArgs = @('--effort', 'max', '-n', $name, '--append-system-prompt', $p)
[ordered]@{ session_id = $sid; cwd = $cwd; name = $name; pack = "$($w.pack.path)"; args = $wakeArgs; created_at = (Get-Date).ToString('o') } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root "wake\$sid.json") -Encoding utf8
$env:CRESTORE_ROOT = $root
$env:FAKE_EXE_LOG = $log
$oldPath = $env:PATH
$env:PATH = "$fake;$env:PATH"
$o = @()
try {
    # Never the real claude: the launcher runs only when the stand-in is the one PATH finds.
    $found = (Get-Command claude -ErrorAction SilentlyContinue).Source
    Check 'the stand-in claude is the one found in PATH' ($found -eq "$fake\claude.exe") "$found"
    if ($found -eq "$fake\claude.exe") { $o = & pwsh -NoProfile -Command "& '$Launcher' $sid" 2>&1 | ForEach-Object { "$_" } }
} finally { $env:PATH = $oldPath; Remove-Item Env:CRESTORE_ROOT, Env:FAKE_EXE_LOG -ErrorAction SilentlyContinue }
$lines = @(if (Test-Path $log) { Get-Content -LiteralPath $log -Encoding UTF8 })
$got = if ($lines.Count -ge 2) { @($lines[1..($lines.Count - 2)]) } else { @() }
$h = if ($lines.Count) { $lines[0].Substring(4).Split([char]0x1f) } else { @() }
Check 'claude was started once, with the pointer as its last argument, byte for byte' ($lines.Count -eq $wakeArgs.Count + 2 -and $got[-2] -eq '--append-system-prompt' -and $got[-1] -ceq $p) ("got: " + ($got -join ' | ') + ' / ' + ($o -join ' '))
Check 'and with CRESTORE_WAKE = the old id (test-hook.ps1 block 8: a /clear in that process is not linked to it)' ($h.Count -ge 3 -and $h[2] -eq $sid) ($h -join ' | ')

"failures: $fail"
exit $fail
