#Requires -Version 7
<#
Restore Claude Code sessions that were open before a reboot / terminal wipeout.

Works for ANY project folder: sessions are tracked globally by
~/.claude/session-restore/hook.ps1 (SessionStart/SessionEnd hooks wired in the
user-level ~/.claude/settings.json). Any tracked session without a clean end
whose transcript is fresh enough is offered for restore; each selected session
gets its own Windows Terminal tab, cd'ed to its original directory, running
`claude --resume <id>` (with launch flags like --dangerously-skip-permissions
replayed). Resuming costs no tokens until a prompt is sent.

Usage:
  crestore                    # picker across ALL folders (Enter = restore all)
  crestore myapp              # only sessions whose cwd matches 'myapp'
  crestore C:\src\myapp       # full paths work too (positional filter)
  crestore api,web,docs       # several folders: a session matching any of them
  crestore -Today             # only sessions that took a turn today (since local midnight), in place of
                              # -MaxAgeHours. Both windows go by each session's last turn, not by its
                              # file's time: Claude Code appends bookkeeping records to every open
                              # transcript, so an idle session's file can carry this morning's time.
  crestore -List              # just show candidates
  crestore -All               # no prompt, restore everything
  crestore -Scan              # also infer sessions from recent transcript files
                              # (needed the first time, for sessions started
                              #  before the hooks were installed)
  crestore -Target vscode     # restore into VS Code integrated terminals instead
                              # of Windows Terminal tabs; windows open per folder,
                              # already-open windows pick sessions up via a watcher.
                              # Set $env:CRESTORE_TARGET='vscode' to make it the default.
  crestore -Effort high       # effort level for every restored session
                              # (low|medium|high|xhigh|max|inherit|none, default inherit;
                              #  'inherit' = keep each session's original level, and pass
                              #  no --effort for one that was started without it,
                              #  'none' = don't pass --effort at all.
                              #  Set $env:CRESTORE_EFFORT to change the default. A higher
                              #  effort spends more tokens per turn.)
  crestore -From auto         # how each session comes back (default resume):
                              #  resume  = the whole conversation, same session id.
                              #  handoff = a fresh session started from a handoff pack
                              #            (~10k tokens, written by acct-sync without a
                              #            model call) instead of the conversation.
                              #  auto    = per session: a handoff where the cache is cold
                              #            and the session has a recent summary in its own
                              #            words, a resume where it is small, still warm,
                              #            already compacted, or would give a thin pack.
                              # Works on the login the session ran on and on another one
                              # (log in first; the pack is worded for whichever it is).
                              # In the picker a letter overrides one entry: 2h,4-6r.
                              # Set $env:CRESTORE_FROM to change the default.
  crestore -HandoffOnly       # -From handoff, and nothing comes back in full in a pack's place: a
                              # session acct-sync gives no pack stays closed (its resume line is
                              # printed), and without acct-sync nothing starts. A session acct-sync
                              # plans as a resume still comes back that way: it is no larger than a
                              # fresh session with its pack would be.
  crestore api,web,docs -Today -HandoffOnly -Target vscode -All
                              # every session of those folders used today, each a fresh session from
                              # its handoff pack, in VS Code, with no picker
  crestore -To work           # with -From: plan for the login labelled 'work' in acct-sync
                              # instead of the one in use (you switch after restoring)
  crestore -MaxAgeHours 24    # freshness window, by last turn (default 72)
  crestore -DryRun            # print the wt commands instead of running them
  crestore -AsIfRestarted -List   # what a restart would offer: sessions running now count as closed. Always a
                              # dry run (it starts nothing); add -DryRun -All to see each one's command.
  crestore -Prune             # mark every open registry entry as ended
  crestore -Prepare           # before a planned restart: every open session writes an
                              # up-to-date handoff first (the handoff-guard plugin), and
                              # this says which did. Nothing is restarted. Spends one
                              # handoff turn per session whose handoff is stale.
  crestore -Prepare -DryRun   # only show where each open session's handoff stands
  crestore -Prepare -Reboot   # ... then asks, and restarts Windows in 60 s (shutdown /a cancels)
  crestore -Prepare -IncludeCold     # sessions whose prompt cache is cold write one too
                              # (each re-reads its whole conversation at the full price)
  crestore -Prepare -PrepareMinutes 15   # how long to wait for the answers (default 10)
  crestore -Prepare -HandoffCommand session-handoff
                              # the command the lines name when a session must write its handoff by
                              # hand (default: handoff-guard's 'command' setting, else hub-handoff)
  crestore -InstallStartup    # optional: run the picker automatically at logon
  crestore -UninstallStartup

Claude Code's config folder is CLAUDE_CONFIG_DIR, else ~/.claude: its projects/, handoff-guard/
and cache-keeper/ folders, and acct-sync in tools/account-sync/ (CRESTORE_ACCT_SYNC names another).

A handoff tab is a new session (new id) that waits like a resumed one: nothing is
sent until your first message, and Claude reads the pack then. The old conversation
stays on disk and can still be resumed with `claude --resume <id>`. Method and
numbers: acct-sync's README, https://github.com/gjovanov/acct-sync.

A session that saved no transcript (a claude started from inside a Claude Code
session inherits CLAUDE_CODE_CHILD_SESSION, and 2.1.322 then saves none) cannot be
resumed and acct-sync cannot pack it. It comes back from its own newest handoff, the
file its handoff-guard record names (~/.claude/handoff-guard/live/<id>.json), whatever
-From says; the list says when work came after that handoff. One with neither a
transcript nor a handoff is listed as one that cannot be brought back.

Tests: pwsh -NoProfile -File tests\run-all.ps1 (stand-ins for wt.exe and claude.exe;
nothing real is started).
#>
[CmdletBinding()]
param(
    # Folders (any match): `crestore a,b` or `-Project a,b`; one 'a,b' string is split the same way.
    [Parameter(Position = 0)]
    [string[]]$Project,
    [switch]$List,
    [switch]$All,
    [switch]$Scan,
    [int]$MaxAgeHours = 72,
    # Sessions that took a turn since local midnight, in place of -MaxAgeHours.
    [switch]$Today,
    # Effort level every restored session starts at. 'inherit', the default, replays whatever the
    # session was originally launched with (nothing if it carried no --effort);
    # 'none' omits the flag entirely. ValidateSet is deliberate: claude itself only
    # WARNS on an unknown value and silently falls back to the default effort.
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'inherit', 'none')]
    [string]$Effort = $(if ($env:CRESTORE_EFFORT) { $env:CRESTORE_EFFORT } else { 'inherit' }),
    # How each session comes back: the whole conversation (resume), a fresh session
    # that reads a handoff pack (handoff), or whichever acct-sync advises (auto).
    [ValidateSet('resume', 'handoff', 'auto')]
    [string]$From = $(if ($env:CRESTORE_FROM) { $env:CRESTORE_FROM } else { 'resume' }),
    # -From handoff, and never a full resume in a pack's place: a session that gets no pack stays closed.
    [switch]$HandoffOnly,
    # An acct-sync label: plan for that login instead of the one in use.
    [string]$To,
    [ValidateSet('wt', 'vscode')]
    [string]$Target = $(if ($env:CRESTORE_TARGET) { $env:CRESTORE_TARGET } else { 'wt' }),
    [string]$Window = 'claude-restore',
    [switch]$DryRun,
    # What a restart would offer: every open session counts as closed, running or not. Implies -DryRun.
    [switch]$AsIfRestarted,
    [switch]$Prune,
    # Before a restart: ask every open session's handoff-guard for an up-to-date handoff, and wait for the answers.
    [switch]$Prepare,
    [switch]$IncludeCold,
    [double]$PrepareMinutes = 10,
    [switch]$Reboot,
    # The slash command, without the slash, that has a session write its handoff (handoff-guard's `command` setting):
    # what the lines name when a session must run it by hand. Default: that setting, else handoff-guard's default.
    [string]$HandoffCommand,
    [switch]$FromStartup,
    [switch]$InstallStartup,
    [switch]$UninstallStartup
)

$ErrorActionPreference = 'Stop'

# A process that a Claude Code session started carries that session's markers. A claude that inherits
# CLAUDE_CODE_CHILD_SESSION saves no transcript and no prompt history (2.1.322: "nested_marker"), and the others
# name the parent session (its id, pid, IDE port, messaging socket). Every tab opened here, and every VS Code window
# `code` cold-starts here, inherits this process's environment, so they go before anything starts.
# CLAUDE_CONFIG_DIR and the variables of settings.json's own env stay. The same list is in Start-HandoffSession.ps1,
# vscode-ext/extension.js and bring-back.mjs.
# CRESTORE_WAKE and CRESTORE_WAKE_AT go too (here only): run from a session that a handoff started, they name the
# session that one carries on, and hook.ps1 would record any fresh claude in a tab or window started here as carrying
# it on as well. Start-HandoffSession.ps1 sets its own pair for the one claude it starts.
$sessionMarkers = @('CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_PID',
    'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_EXECPATH', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN',
    'CLAUDE_CODE_SSE_PORT', 'CLAUDE_EFFORT') + @(Get-ChildItem Env: | Where-Object Name -like 'HUB_*' | ForEach-Object Name)
foreach ($n in $sessionMarkers + @('CRESTORE_WAKE', 'CRESTORE_WAKE_AT')) { Remove-Item -LiteralPath "Env:$n" -ErrorAction SilentlyContinue }

$root        = if ($env:CRESTORE_ROOT) { $env:CRESTORE_ROOT } else { Join-Path $env:USERPROFILE '.claude\session-restore' }
$registryDir = Join-Path $root 'registry'
$wakeDir     = Join-Path $root 'wake'
$launcher    = Join-Path $PSScriptRoot 'Start-HandoffSession.ps1'
# Claude Code's config folder, the one Claude Code, handoff-guard, Cache Keeper and acct-sync each read.
$configDir   = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
# acct-sync (optional): where its README installs it, unless CRESTORE_ACCT_SYNC names the script.
$acctSync    = if ($env:CRESTORE_ACCT_SYNC) { $env:CRESTORE_ACCT_SYNC } else { Join-Path $configDir 'tools\account-sync\acct-sync.mjs' }
$projectsDir = Join-Path $configDir 'projects'
# The handoff-guard plugin's folder: request.json (written by -Prepare) and live/<sid>.json (one record per session).
$guardDir    = if ($env:CRESTORE_GUARD_DIR) { $env:CRESTORE_GUARD_DIR } else { Join-Path $configDir 'handoff-guard' }
# Cache Keeper's folder (optional): live/<sid>.json holds a session's name and the size of its context. Only read.
$ckDir       = if ($env:CRESTORE_CACHE_KEEPER_DIR) { $env:CRESTORE_CACHE_KEEPER_DIR } else { Join-Path $configDir 'cache-keeper' }
$taskName    = 'ClaudeSessionRestore'
$uuidRe      = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# The handoff command the lines name when a session must write its handoff by hand: -HandoffCommand, else
# handoff-guard's `command` setting (pluginConfigs."handoff-guard@<marketplace>".options.command in the config folder's
# settings.json), else handoff-guard's own default. It only names the command: crestore never runs it.
function Get-GuardHandoffCommand {
    try {
        $s = Get-Content -LiteralPath (Join-Path $configDir 'settings.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($p in @($s.pluginConfigs.PSObject.Properties)) {
            if ($p -and $p.Name -like 'handoff-guard@*' -and "$($p.Value.options.command)".Trim()) { return "$($p.Value.options.command)".Trim() }
        }
    } catch {}
    return 'hub-handoff'
}
$handoffCmd = $(if ("$HandoffCommand".Trim()) { "$HandoffCommand".Trim() } else { Get-GuardHandoffCommand }).TrimStart('/')

# A default taken from the environment is not checked by ValidateSet.
if ($From -notin 'resume', 'handoff', 'auto') {
    Write-Host "Note: CRESTORE_FROM='$From' is not resume, handoff or auto - using resume." -ForegroundColor Yellow
    $From = 'resume'
}
if ($Effort -notin 'low', 'medium', 'high', 'xhigh', 'max', 'inherit', 'none') {
    Write-Host "Note: CRESTORE_EFFORT='$Effort' is not low, medium, high, xhigh, max, inherit or none - using inherit." -ForegroundColor Yellow
    $Effort = 'inherit'
}
# The level reaches claude as written, so in lower case: ValidateSet and -notin take it in any case.
$Effort = $Effort.ToLowerInvariant()
if ($HandoffOnly) {
    if ($PSBoundParameters.ContainsKey('From') -and $From -ne 'handoff') { Write-Host "Note: -HandoffOnly brings sessions back from a handoff; -From $From is ignored." -ForegroundColor Yellow }
    $From = 'handoff'
}
# -AsIfRestarted shows what a restart would offer while the sessions it counts as closed are still running: starting
# one of them would put a second writer on a live session, so it never starts anything.
if ($AsIfRestarted) {
    if ($Prepare -or $Prune) { Write-Host '-AsIfRestarted goes with a restore listing (-List, or -DryRun), not with -Prepare or -Prune.' -ForegroundColor Yellow; return }
    if (-not $DryRun) { $DryRun = [switch]$true; if (-not $List) { Write-Host 'Note: -AsIfRestarted starts nothing: it runs as -DryRun.' -ForegroundColor Yellow } }
}
# `crestore a,b` arrives as an array, `pwsh -File ... a,b` as one string: either way, a list of folder fragments.
$Project = @($Project | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim().TrimEnd('\', '/') } | Where-Object { $_ })

# ---------- startup task management ----------
if ($InstallStartup) {
    $pwshExe = (Get-Command pwsh).Source
    $action  = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoLogo -NoProfile -File `"$PSCommandPath`" -FromStartup"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $trigger.Delay = 'PT45S'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Write-Host "Installed logon task '$taskName' (interactive picker, 45 s after logon)."
    return
}
if ($UninstallStartup) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed logon task '$taskName'."
    return
}

if ($Prune) {
    $n = 0
    foreach ($f in Get-ChildItem $registryDir -Filter '*.json' -ErrorAction SilentlyContinue) {
        try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not $e.ended_at) {
            $e | Add-Member -NotePropertyName ended_at   -NotePropertyValue (Get-Date -Format o) -Force
            $e | Add-Member -NotePropertyName end_reason -NotePropertyValue 'pruned' -Force
            $e | ConvertTo-Json -Depth 5 | Set-Content $f.FullName -Encoding utf8
            $n++
        }
    }
    Write-Host "Marked $n open session(s) as ended."
    $old = @(Get-ChildItem (Join-Path $guardDir 'live') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) })
    if ($old.Count) { $old | Remove-Item -Force -ErrorAction SilentlyContinue; Write-Host "Removed $($old.Count) handoff-guard record(s) older than 7 days." }
    return
}

# ---------- helpers ----------
function Read-FileHead([string]$path, [int]$bytes = 65536) {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $buf = New-Object byte[] $bytes
        $n = $fs.Read($buf, 0, $buf.Length)
        return [Text.Encoding]::UTF8.GetString($buf, 0, $n)
    } finally { $fs.Dispose() }
}

function Get-TranscriptTitle([string]$path) {
    try {
        $head = Read-FileHead $path
        $m = [regex]::Match($head, '"type":"summary","summary":"((?:[^"\\]|\\.)*)"')
        if ($m.Success) { return (Limit-Title ([regex]::Unescape($m.Groups[1].Value))) }
        # no summary record -> first real user message becomes the title
        $re = '"role":"user","content":(?:"((?:[^"\\]|\\.)*)"|\[\{"type":"text","text":"((?:[^"\\]|\\.)*)")'
        foreach ($mm in [regex]::Matches($head, $re)) {
            $t = if ($mm.Groups[1].Success) { $mm.Groups[1].Value } else { $mm.Groups[2].Value }
            $t = ([regex]::Unescape($t) -replace '\s+', ' ').Trim()
            if ($t -and $t -notmatch '^[<\[]' -and $t -notmatch '^Caveat') { return (Limit-Title $t) }
        }
    } catch {}
    return $null
}

function Limit-Title([string]$t, [int]$max = 58) {
    $t = ($t -replace '\s+', ' ').Trim()
    if ($t.Length -gt $max) { return $t.Substring(0, $max) + [char]0x2026 }
    return $t
}

function Get-TranscriptCwd([string]$path) {
    try {
        $head = Read-FileHead $path
        $m = [regex]::Match($head, '"cwd":"((?:[^"\\]|\\.)*)"')
        if ($m.Success) { return [regex]::Unescape($m.Groups[1].Value) }
    } catch {}
    return $null
}

# When the session last took a turn: the newest user or assistant record in its transcript. The file's write time
# says less: Claude Code appends bookkeeping records (a remote-control bridge record, a title) to every open
# transcript, idle or not, so a session idle for days can carry this morning's time. $null when no such record
# carries a time; the caller then goes by the file's time, as before.
function Get-LastTurnTime([string]$path) {
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            $len = $fs.Length
            for ($chunk = [long]512KB; ; $chunk *= 4) {
                $take = [long][Math]::Min($chunk, $len)
                $buf = New-Object byte[] $take
                [void]$fs.Seek($len - $take, 'Begin')
                $got = 0
                while ($got -lt $take) { $n = $fs.Read($buf, $got, $take - $got); if ($n -le 0) { break }; $got += $n }
                $lines = [Text.Encoding]::UTF8.GetString($buf, 0, $got) -split "`n"
                $first = if ($take -lt $len) { 1 } else { 0 }   # a window that starts mid-file starts mid-line
                for ($i = $lines.Count - 1; $i -ge $first; $i--) {
                    $l = $lines[$i]
                    if ($l -notmatch '"type":"(user|assistant)"' -or $l -notmatch '"timestamp":"') { continue }
                    # Parsed, not matched: a nested object can carry its own type and timestamp.
                    try { $j = $l | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                    if ("$($j.type)" -notin 'user', 'assistant' -or -not $j.timestamp) { continue }
                    $at = $j.timestamp
                    if ($at -isnot [datetime]) { $at = [datetime]::Parse("$at", $inv, [System.Globalization.DateTimeStyles]::RoundtripKind) }
                    elseif ($at.Kind -eq 'Unspecified') { $at = [datetime]::SpecifyKind($at, 'Utc') }
                    return $at.ToLocalTime()
                }
                if ($take -ge $len -or $chunk -ge 64MB) { break }
            }
        } finally { $fs.Dispose() }
    } catch {}
    return $null
}

# The folder filter: no -Project offers every folder, several offer a session whose folder matches any of them.
function Test-ProjectMatch([string]$cwd) {
    if ($Project.Count -eq 0) { return $true }
    foreach ($p in $Project) { if ($cwd -like "*$p*") { return $true } }
    return $false
}

function Format-Age([TimeSpan]$ts) {
    if ($ts.TotalMinutes -lt 60) { return '{0}m ago' -f [int]$ts.TotalMinutes }
    if ($ts.TotalHours -lt 24)   { return '{0}h ago' -f [int]$ts.TotalHours }
    return '{0}d ago' -f [int]$ts.TotalDays
}

# Numbers are printed the same way on every machine, whatever its regional format (a decimal point, not a comma).
$inv = [cultureinfo]::InvariantCulture
function Format-Tokens($n) {
    if ($null -eq $n) { return '?' }
    $n = [double]$n
    if ($n -ge 1e6) { return ($n / 1e6).ToString('0.00', $inv) + 'M' }
    if ($n -ge 1e3) { return ($n / 1e3).ToString('0', $inv) + 'k' }
    return $n.ToString('0', $inv)
}

# The process a registry entry was recorded for is still a claude: the session is open in some terminal.
function Test-EntryAlive($e) {
    if (-not $e.pid) { return $false }
    $proc = Get-Process -Id $e.pid -ErrorAction SilentlyContinue
    return [bool]($proc -and $proc.ProcessName -match '^(claude|node)')
}

# A session that never got a prompt took nothing over: its transcript is missing or holds no reply yet.
function Test-TranscriptHasTurn([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $false }
    try {
        if ((Get-Item -LiteralPath $path).Length -gt 2MB) { return $true }
        return (Read-FileHead $path 2097152) -match '"type":"assistant"'
    } catch { return $false }
}

# Replay only known-safe launch flags from the recorded claude command line.
function Get-ReplayFlags([string]$cmdline) {
    if (-not $cmdline) { return @() }
    $arity = @{ '--dangerously-skip-permissions' = 0; '--model' = 1; '--permission-mode' = 1; '--add-dir' = 1; '--effort' = 1 }
    $tokens = @([regex]::Matches($cmdline, '"([^"]*)"|(\S+)') | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
    })
    $flags = @()
    for ($i = 1; $i -lt $tokens.Count; $i++) {   # skip argv[0]
        $t = $tokens[$i]
        if ($t -match '^(--[a-z-]+)=(.*)$') {
            if ($arity.ContainsKey($Matches[1]) -and $arity[$Matches[1]] -eq 1) { $flags += $Matches[1], $Matches[2] }
            continue
        }
        if ($arity.ContainsKey($t)) {
            $flags += $t
            if ($arity[$t] -eq 1 -and $i + 1 -lt $tokens.Count) { $flags += $tokens[++$i] }
        }
    }
    return $flags
}

# `claude --effort` landed in 2.1.24x; on an older CLI the flag would break every
# restore, so probe once per run and degrade to omitting it.
$script:effortSupported = $null
function Test-EffortSupported {
    if ($null -eq $script:effortSupported) {
        try { $script:effortSupported = [bool]((claude --help 2>$null) -match '--effort') }
        catch { $script:effortSupported = $false }
        if (-not $script:effortSupported) {
            Write-Host "Note: this claude CLI has no --effort flag - restoring without it." -ForegroundColor Yellow
        }
    }
    return $script:effortSupported
}

function Resolve-Effort($c) {
    if ($Effort -eq 'none') { return $null }
    $level = $Effort
    if ($Effort -eq 'inherit') {
        $level = $null
        $f = @(Get-ReplayFlags $c.Cmdline)
        for ($i = 0; $i -lt $f.Count - 1; $i++) { if ($f[$i] -eq '--effort') { $level = $f[$i + 1]; break } }
        if (-not $level) { return $null }
    }
    if (-not (Test-EffortSupported)) { return $null }
    return $level
}

# The launch flags a restored session gets, whichever way it comes back.
function Get-LaunchFlags($c) {
    # Drop any replayed --effort pair: the -Effort parameter is the single decision
    # point, so a session can never end up carrying the flag twice.
    $replayed = @(Get-ReplayFlags $c.Cmdline)
    $flags = @()
    for ($i = 0; $i -lt $replayed.Count; $i++) {
        if ($replayed[$i] -eq '--effort') { $i++; continue }
        $flags += $replayed[$i]
    }
    $level = Resolve-Effort $c
    if ($level) { $flags += '--effort', $level }
    return $flags
}

function Build-ResumeCommand($c) {
    $parts = @('claude') + @(Get-LaunchFlags $c) + @('--resume', $c.SessionId)
    return ($parts | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' '
}

# A session that comes back from a handoff: the arguments its fresh claude gets.
function Get-HandoffArgs($c) {
    $a = @(Get-LaunchFlags $c)
    $n = "$($c.Wake.name)".Trim()
    if ($n) { $a += '-n', $n }
    $pointer = if ($c.Wake.append) { "$($c.Wake.append)" } else { "<one line pointing at the handoff pack, about $(Format-Tokens $c.Wake.pack.tokens) tokens>" }
    return $a + @('--append-system-prompt', $pointer)
}

# Queue the wake file Start-HandoffSession.ps1 reads, and return the command that runs it in the new tab.
# The arguments travel in the file, never on that command line, so no title or path has to survive a shell.
# -AnyShell: the command is typed into a terminal whose shell is not ours to choose (VS Code: PowerShell 7,
# Windows PowerShell, cmd or Git Bash), so it starts PowerShell 7 itself instead of assuming it.
function Build-HandoffCommand($c, [switch]$NoWrite, [switch]$AnyShell) {
    if (-not $NoWrite) {
        New-Item -ItemType Directory -Path $wakeDir -Force | Out-Null
        $w = [ordered]@{
            session_id = $c.SessionId; cwd = $c.Cwd; name = "$($c.Wake.name)"; pack = "$($c.Wake.pack.path)"
            args = @(Get-HandoffArgs $c); created_at = (Get-Date).ToString('o')
        }
        # Its own handoff, not a pack: it saved no transcript, so the tab must not offer `claude --resume` instead.
        if ($c.Wake.own) { $w.no_transcript = $true }
        $w | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $wakeDir "$($c.SessionId).json") -Encoding utf8
    }
    if ($AnyShell) { return "pwsh -NoLogo -NoProfile -File `"$launcher`" $($c.SessionId)" }
    return "& '$($launcher -replace "'", "''")' $($c.SessionId)"
}

# Ask acct-sync how the given sessions should come back; with -Write it also writes their handoff packs.
# It reads transcripts and never calls a model. $null when it cannot run: the caller then resumes in full.
function Invoke-Wake([string[]]$Ids, [string]$Mode, [switch]$Write) {
    if (-not $Ids -or $Ids.Count -eq 0) { return $null }
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node -or -not (Test-Path -LiteralPath $acctSync)) { return $null }
    $a = @($acctSync, 'wake', '--json', '--mode', $Mode)
    if ($Write) { $a += '--write' }
    if ($To) { $a += '--to', $To }
    $a += $Ids
    $errFile = [IO.Path]::GetTempFileName()
    $ErrorActionPreference = 'Continue'   # in this function only: a line on stderr is not a failure
    try {
        $raw = & $node.Source @a 2> $errFile
        if ($LASTEXITCODE -ne 0) {
            $msg = (Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue | Select-Object -First 2) -join ' '
            if ($msg -notmatch '^acct-sync') { $msg = "acct-sync: $msg" }
            Write-Host $msg -ForegroundColor Yellow
            return $null
        }
        return (($raw -join "`n") | ConvertFrom-Json)
    } catch {
        Write-Host "acct-sync could not be run: $_" -ForegroundColor Yellow
        return $null
    } finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
}

# Keep the local VS Code extension (consumer of vscode-pending files) in sync.
function Install-VsCodeExtension {
    $src = Join-Path $PSScriptRoot 'vscode-ext'
    $dst = Join-Path $env:USERPROFILE '.vscode\extensions\gjovanov.claude-session-restore-0.1.0'
    if (-not (Test-Path (Join-Path $src 'package.json'))) { throw "extension source missing: $src" }
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Copy-Item (Join-Path $src '*') $dst -Force
}

# ---------- -Prepare: an up-to-date handoff in every open session, before a restart ----------
# The handoff-guard plugin (https://github.com/gjovanov/handoff-guard) in each session looks for request.json every
# 10 s. A session whose handoff is stale and whose prompt cache is warm runs its handoff command (one turn: this is
# what -Prepare spends); each answers in its own live/<sid>.json. This waits for the answers and says who can come back from a
# handoff of its own. A session it cannot reach (no guard loaded, a cold cache, a hub worker) comes back from a pack
# of its transcript, as without -Prepare.
function Get-When($v) {
    if ($v -is [datetime]) { return $v }
    try { return [datetime]::Parse("$v", $inv, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { return [datetime]::MinValue }
}

function Read-GuardRecord([string]$sid) {
    # A record read while its session rewrites it can be empty or cut short: read it again.
    $p = Join-Path (Join-Path $guardDir 'live') "$sid.json"
    for ($try = 0; $try -lt 3; $try++) {
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        try { $r = Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop; if ($r) { return $r } } catch { }
        Start-Sleep -Milliseconds 150
    }
    return $null
}

function Format-GuardTime($ms) {
    if (-not $ms) { return '' }
    try { return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms).LocalDateTime.ToString('yyyy-MM-dd HH:mm', $inv) } catch { return '' }
}

# ---------- a session that saved no transcript ----------
# A claude that inherits CLAUDE_CODE_CHILD_SESSION (one started from inside a Claude Code session, or from a terminal
# or a VS Code window that such a session opened) saves no transcript (2.1.322: "nested_marker"), though hook.ps1
# still records the path it would have had. Nothing can resume it, and acct-sync, which reads transcripts, has no
# pack for it. What is left is handoff-guard's record of it: its newest handoff (track.handoffPath), when it last took
# a turn, and whether work came after that handoff; and Cache Keeper's, which holds its name.
function Test-HasTranscript($e) { return [bool]($e.transcript_path -and (Test-Path -LiteralPath "$($e.transcript_path)")) }

# A time in handoff-guard's records (milliseconds since 1970), as local time; $null for none.
function ConvertFrom-GuardMs($ms) {
    try { $n = [long]$ms } catch { return $null }
    if ($n -le 0) { return $null }
    try { return [DateTimeOffset]::FromUnixTimeMilliseconds($n).LocalDateTime } catch { return $null }
}

# Today as HH:mm, another day with its date: the times a list line can afford.
function Format-Clock([datetime]$t) {
    if ($t.Date -eq (Get-Date).Date) { return $t.ToString('HH:mm', $inv) }
    return $t.ToString('MM-dd HH:mm', $inv)
}

function Read-CacheKeeperRecord([string]$sid) {
    $p = Join-Path (Join-Path $ckDir 'live') "$sid.json"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

# A session's name for a tab and a list line, cut the way acct-sync cuts one (wakeName).
function Get-PlainName([string]$name) {
    $n = ("$name" -replace '["`\r\n]+', ' ' -replace '\s+', ' ').Trim()
    if ($n.Length -gt 60) { $n = $n.Substring(0, 60).Trim() }
    if ($n) { return $n }
    return $null
}

# What is left of a session that saved no transcript.
#   Used:     it took a turn (lastTurnAt or track.workAt), one is running in it (busy), or Cache Keeper saw a context in
#             it. A first turn that is still running has no lastTurnAt yet, and can hold 200k tokens.
#   Active:   its last turn, else its last work, else the record's last write; the registry's started_at without a record.
#   Touched:  when the record was last written: the window's first cut, as a transcript's file time is.
#   Handoff:  track.handoffPath when that file exists (HandoffGone when it does not); Stale when turns or work came after it.
function Get-NoTranscriptState($e) {
    $sid = "$($e.session_id)"
    $rec = Read-GuardRecord $sid
    $ck  = Read-CacheKeeperRecord $sid
    $t   = if ($rec) { $rec.track } else { $null }
    $lastTurn = ConvertFrom-GuardMs $rec.lastTurnAt
    $workAt   = ConvertFrom-GuardMs $t.workAt
    $updated  = ConvertFrom-GuardMs $rec.updatedAt
    $started  = Get-When $e.started_at
    if ($started -eq [datetime]::MinValue) { $started = $null } elseif ($started.Kind -eq 'Utc') { $started = $started.ToLocalTime() }
    $active   = @($lastTurn, $workAt, $updated, $started) | Where-Object { $_ } | Select-Object -First 1
    $touched  = if ($updated) { $updated } elseif ($rec) { (Get-Item -LiteralPath (Join-Path (Join-Path $guardDir 'live') "$sid.json")).LastWriteTime } else { $started }
    if (-not $active) { $active = [datetime]::MinValue }
    if (-not $touched) { $touched = [datetime]::MinValue }
    $hp = if ($t -and $t.handoffPath) { "$($t.handoffPath)" } else { $null }
    $hpOk = [bool]($hp -and (Test-Path -LiteralPath $hp -PathType Leaf))
    $handoffAt = ConvertFrom-GuardMs $t.handoffAt
    if ($hpOk -and -not $handoffAt) { $handoffAt = (Get-Item -LiteralPath $hp).LastWriteTime }
    $turnsAfter = 0
    try { $turnsAfter = [int]$t.turnsAfter } catch {}
    $stale = $turnsAfter -gt 0 -or ($workAt -and (-not $handoffAt -or $workAt -gt $handoffAt))
    $ctx = "$($ck.context.tokens)" -as [double]
    $used = [bool]($lastTurn -or $workAt -or ($rec -and $rec.busy -eq $true) -or ($ctx -gt 0))
    $name = Get-PlainName "$($ck.sessionName)"
    if (-not $name -and $hpOk) {
        try {
            $h = Get-Content -LiteralPath $hp -TotalCount 40 -ErrorAction Stop | Where-Object { $_ -match '^#{1,3}\s+\S' } | Select-Object -First 1
            if ($h) { $name = Get-PlainName ($h -replace '^#+\s+', '') }
        } catch {}
    }
    return [pscustomobject]@{
        Record = $rec; Ended = [bool]($rec -and $rec.endedAt); Worker = [bool]($rec -and "$($rec.role)" -eq 'worker')
        Used = $used; LastTurn = $lastTurn; Active = $active; Touched = $touched
        Handoff = $(if ($hpOk) { $hp } else { $null }); HandoffGone = $(if ($hp -and -not $hpOk) { $hp } else { $null })
        HandoffAt = $handoffAt; TurnsAfter = $turnsAfter; Stale = [bool]($hpOk -and $stale); Name = $name
    }
}

# "handoff from 19:37", and when work came after it, how much: "handoff from 19:37, 2 turns after it".
function Format-OwnHandoff($n) {
    $s = if ($n.HandoffAt) { "handoff from $(Format-Clock $n.HandoffAt)" } else { 'handoff' }
    if (-not $n.Stale) { return $s }
    if ($n.TurnsAfter -gt 0) { return "$s, $($n.TurnsAfter) turn$(if ($n.TurnsAfter -ne 1) { 's' }) after it" }
    return "$s, work after it"
}

# The line a session that comes back from its own handoff is started with (--append-system-prompt), worded as
# acct-sync's wakeAppend is (tests/test-pointer.ps1 says why each part is there), naming that handoff instead of a pack.
# No double quote, backtick, dollar or percent sign: it is one argument, and it may pass through a shell.
function Get-OwnHandoffPointer([string]$sid, $n) {
    $plain = ("$($n.Name)" -replace '["''`$%\\\r\n]+', ' ' -replace '\s+', ' ').Trim()
    $who = if ($plain) { "$($sid.Substring(0, 8)), named '$plain'" } else { $sid.Substring(0, 8) }
    $behind = ''
    if ($n.Stale) {
        $went = if ($n.TurnsAfter -gt 0) { "went on for $($n.TurnsAfter) turn$(if ($n.TurnsAfter -ne 1) { 's' })" } else { 'went on working' }
        $behind = " That session $went after it wrote that file, so the file can be behind on what it did last: check the current state of what the file describes before you rely on it."
    }
    return "This session was started to carry on the work of an earlier Claude Code session ($who) whose conversation was not saved. Its handoff is the file '$("$($n.Handoff)" -replace '\\', '/')'.$behind This holds only for the conversation the session started with: a conversation that begins with /clear (recorded at its start as <command-name>/clear</command-name>) has a brief of its own, and for it this pointer is spent, so do not read the file there unless that conversation asks for it. When the first message of this conversation arrives, read that file in full before you act on the message, then act on it with the handoff as the record of the work so far. Do this once: later in the conversation, also after a compaction, open the file again only when you need a detail from it."
}

if ($Prepare) {
    # One session per claude process, the newest: /clear and /resume run another session in the same process.
    $open = @{}
    foreach ($f in Get-ChildItem $registryDir -Filter '*.json' -ErrorAction SilentlyContinue) {
        try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not $e.session_id -or $e.ended_at -or -not (Test-EntryAlive $e)) { continue }
        if (-not (Test-ProjectMatch "$($e.cwd)")) { continue }
        $k = "$($e.pid)"
        if (-not $open.ContainsKey($k) -or (Get-When $e.started_at) -gt (Get-When $open[$k].started_at)) { $open[$k] = $e }
    }
    $live = @($open.Values | Sort-Object cwd, { Get-When $_.started_at })
    # Records of sessions gone for a week go. An open session keeps its own, however long it has sat idle.
    $keep = @{}
    foreach ($e in $live) { $keep["$($e.session_id).json"] = $true }
    $old = @(Get-ChildItem (Join-Path $guardDir 'live') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) -and -not $keep[$_.Name] })
    $old | Remove-Item -Force -ErrorAction SilentlyContinue
    $state = @{}

    if ($live.Count -eq 0) {
        Write-Host 'No open Claude sessions: nothing to hand off.'
    } elseif ($DryRun) {
        Write-Host "Open Claude sessions and their handoffs (-DryRun: nothing asked):" -ForegroundColor Cyan
        foreach ($e in $live) {
            $sid = "$($e.session_id)"
            $rec = Read-GuardRecord $sid
            $noTx = -not (Test-HasTranscript $e)
            $ttl = if ($noTx) { (Get-NoTranscriptState $e).Name } else { Get-TranscriptTitle "$($e.transcript_path)" }
            $tag = if (-not $rec) { 'no guard' } elseif ($rec.upToDate) { 'up to date' } else { 'stale' }
            Write-Host ('  {0,-11} {1}  {2,-16} {3}{4}' -f $tag, $sid.Substring(0, 8), (Limit-Title (Split-Path "$($e.cwd)" -Leaf) 16), $(if ($ttl) { Limit-Title $ttl } else { '(untitled)' }), $(if ($noTx) { '  [no transcript]' } else { '' }))
            if ($rec -and $rec.track -and $rec.track.handoffPath) {
                Write-Host ("              last handoff {0}: {1}" -f (Format-GuardTime $rec.track.handoffAt), $rec.track.handoffPath)
            }
        }
        if (@($live | Where-Object { -not (Test-HasTranscript $_) }).Count) {
            Write-Host '[no transcript]: the session saved no transcript, so after a restart only its newest handoff can bring it back.'
        }
    } else {
        $rid = if ($env:CRESTORE_PREPARE_ID) { $env:CRESTORE_PREPARE_ID } else { [guid]::NewGuid().ToString('n').Substring(0, 12) }
        $askedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $request = [ordered]@{
            id = $rid; reason = 'restart'; at = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", $inv)
            includeCold = [bool]$IncludeCold; sids = @($live | ForEach-Object { "$($_.session_id)" })
        }
        New-Item -ItemType Directory -Path $guardDir -Force | Out-Null
        $reqPath = Join-Path $guardDir 'request.json'
        $tmp = "$reqPath.$PID.tmp"
        $request | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination $reqPath -Force

        $final = @('current', 'written', 'skipped', 'failed')
        foreach ($e in $live) { $state["$($e.session_id)"] = [pscustomobject]@{ State = 'asked'; Path = ''; Why = ''; Done = $false } }
        $began = Get-Date
        $deadline = $began.AddMinutes([math]::Max(0.05, $PrepareMinutes))
        # Every guard looks every 10 s, so one that has not answered in 30 s stops holding the wait open.
        $grace = if ($env:CRESTORE_PREPARE_GRACE_S) { [double]$env:CRESTORE_PREPARE_GRACE_S } else { [math]::Min(30, ($deadline - $began).TotalSeconds) }
        Write-Host "Asked $($live.Count) open session(s) for an up-to-date handoff. Waiting up to $($PrepareMinutes.ToString('0.##', $inv)) min; Ctrl+C stops waiting (the sessions go on)." -ForegroundColor Cyan
        while ($true) {
            $waiting = 0
            foreach ($e in $live) {
                $s = $state["$($e.session_id)"]
                if ($s.Done) { continue }
                $rec = Read-GuardRecord "$($e.session_id)"
                $ans = if ($rec -and $rec.request -and "$($rec.request.id)" -eq $rid) { $rec.request } else { $null }
                if ($ans) {
                    $s.State = "$($ans.state)"; $s.Path = "$($ans.path)"; $s.Why = "$($ans.why)"
                    if ($s.State -in $final) { $s.Done = $true; continue }
                } elseif ($rec -and $rec.endedAt -and [long]$rec.endedAt -ge $askedMs) {
                    $s.State = 'ended'; $s.Why = "the session ended ($($rec.endReason))"; $s.Done = $true; continue
                } elseif (((Get-Date) - $began).TotalSeconds -ge $grace) {
                    # It no longer holds the wait open, but it is read again while others are still being written.
                    $s.State = 'no answer'
                    $s.Why = if ($rec) { 'its handoff-guard did not answer' } else { 'no handoff-guard in it (a session started before the plugin was installed)' }
                    continue
                }
                $waiting++
            }
            if ($waiting -eq 0 -or (Get-Date) -ge $deadline) { break }
            $counts = @($state.Values | Group-Object State | Sort-Object Name | ForEach-Object { "$($_.Count) $($_.Name)" })
            Write-Host ("`r  {0} ...   " -f ($counts -join ', ')) -NoNewline
            Start-Sleep -Milliseconds 1500
        }
        Write-Host ''

        $label = @{ written = 'written'; current = 'current'; skipped = 'skipped'; failed = 'FAILED'; ended = 'ended'; 'no answer' = 'NO ANSWER'; waiting = 'still waiting'; writing = 'still writing'; asked = 'NO ANSWER' }
        Write-Host 'Before the restart:' -ForegroundColor Cyan
        # A session that saved no transcript has no pack to come back from: after a restart only its own newest
        # handoff can bring it back (Get-NoTranscriptState). Each says so under its line, in the state it is in now.
        $fate = @{}   # sid -> own | lost | unused | hub, for the sessions without a transcript
        foreach ($e in $live) {
            $sid = "$($e.session_id)"; $s = $state[$sid]
            $nt = if (Test-HasTranscript $e) { $null } else { Get-NoTranscriptState $e }
            $ttl = if ($nt) { $nt.Name } else { Get-TranscriptTitle "$($e.transcript_path)" }
            $tag = if ($label.ContainsKey($s.State)) { $label[$s.State] } else { $s.State }
            Write-Host ('  {0,-13} {1}  {2,-16} {3}' -f $tag, $sid.Substring(0, 8), (Limit-Title (Split-Path "$($e.cwd)" -Leaf) 16), $(if ($ttl) { Limit-Title $ttl } else { '(untitled)' }))
            $detail = if (($s.State -in @('written', 'current')) -and $s.Path) { $s.Path } else { $s.Why }
            if ($detail) { Write-Host ('                ' + $detail) }
            if (-not $nt -or $s.State -eq 'ended') { continue }
            if ($nt.Worker) { $fate[$sid] = 'hub'; continue }
            # 'cache is cold' is the guard's own wording for that skip (handoff-guard register.ts, answer()).
            $cold = $s.State -eq 'skipped' -and "$($s.Why)" -match 'cache is cold'
            # Not Pack & Clear: handoff-guard does not take a pack as a handoff, and the /clear starts a session whose
            # record is empty, so after a restart nothing would name the pack (decided 2026-11-20).
            $fix = if ($cold) { 'crestore -Prepare -IncludeCold fixes that, at the full price of re-reading it.' } else { "A handoff written in that session (/$handoffCmd) fixes that." }
            if ($nt.Handoff) {
                $fate[$sid] = $(if ($nt.Stale) { 'own-behind' } else { 'own' })
                # Up to date: it comes back from that handoff, which the line above names. Behind: say how far.
                if ($s.State -in @('written', 'current') -and -not $nt.Stale) { continue }
                $when = if ($nt.HandoffAt) { ' from ' + $nt.HandoffAt.ToString('yyyy-MM-dd HH:mm', $inv) } else { '' }
                $behind = if ($nt.Stale) { $(if ($nt.TurnsAfter -gt 0) { ", $($nt.TurnsAfter) turn$(if ($nt.TurnsAfter -ne 1) { 's' }) behind" } else { ', with work after it' }) } else { '' }
                Write-Host "                no transcript on disk: after a restart only its handoff$when remains$behind. $fix" -ForegroundColor Yellow
            } elseif ($nt.Used) {
                $fate[$sid] = 'lost'
                Write-Host "                no transcript on disk and no handoff: after a restart nothing remains. $fix" -ForegroundColor Yellow
            } else {
                $fate[$sid] = 'unused'   # it never took a turn: nothing in it to lose
            }
        }
        $n = @{}
        foreach ($s in $state.Values) { $n[$s.State] = 1 + [int]$n[$s.State] }
        $noTxOf = { param($st) @($live | Where-Object { $state["$($_.session_id)"].State -eq $st -and $fate.ContainsKey("$($_.session_id)") -and $fate["$($_.session_id)"] -ne 'hub' }).Count }
        Write-Host ''
        # One that saved no transcript and has no handoff file can still answer "current" (its guard judged its last
        # handoff current, or saw no work changed since it started): after a restart nothing of it remains, so it is
        # not counted as up to date.
        $lostCurrent = @($live | Where-Object { $fate["$($_.session_id)"] -eq 'lost' -and $state["$($_.session_id)"].State -in @('written', 'current') }).Count
        $line = '{0} of {1} have an up-to-date handoff.' -f ([int]$n['written'] + [int]$n['current'] - $lostCurrent), $live.Count
        if ($lostCurrent) { $line += " $lostCurrent more answered current, but saved no transcript and have no handoff file: nothing of them remains after a restart." }
        Write-Host $line
        if ($n['skipped']) {
            # A worker is skipped too: whatever runs it brings it back (the line under it says so). One that saved no
            # transcript has no pack to come back from: what remains of it is said under it.
            $skipped = @($live | Where-Object { $state["$($_.session_id)"].State -eq 'skipped' -and $fate["$($_.session_id)"] -ne 'hub' -and "$($state["$($_.session_id)"].Why)" -notmatch '^a worker session' })
            $skippedNoTx = @($skipped | Where-Object { $fate.ContainsKey("$($_.session_id)") }).Count
            $cold = @($skipped | Where-Object { "$($state["$($_.session_id)"].Why)" -match 'cache is cold' }).Count
            $say = @()
            if ($skipped.Count -gt $skippedNoTx) { $say += $(if ($skippedNoTx) { 'Skipped ones with a transcript come back from a pack of it.' } else { 'Skipped ones come back from a pack of their transcript.' }) }
            if ($skippedNoTx) { $say += "$skippedNoTx skipped one(s) saved no transcript: what remains of each after a restart is said under it." }
            if ($cold) { $say += '-IncludeCold writes the cold ones'' handoffs too, each re-reading its conversation at the full price.' }
            if ($say) { Write-Host ($say -join ' ') }
        }
        if ($n['no answer'] -or $n['asked']) {
            $tail = if ((& $noTxOf 'no answer') + (& $noTxOf 'asked')) { ' (one that saved no transcript has only what is said under it)' } else { '' }
            Write-Host "NO ANSWER: run /$handoffCmd in that session by hand, or let it come back from its transcript$tail."
        }
        if ($n['writing'] -or $n['waiting']) { Write-Host 'Still writing when the wait ended: give them a minute, or run crestore -Prepare again.' }
        if ($n['failed']) { Write-Host "FAILED: the reason is under each one; run /$handoffCmd there by hand." }
        $own = @($fate.Values | Where-Object { $_ -like 'own*' }).Count
        $ownBehind = @($fate.Values | Where-Object { $_ -eq 'own-behind' }).Count
        $lost = @($fate.Values | Where-Object { $_ -eq 'lost' }).Count
        $noTx = @($fate.Values | Where-Object { $_ -ne 'hub' }).Count
        if ($noTx -eq 0) {
            Write-Host 'After the restart: crestore -From auto brings each back from its handoff or its conversation, whichever fits.'
        } else {
            Write-Host 'After the restart: crestore -From auto brings each one with a transcript back from its handoff or its conversation, whichever fits.'
            $parts = @()
            if ($own) { $parts += "$own come back from their own newest handoff, whatever -From says" + $(if ($ownBehind) { " ($ownBehind of them without the work done after it)" } else { '' }) }
            if ($lost) { $parts += "$lost cannot be brought back (no handoff either)" }
            $idleN = $noTx - $own - $lost
            if ($idleN) { $parts += "$idleN never took a turn, so nothing in them is lost" }
            Write-Host "Of the $noTx without a transcript: $($parts -join '; ')."
        }
    }

    if ($Reboot -and $DryRun) {
        Write-Host 'Not restarting: -DryRun.'
    } elseif ($Reboot) {
        $notReady = @($state.Values | Where-Object { $_.State -notin @('written', 'current', 'skipped', 'ended') }).Count
        $q = if ($notReady) { "$notReady session(s) have no fresh handoff yet. Restart Windows anyway? [y/N]" } else { 'Restart Windows now? [y/N]' }
        # The tests answer for themselves, and only to a stand-in restart command: a real restart is always asked.
        $answer = if ($env:CRESTORE_REBOOT_ANSWER -and $env:CRESTORE_REBOOT_CMD) { $env:CRESTORE_REBOOT_ANSWER } else { Read-Host $q }
        if ("$answer".Trim() -match '^(y|yes)$') {
            $shutdown = if ($env:CRESTORE_REBOOT_CMD) { $env:CRESTORE_REBOOT_CMD } else { 'shutdown.exe' }
            & $shutdown /r /t 60 /c 'crestore -Prepare: Windows restarts in 60 s. shutdown /a cancels.'
            Write-Host 'Windows restarts in 60 s. shutdown /a cancels it.'
        } else {
            Write-Host 'Not restarting.'
        }
    }
    return
}

# ---------- collect candidates ----------
$now    = Get-Date
# Either window is judged by each session's last turn (Get-LastTurnTime); the file's time only pre-filters, as a
# session cannot have taken a turn after its file was last written.
$cutoff = if ($Today) { $now.Date } else { $now.AddHours(-$MaxAgeHours) }
$span   = if ($Today) { 'used today' } else { "last ${MaxAgeHours}h" }
$candidates   = @{}   # session_id -> candidate object
$registrySeen = @{}   # every registry id, incl. cleanly-ended (excluded from -Scan)
$entries      = [System.Collections.Generic.List[object]]::new()
$idleOpen     = [System.Collections.Generic.List[object]]::new()   # file written inside the window, last turn before it
# Open sessions that saved no transcript and come back from nothing (Get-NoTranscriptState): listed, never dropped.
$lost         = [System.Collections.Generic.List[object]]::new()   # did work, and has no handoff: cannot be brought back
$unused       = [System.Collections.Generic.List[object]]::new()   # never took a turn: nothing in it to bring back
$toHub        = [System.Collections.Generic.List[object]]::new()   # a hub worker: its hub brings it back, as before

# A running session is not restored. -AsIfRestarted lists what a restart would offer, so to it none is running.
function Test-Running($e) { return ((-not $AsIfRestarted) -and (Test-EntryAlive $e)) }
# One read of a session's records per run: the takeover check and the list both ask.
$noTxSeen = @{}
function Get-NoTranscriptStateOnce($e) {
    $k = "$($e.session_id)"
    if (-not $noTxSeen.ContainsKey($k)) { $noTxSeen[$k] = Get-NoTranscriptState $e }
    return $noTxSeen[$k]
}
if ($AsIfRestarted) { Write-Host 'As if this machine had just restarted: every open session counts as closed, running or not. Nothing is started.' -ForegroundColor Cyan }

foreach ($f in Get-ChildItem $registryDir -Filter '*.json' -ErrorAction SilentlyContinue) {
    try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (-not $e.session_id) { continue }
    $registrySeen[$e.session_id] = $true
    $entries.Add($e)
}

# A session started from a handoff carries on an older one (hook.ps1 records `continues` and `continued_at`). Once
# the newer one is open in a terminal, or has taken a turn, the older one is no longer the thing to restore. A newer
# one that never got a prompt took nothing over, and the older one is offered again. So is an older one that was
# resumed by hand and written to after the newer one started: then both hold work, and both are offered.
# A newer one that saved no transcript took a turn when its handoff-guard record says so (Get-NoTranscriptState's
# Used: lastTurnAt, track.workAt, a turn running, or a context Cache Keeper saw); an older one without a transcript
# was used again when its record's last turn came after the newer one started.
$bySid = @{}
foreach ($e in $entries) { $bySid["$($e.session_id)"] = $e }
$takenOver = @{}
foreach ($e in $entries) {
    if (-not $e.continues) { continue }
    if (-not ((-not $e.ended_at) -and (Test-Running $e))) {
        $took = if (Test-HasTranscript $e) { Test-TranscriptHasTurn "$($e.transcript_path)" } else { (Get-NoTranscriptStateOnce $e).Used }
        if (-not $took) { continue }
    }
    $old = $bySid["$($e.continues)"]
    if ($old -and $e.continued_at) {
        try {
            $since = ([datetime]$e.continued_at).ToUniversalTime().AddMinutes(1)
            $usedAt = $null
            if (Test-HasTranscript $old) { $usedAt = (Get-Item -LiteralPath $old.transcript_path).LastWriteTimeUtc }
            elseif ((Get-NoTranscriptStateOnce $old).LastTurn) { $usedAt = (Get-NoTranscriptStateOnce $old).LastTurn.ToUniversalTime() }
            if ($usedAt -and $usedAt -gt $since) { continue }
        } catch {}
    }
    $takenOver["$($e.continues)"] = $e.session_id
}

foreach ($e in $entries) {
    if ($e.ended_at) { continue }
    if (-not (Test-HasTranscript $e)) {
        # It saved no transcript, so neither a resume nor a pack can bring it back: it comes back from its own newest
        # handoff (handoff-guard's record names it), whatever -From says, or it is listed as one that cannot come
        # back. The window goes by its record's last turn, then its last work, then the record's last write.
        # A hub worker stays out, as before: its hub brings it back.
        if (Test-Running $e) { continue }
        if ($takenOver.ContainsKey("$($e.session_id)")) { continue }
        $n = Get-NoTranscriptStateOnce $e
        if ($n.Ended -or $n.Touched -lt $cutoff) { continue }
        if (-not $e.cwd -or -not (Test-Path -LiteralPath "$($e.cwd)")) {
            Write-Host "skipping $("$($e.session_id)".Substring(0,8)): folder gone ($($e.cwd))" -ForegroundColor DarkYellow
            continue
        }
        $row = [pscustomobject]@{
            SessionId = "$($e.session_id)"; Cwd = "$($e.cwd)"; Active = $n.Active; Name = $n.Name; Gone = $n.HandoffGone
            Carries = "$($e.continues)"; Older = $(if ($e.continues) { $bySid["$($e.continues)"] } else { $null })
        }
        if ($n.Worker) { $toHub.Add($row); continue }
        if (-not $n.Handoff -and -not $n.Used) { $unused.Add($row); continue }
        # One that did work and has no handoff is listed whenever its record was written inside the window: no
        # -MaxAgeHours brings it back, so the window only keeps out records of sessions long gone.
        if (-not $n.Handoff) { $lost.Add($row); continue }
        if ($n.Active -lt $cutoff) { $idleOpen.Add([pscustomobject]@{ Cwd = $e.cwd; Active = $n.Active }); continue }
        $candidates["$($e.session_id)"] = [pscustomobject]@{
            SessionId = "$($e.session_id)"; Cwd = "$($e.cwd)"; Transcript = $null
            MTime = $n.Active; Cmdline = $e.claude_cmdline; Origin = 'no-transcript'; MaybeLive = $false; Own = $n
        }
        continue
    }
    $mtime = (Get-Item -LiteralPath $e.transcript_path).LastWriteTime
    if ($mtime -lt $cutoff) { continue }
    if (-not $e.cwd -or -not (Test-Path $e.cwd)) {
        Write-Host "skipping $($e.session_id.Substring(0,8)): folder gone ($($e.cwd))" -ForegroundColor DarkYellow
        continue
    }
    if (Test-Running $e) { continue }   # still running in some terminal -> nothing to restore
    if ($takenOver.ContainsKey($e.session_id)) { continue }
    # Last, as it reads the transcript's end. MTime is from here on the last turn (the file's time without one).
    $active = Get-LastTurnTime $e.transcript_path
    if (-not $active) { $active = $mtime }
    if ($active -lt $cutoff) { $idleOpen.Add([pscustomobject]@{ Cwd = $e.cwd; Active = $active }); continue }
    $candidates[$e.session_id] = [pscustomobject]@{
        SessionId = $e.session_id; Cwd = $e.cwd; Transcript = $e.transcript_path
        MTime = $active; Cmdline = $e.claude_cmdline; Origin = 'tracked'; MaybeLive = $false
    }
}

if ($Scan) {
    foreach ($dir in Get-ChildItem $projectsDir -Directory -ErrorAction SilentlyContinue) {
        $recent = Get-ChildItem $dir.FullName -Filter '*.jsonl' -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match $uuidRe -and $_.LastWriteTime -ge $cutoff } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 3
        foreach ($t in $recent) {
            $sid = $t.BaseName
            if ($registrySeen.ContainsKey($sid) -or $candidates.ContainsKey($sid)) { continue }
            $cwd = Get-TranscriptCwd $t.FullName
            if (-not $cwd -or -not (Test-Path $cwd)) { continue }
            $active = Get-LastTurnTime $t.FullName
            if (-not $active) { $active = $t.LastWriteTime }
            if ($active -lt $cutoff) { continue }
            $candidates[$sid] = [pscustomobject]@{
                SessionId = $sid; Cwd = $cwd; Transcript = $t.FullName
                MTime = $active; Cmdline = $null; Origin = 'scanned'
                # scan can't know the owning PID; a very fresh transcript may
                # belong to a session that is still running right now
                MaybeLive = ($t.LastWriteTime -gt $now.AddMinutes(-5))
            }
        }
    }
}

$sessions = @($candidates.Values | Sort-Object Cwd, MTime)
$sessions = @($sessions | Where-Object { Test-ProjectMatch $_.Cwd })
$idle = @($idleOpen | Where-Object { Test-ProjectMatch $_.Cwd })
# Open until recently (their files were written inside the window) but idle for longer: left out, and said so.
function Write-IdleNote {
    if ($idle.Count -eq 0) { return }
    $oldest = (@($idle | Sort-Object Active))[0].Active
    $hours = [int][Math]::Ceiling(($now - $oldest).TotalHours) + 1
    $where = @($idle | Group-Object { Split-Path $_.Cwd -Leaf } | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
    $instead = if ($Today) { ' in place of -Today' } else { '' }
    Write-Host "Not offered: $($idle.Count) session(s) whose last turn was before the window, though their files were written inside it ($where). -MaxAgeHours $hours$instead offers them too." -ForegroundColor DarkGray
}
# Open sessions without a transcript that nothing brings back: each one listed, so none is dropped without a word.
$lostHere   = @($lost | Where-Object { Test-ProjectMatch $_.Cwd } | Sort-Object Cwd, Active)
$unusedHere = @($unused | Where-Object { Test-ProjectMatch $_.Cwd })
$hubHere    = @($toHub | Where-Object { Test-ProjectMatch $_.Cwd })
function Write-LeftOutNotes {
    Write-IdleNote
    if ($lostHere.Count) {
        Write-Host "Cannot be brought back: no transcript and no handoff ($($lostHere.Count)):" -ForegroundColor Yellow
        foreach ($l in $lostHere) {
            $ttl = if ($l.Name) { '"' + (Limit-Title $l.Name 40) + '"' } else { '' }
            Write-Host ('  {0,-22} last active {1} ({2})  {3} {4}' -f (Split-Path $l.Cwd -Leaf), (Format-Clock $l.Active), (Format-Age ($now - $l.Active)), $l.SessionId.Substring(0, 8), $ttl) -NoNewline
            Write-Host "  $($l.Cwd)" -ForegroundColor DarkGray
            if ($l.Gone) { Write-Host "      the handoff its handoff-guard record names is gone: $($l.Gone)" -ForegroundColor DarkGray }
            if ($l.Older -and (Test-HasTranscript $l.Older)) {
                Write-Host "      it carried on $($l.Carries.Substring(0, 8)), whose older conversation is still on disk: claude --resume $($l.Carries)" -ForegroundColor DarkGray
            }
        }
        Write-Host "  Their conversations were never saved (no transcript), and they wrote no handoff. While such a session is still open, a handoff written in it (/$handoffCmd there, or crestore -Prepare: -IncludeCold when its cache is cold) is what can bring it back." -ForegroundColor DarkGray
    }
    if ($unusedHere.Count) {
        $where = @($unusedHere | Group-Object { Split-Path $_.Cwd -Leaf } | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
        $tabs = @($unusedHere | Where-Object { $_.Carries }).Count
        $more = if ($tabs) { " $tabs of them were started from a handoff: the older session each one was to carry on is treated as if it had not been started." } else { '' }
        Write-Host "Not offered: $($unusedHere.Count) session(s) that saved no transcript and never took a turn, so nothing is in them ($where).$more" -ForegroundColor DarkGray
    }
    if ($hubHere.Count) {
        Write-Host "Not offered: $($hubHere.Count) hub worker session(s) that saved no transcript: a hub brings its own workers back." -ForegroundColor DarkGray
    }
}
if ($sessions.Count -eq 0) {
    $hint = if (-not $Scan) { ' (try -Scan for sessions from before the hooks were installed)' } else { '' }
    Write-Host "No restorable Claude sessions found$hint."
    Write-LeftOutNotes
    return
}

# ---------- plan: how each one would come back ----------
# acct-sync knows each session's size, whether its cache is still warm on the login in use, and whether it has a
# recent summary in its own words. With -From resume this only adds the size to the list; nothing depends on it.
# A session that saved no transcript is not acct-sync's to plan: it reads transcripts. It comes back from its own handoff.
$planBy = @{}
$ownHandoff = @($sessions | Where-Object { $_.Origin -eq 'no-transcript' })
$toPlan = @($sessions | Where-Object { $_.Origin -ne 'no-transcript' })
$plan = if ($toPlan.Count -gt 0) { Invoke-Wake -Ids @($toPlan | ForEach-Object { $_.SessionId }) -Mode $From } else { $null }
if ($plan) {
    foreach ($s in @($plan.sessions)) { if ($s.sid -and -not $s.missing) { $planBy["$($s.sid)"] = $s } }
} elseif ($toPlan.Count -eq 0) {
    # nothing to plan: every one of them comes back from its own handoff
} elseif ($HandoffOnly) {
    $only = if ($ownHandoff.Count) { "only the $($ownHandoff.Count) that come back from their own handoff are started" } else { 'nothing is started' }
    Write-Host "Note: no plan from acct-sync ($acctSync) - with -HandoffOnly $only." -ForegroundColor Yellow
} elseif ($From -ne 'resume') {
    $who = if ($ownHandoff.Count) { 'the ones with a transcript' } else { 'sessions' }
    Write-Host "Note: no plan from acct-sync ($acctSync) - $who will be resumed in full." -ForegroundColor Yellow
}

# ---------- list ----------
if ($Scan) {
    # scan mode can't tell an idle-but-open session from a killed one; if claude
    # is running anywhere right now, make the user double-check the selection
    try {
        $live = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -Property ProcessId).Count
        if ($live -gt 0) {
            Write-Host "Note: $live claude process(es) running right now - scanned entries may include sessions still open in some terminal; deselect those." -ForegroundColor Yellow
        }
    } catch {}
}
Write-Host "Restorable Claude sessions ($span):" -ForegroundColor Cyan
$i = 0
$hasMaybeLive = $false
$leafDirs = @{}   # folder name -> the distinct full paths that end in it
foreach ($c in $sessions) {
    $leaf = Split-Path $c.Cwd -Leaf
    if (-not $leafDirs.ContainsKey($leaf)) { $leafDirs[$leaf] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
    [void]$leafDirs[$leaf].Add($c.Cwd)
}
foreach ($c in $sessions) {
    $i++
    $p = $planBy[$c.SessionId]
    $own = $c.Origin -eq 'no-transcript'
    # acct-sync reads the session's own name (a custom title, or Claude's); the transcript's first prompt otherwise.
    # Without a transcript: the name Cache Keeper recorded, else its handoff's heading.
    $ttl = if ($own) { if ($c.Own.Name) { Limit-Title "$($c.Own.Name)" 44 } else { $null } }
           elseif ($p -and $p.name) { Limit-Title "$($p.name)" $(if ($From -eq 'resume') { 58 } else { 44 }) } else { Get-TranscriptTitle $c.Transcript }
    $c | Add-Member -NotePropertyName Index -NotePropertyValue $i -Force
    $c | Add-Member -NotePropertyName Title -NotePropertyValue $ttl -Force
    $c | Add-Member -NotePropertyName Plan  -NotePropertyValue $p -Force
    # One without a transcript comes back from its own handoff, whatever -From says: nothing else can bring it back.
    $c | Add-Member -NotePropertyName Route -NotePropertyValue $(if ($own) { 'handoff' } elseif ($p -and $From -ne 'resume') { "$($p.route)" } else { 'resume' }) -Force
    $name  = Split-Path $c.Cwd -Leaf
    $age   = Format-Age ($now - $c.MTime)
    $title = if ($c.Title) { '"' + $c.Title + '"' } else { $c.SessionId.Substring(0, 8) }
    $flag  = ''
    if ($c.MaybeLive) { $flag = '  [!] may still be running'; $hasMaybeLive = $true }
    if ($own) {
        # "handoff from 19:37", or "handoff from 19:37, 2 turns after it" when work came after it (still offered).
        Write-Host ('[{0,2}] {1,-24} {2,-8} {3}' -f $i, $name, $age, $title) -NoNewline
        Write-Host '  from its handoff (no transcript)' -NoNewline -ForegroundColor Green
        Write-Host (', ' + (Format-OwnHandoff $c.Own)) -NoNewline -ForegroundColor $(if ($c.Own.Stale) { 'Yellow' } else { 'DarkGray' })
        Write-Host ("  $($c.Cwd)$flag") -ForegroundColor DarkGray
        continue
    }
    if (-not $p) {
        Write-Host ('[{0,2}] {1,-24} {2,-8} {3}' -f $i, $name, $age, $title) -NoNewline
        Write-Host ("  $($c.Cwd)$flag") -ForegroundColor DarkGray
        continue
    }
    $cache = if ($p.sameLogin -eq $false) { 'other login' } else { "$($p.cache)" }
    Write-Host ('[{0,2}] {1,-22} {2,-8} ' -f $i, $name, $age) -NoNewline
    Write-Host ('{0,5} {1,-11} ' -f (Format-Tokens $p.ctx), $cache) -NoNewline -ForegroundColor DarkGray
    if ($From -ne 'resume') {
        if ($c.Route -eq 'handoff') { Write-Host ('{0,-9}' -f ('handoff' + $(if ($p.thin) { '~' } else { '' }))) -NoNewline -ForegroundColor Green }
        else { Write-Host ('{0,-9}' -f ('resume' + $(if ($p.compactFirst) { '*' } else { '' }))) -NoNewline }
    }
    Write-Host $title -NoNewline
    # the folder's name is in the second column; the full path only where two folders share that name
    $tail = if ($leafDirs[$name].Count -gt 1) { "  $($c.Cwd)$flag" } else { $flag }
    Write-Host $tail -ForegroundColor DarkGray
}
if ($planBy.Count -gt 0) {
    $planned = @($sessions | Where-Object { $_.Plan })
    $who = if ($plan.login) { if ($plan.login.label) { "$($plan.login.label) ($($plan.login.fp))" } else { "$($plan.login.fp)" } } else { 'unknown' }
    $other = @($planned | Where-Object { $_.Plan.sameLogin -eq $false }).Count
    $line = "Login in use: $who"
    if ($plan.to) { $line += ", planned for '$($plan.to)'" }
    if ($other -gt 0) { $line += ". $other of these last ran on another login" }
    Write-Host "$line." -ForegroundColor DarkGray
    if ($From -eq 'resume') {
        $big = @($planned | Where-Object { $_.Plan.auto -ne 'resume' }).Count
        if ($big -gt 0) {
            Write-Host "$big of these are large and no longer cached: -From auto starts such a session from a handoff pack where it has a recent summary of its own (or add h to its number below)." -ForegroundColor DarkGray
        }
    } else {
        $priced = @($planned | Where-Object { $_.Plan.usd })
        $sumResume = ($priced | ForEach-Object { [double]$_.Plan.usd.resume } | Measure-Object -Sum).Sum
        $sumDo = ($priced | ForEach-Object { if ($_.Route -eq 'handoff') { [double]$_.Plan.usd.handoff } else { [double]$_.Plan.usd.resume } } | Measure-Object -Sum).Sum
        Write-Host 'handoff = a fresh session that reads a handoff pack on your first message (a new session id; the old conversation stays resumable).' -ForegroundColor DarkGray
        if (@($planned | Where-Object { $_.Plan.compactFirst }).Count -gt 0) { Write-Host 'resume*  = too little in its own words for a handoff: resume it, then run /compact before your first prompt.' -ForegroundColor DarkGray }
        if (@($planned | Where-Object { $_.Plan.thin -and $_.Route -eq 'handoff' }).Count -gt 0) { Write-Host 'handoff~ = a thin pack: the session wrote nothing about itself lately, so it rests on prompts and last messages.' -ForegroundColor DarkGray }
        if ($priced.Count -gt 0) {
            Write-Host ("First turn of all $($priced.Count): `$$(([double]$sumResume).ToString('0.00', $inv)) resumed, `$$(([double]$sumDo).ToString('0.00', $inv)) this way (API prices; a plan's limits move in proportion).") -ForegroundColor DarkGray
        }
    }
}
if ($ownHandoff.Count -gt 0) {
    Write-Host 'from its handoff (no transcript) = it saved no transcript, so it comes back as a fresh session that reads its own newest handoff on your first message, whatever -From says; turns after that handoff are not in it.' -ForegroundColor DarkGray
}
Write-LeftOutNotes
if ($List) { return }
# -HandoffOnly with no plan at all: not one of them would get a pack (the note above says why), unless it comes back
# from its own handoff.
if ($HandoffOnly -and $planBy.Count -eq 0 -and $ownHandoff.Count -eq 0) {
    if ($plan) { Write-Host 'Nothing started: acct-sync found none of these transcripts (-HandoffOnly).' -ForegroundColor Yellow }
    return
}

# ---------- select ----------
$force = @{}   # index -> 'handoff' | 'resume', typed in the picker
if ($All) {
    $selected = @($sessions | Where-Object { -not $_.MaybeLive })
} else {
    $def = if ($hasMaybeLive) { 'all except [!]' } else { 'all' }
    $more = if ($planBy.Count -gt 0) { ' | 2h or 4-6r = that one from a handoff / resumed' } else { '' }
    $ans = Read-Host "Restore which sessions? [Enter = $def | e.g. 1,3-5$more | q = none]"
    if ($ans -eq 'q') { return }
    if ($ans -match '^\s*([hr])\s*$') {
        # a letter alone: all of them, that way
        $way = if ($Matches[1] -eq 'h') { 'handoff' } else { 'resume' }
        $selected = @($sessions | Where-Object { -not $_.MaybeLive })
        foreach ($c in $selected) { $force[$c.Index] = $way }
    } elseif ([string]::IsNullOrWhiteSpace($ans)) {
        $selected = @($sessions | Where-Object { -not $_.MaybeLive })
    } else {
        $idx = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($part in $ans -split ',') {
            $part = $part.Trim()
            if ($part -notmatch '^(\d+)(?:\s*-\s*(\d+))?\s*([hr])?$') { continue }
            $a = [int]$Matches[1]
            $b = if ($Matches[2]) { [int]$Matches[2] } else { $a }
            $lo = [Math]::Max(1, [Math]::Min($a, $b))                  # 5-3 means 3-5, as it always did
            $hi = [Math]::Min([Math]::Max($a, $b), $sessions.Count)
            $way = if (-not $Matches[3]) { $null } elseif ($Matches[3] -eq 'h') { 'handoff' } else { 'resume' }
            for ($n = $lo; $n -le $hi; $n++) { [void]$idx.Add($n); if ($way) { $force[$n] = $way } }
        }
        $selected = @($sessions | Where-Object { $idx.Contains($_.Index) })
    }
}
if ($selected.Count -eq 0) { Write-Host 'Nothing selected.'; return }
foreach ($c in $selected) {
    if (-not $force.ContainsKey($c.Index)) { continue }
    if ($c.Origin -eq 'no-transcript' -and $force[$c.Index] -eq 'resume') {
        Write-Host "[$($c.Index)] cannot be resumed: it saved no transcript. It comes back from its handoff." -ForegroundColor Yellow
        continue
    }
    $c.Route = $force[$c.Index]
}
# -HandoffOnly: a session acct-sync did not plan would come back in full, so it stays closed. One it planned as a
# resume holds no more than a fresh session with its pack would (or no request at all): that is the cheaper way back.
# A letter typed in the picker is the person's own choice and stands.
if ($HandoffOnly) {
    foreach ($c in $selected) {
        if ($c.Route -eq 'resume' -and -not $c.Plan -and -not $force.ContainsKey($c.Index)) {
            Write-Host "[$($c.Index)] stays closed: acct-sync has no plan for it, so it would come back in full. By hand: claude --resume $($c.SessionId)" -ForegroundColor Yellow
            $c.Route = 'closed'
        }
    }
}

# ---------- handoff packs for the sessions that come back that way ----------
$viaHandoff = @($selected | Where-Object { $_.Route -eq 'handoff' })
# One without a transcript needs no pack: its own handoff is the file, named in its handoff-guard record. The wake
# file Start-HandoffSession.ps1 reads is the same, with no_transcript set, so the tab does not offer a resume.
foreach ($c in @($viaHandoff | Where-Object { $_.Origin -eq 'no-transcript' })) {
    $tokens = try { [int]((Get-Item -LiteralPath $c.Own.Handoff -ErrorAction Stop).Length / 4) } catch { $null }
    $c | Add-Member -NotePropertyName Wake -NotePropertyValue ([pscustomobject]@{
        sid = $c.SessionId; route = 'handoff'; own = $true; name = $c.Own.Name
        pack = [pscustomobject]@{ path = "$($c.Own.Handoff)"; tokens = $tokens }
        append = (Get-OwnHandoffPointer $c.SessionId $c.Own)
    }) -Force
}
$viaPack = @($viaHandoff | Where-Object { $_.Origin -ne 'no-transcript' })
if ($viaHandoff.Count -gt 0) {
    $wakeBy = @{}
    $woken = if ($viaPack.Count -gt 0) { Invoke-Wake -Ids @($viaPack | ForEach-Object { $_.SessionId }) -Mode 'handoff' -Write:(-not $DryRun) } else { $null }
    if ($woken) { foreach ($s in @($woken.sessions)) { if ($s.sid) { $wakeBy["$($s.sid)"] = $s } } }
    foreach ($c in $viaPack) {
        $s = $wakeBy[$c.SessionId]
        if ($s -and $s.route -eq 'handoff' -and ($DryRun -or ($s.append -and $s.pack.path))) {
            $c | Add-Member -NotePropertyName Wake -NotePropertyValue $s -Force
            continue
        }
        $why = if ($s -and $s.why) { "$($s.why)" } else { 'acct-sync gave no handoff pack' }
        if ($HandoffOnly) {
            Write-Host "[$($c.Index)] stays closed, not resumed in full: $why. By hand: claude --resume $($c.SessionId)" -ForegroundColor Yellow
            $c.Route = 'closed'
            continue
        }
        Write-Host "[$($c.Index)] comes back as a full resume, not from a handoff: $why" -ForegroundColor Yellow
        $c.Route = 'resume'
    }
    if (-not $DryRun) {
        Get-ChildItem $wakeDir -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
# What -HandoffOnly left closed is not started; each one's resume line was printed where that was decided.
$leftClosed = @($selected | Where-Object { $_.Route -eq 'closed' })
if ($leftClosed.Count -gt 0) {
    $selected = @($selected | Where-Object { $_.Route -ne 'closed' })
    if ($selected.Count -eq 0) { Write-Host "Nothing started: all $($leftClosed.Count) stayed closed (-HandoffOnly)."; return }
}

# ---------- spawn ----------
$spawned = 0
$fromHandoff = 0
# What the tab runs: `claude --resume <id>`, or the launcher that starts a fresh session from the wake file.
function Get-TabCommand($c, [switch]$AnyShell) {
    if ($c.Route -eq 'handoff') { return (Build-HandoffCommand $c -NoWrite:$DryRun -AnyShell:$AnyShell) }
    return (Build-ResumeCommand $c)
}
function Write-HandoffDryRun($c) {
    $shown = (@(Get-HandoffArgs $c) | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' '
    Write-Host "    which runs: claude $shown" -ForegroundColor DarkGray
}
function Write-Outcome([string]$where) {
    $resumed = $spawned - $fromHandoff
    $ownN = @($selected | Where-Object { $_.Route -eq 'handoff' -and $_.Origin -eq 'no-transcript' }).Count
    $how = if ($fromHandoff -gt 0) { ": $resumed resumed, $fromHandoff from a handoff" + $(if ($ownN) { " ($ownN of them from their own, having saved no transcript)" } else { '' }) } else { '' }
    Write-Host "$where$how."
    if ($leftClosed.Count -gt 0) { Write-Host "$($leftClosed.Count) stayed closed (-HandoffOnly); the resume line of each is above." -ForegroundColor Yellow }
    if ($fromHandoff -gt 0) { Write-Host 'A handoff tab sends nothing until your first message; Claude reads the pack (or the handoff) then.' -ForegroundColor DarkGray }
    $compact = @($selected | Where-Object { $_.Route -eq 'resume' -and $_.Plan -and $_.Plan.compactFirst -and $From -ne 'resume' })
    if ($compact.Count -gt 0) {
        Write-Host ("Run /compact before your first prompt in: " + (($compact | ForEach-Object { "[$($_.Index)] $($_.Title)" }) -join ', ')) -ForegroundColor DarkGray
    }
}

if ($Target -eq 'vscode') {
    # Queue one pending file per session; the claude-session-restore
    # extension (synced below) consumes them on window startup AND via a
    # directory watcher, so this works whether the target windows are already
    # open or get opened by `code` here. Claim-by-delete in the extension
    # makes each session spawn exactly once.
    $pendingDir = Join-Path $root 'vscode-pending'
    if (-not $DryRun) {
        Install-VsCodeExtension
        New-Item -ItemType Directory -Path $pendingDir -Force | Out-Null
        Get-ChildItem $pendingDir -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-20) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $codeFolders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($c in $selected) {
        $label = if ($c.Title) { $c.Title } else { (Split-Path $c.Cwd -Leaf) + ' ' + $c.SessionId.Substring(0, 8) }
        $label = ($label -replace '["`]', '').Trim()
        if ($label.Length -gt 40) { $label = $label.Substring(0, 40) }
        $cmd = Get-TabCommand $c -AnyShell
        if ($DryRun) {
            Write-Host "queue for VS Code: [$label] $($c.Cwd) :: $cmd"
            if ($c.Route -eq 'handoff') { Write-HandoffDryRun $c }
            continue
        }
        [ordered]@{
            session_id = $c.SessionId; cwd = $c.Cwd; name = $label; command = $cmd
            created_at = (Get-Date).ToString('o'); expires_at = (Get-Date).AddMinutes(15).ToString('o')
        } | ConvertTo-Json | Set-Content -Path (Join-Path $pendingDir "$($c.SessionId).json") -Encoding utf8
        [void]$codeFolders.Add($c.Cwd)
        $spawned++
        if ($c.Route -eq 'handoff') { $fromHandoff++ }
    }
    if (-not $DryRun) {
        foreach ($f in $codeFolders) { & code $f 2>$null; Start-Sleep -Milliseconds 500 }
        Write-Outcome "Queued $spawned session(s) across $($codeFolders.Count) VS Code window(s) - terminals appear as each window loads (queue expires in 15 min)"
    }
    return
}

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
foreach ($c in $selected) {
    $label = if ($c.Title) { $c.Title } else { (Split-Path $c.Cwd -Leaf) + ' ' + $c.SessionId.Substring(0, 8) }
    $label = ($label -replace '[;"`]', '').Trim()
    if ($label.Length -gt 40) { $label = $label.Substring(0, 40) }
    $cmd = Get-TabCommand $c
    if ($DryRun) {
        Write-Host "wt -w $Window nt -d `"$($c.Cwd)`" --title `"$label`" pwsh -NoLogo -NoExit -Command `"$cmd`""
        if ($c.Route -eq 'handoff') { Write-HandoffDryRun $c }
        continue
    }
    if ($wt) {
        & $wt.Source -w $Window nt -d $c.Cwd --title $label pwsh -NoLogo -NoExit -Command $cmd
    } else {
        Start-Process pwsh -WorkingDirectory $c.Cwd -ArgumentList @('-NoLogo', '-NoExit', '-Command', $cmd)
    }
    $spawned++
    if ($c.Route -eq 'handoff') { $fromHandoff++ }
    Start-Sleep -Milliseconds 500
}
if (-not $DryRun) { Write-Outcome "Restored $spawned session(s) into Windows Terminal window '$Window'" }
