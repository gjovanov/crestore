# Start a fresh Claude Code session that carries on a closed one from its handoff pack.
#
# Restore-ClaudeSessions.ps1 (crestore -From handoff|auto) queues one wake file per such session and opens a tab
# that runs:   & '<this file>' <old session id>                              (a Windows Terminal tab, PowerShell 7)
#         or:  pwsh -NoLogo -NoProfile -File "<this file>" <old session id>   (a VS Code terminal, whatever its shell)
#
#   ~/.claude/session-restore/wake/<old session id>.json = { session_id, cwd, name, pack, args[], created_at[, no_transcript] }
#
# `pack` is acct-sync's pack of the old conversation, or, for a session that saved no transcript (no_transcript:
# true), the newest handoff that session wrote itself. Such a session cannot be resumed, so this never offers
# `claude --resume` for it.
#
# `args` is the whole argument list for claude: the replayed launch flags, -n <name>, and --append-system-prompt
# with one line that points at the pack. Nothing is sent to the model here. The fresh session waits like a resumed
# one does, and reads the pack when the first message arrives. The line stays in the system prompt for as long as
# the process runs, so it says that it holds only for the conversation claude starts with: one that a /clear begins
# has a brief of its own (acct-sync's wakeAppend builds the line).
#
# Both commands run this file in PowerShell 7. A VS Code terminal can be Windows PowerShell 5.1 (which may refuse to
# load a script: its execution policy), cmd or Git Bash, which is why that command starts pwsh by name.
# The arguments hold no double quotes, so nothing depends on how a shell passes those to a program.
param([Parameter(Mandatory = $true, Position = 0)][string]$Wake)

$base = if ($env:CRESTORE_ROOT) { $env:CRESTORE_ROOT } else { $PSScriptRoot }
$file = Join-Path (Join-Path $base 'wake') "$Wake.json"
$full = "claude --resume $Wake"
if (-not (Test-Path -LiteralPath $file)) {
    Write-Host "crestore: no wake file for $Wake." -ForegroundColor Yellow
    Write-Host "The whole conversation instead:  $full"
    return
}
try { $w = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json }
catch {
    Write-Host "crestore: the wake file cannot be read ($file): $_" -ForegroundColor Yellow
    Write-Host "The whole conversation instead:  $full"
    return
}
$saved = $w.no_transcript -ne $true   # its conversation is on disk, so a full resume is the other way back
if (-not $w.pack -or -not (Test-Path -LiteralPath $w.pack)) {
    Write-Host "crestore: the handoff file is gone ($($w.pack))." -ForegroundColor Yellow
    if ($saved) { Write-Host "The whole conversation instead:  $full" }
    else { Write-Host 'Its conversation was never saved (no transcript), so nothing else can bring it back.' }
    return
}
if ($w.cwd -and (Test-Path -LiteralPath $w.cwd)) { Set-Location -LiteralPath $w.cwd }

Write-Host "Fresh session from the handoff of $($Wake.Substring(0, 8))" -ForegroundColor Cyan
Write-Host "  handoff: $($w.pack)" -ForegroundColor DarkGray
Write-Host "  Nothing is sent until your first message; Claude reads the handoff then." -ForegroundColor DarkGray
if ($saved) { Write-Host "  The whole conversation instead: exit, then  $full" -ForegroundColor DarkGray }
else { Write-Host '  Its conversation was never saved (no transcript): this handoff is all there is of it.' -ForegroundColor DarkGray }

# A terminal that a Claude Code session started (or a VS Code window it cold-started) passes that session's markers
# on, and a claude that inherits CLAUDE_CODE_CHILD_SESSION saves no transcript and no prompt history (2.1.322:
# "nested_marker"). This process is the tab's own, so dropping them here also covers a claude typed in it later.
# CLAUDE_CONFIG_DIR and the variables of settings.json's own env stay. The same list is in Restore-ClaudeSessions.ps1,
# vscode-ext/extension.js and bring-back.mjs.
$sessionMarkers = @('CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_PID',
    'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_EXECPATH', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN',
    'CLAUDE_CODE_SSE_PORT', 'CLAUDE_EFFORT') + @(Get-ChildItem Env: | Where-Object Name -like 'HUB_*' | ForEach-Object Name)
foreach ($n in $sessionMarkers) { Remove-Item -LiteralPath "Env:$n" -ErrorAction SilentlyContinue }

# hook.ps1 reads these in the session's SessionStart and records which session this one continues, and since when.
$claudeArgs = @($w.args)
$env:CRESTORE_WAKE = $Wake
$env:CRESTORE_WAKE_AT = (Get-Date).ToUniversalTime().ToString('o')
try { & claude @claudeArgs }
finally { Remove-Item Env:CRESTORE_WAKE, Env:CRESTORE_WAKE_AT -ErrorAction SilentlyContinue }
