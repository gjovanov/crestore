#Requires -Version 7
# Claude Code session-restore tracker (SessionStart + SessionEnd hook).
# Wired in ~/.claude/settings.json; reads the hook event JSON from stdin and
# maintains one registry file per session under ~/.claude/session-restore/registry.
# Restore-ClaudeSessions.ps1 consumes the registry after a reboot: entries without
# a clean SessionEnd are the sessions that were killed by the reboot.
# Must never fail the session: always exits 0, errors go to hook.log.

$ErrorActionPreference = 'Stop'
$root     = if ($env:CRESTORE_ROOT) { $env:CRESTORE_ROOT } else { Join-Path $env:USERPROFILE '.claude\session-restore' }
$registry = Join-Path $root 'registry'
$logFile  = Join-Path $root 'hook.log'

function Write-Log([string]$msg) {
    try { Add-Content -Path $logFile -Value "$(Get-Date -Format o) $msg" -ErrorAction SilentlyContinue } catch {}
}

function Save-Entry([string]$path, $obj) {
    $tmp = "$path.$PID.tmp"
    $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $path -Force
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $evt = $raw | ConvertFrom-Json

    if ($evt.agent_id) { exit 0 }        # subagent, not a restorable terminal session
    if (-not $evt.session_id) { exit 0 }

    New-Item -ItemType Directory -Path $registry -Force | Out-Null
    $entryPath = Join-Path $registry "$($evt.session_id).json"

    if ($evt.hook_event_name -eq 'SessionEnd') {
        if (Test-Path $entryPath) {
            $entry = Get-Content $entryPath -Raw | ConvertFrom-Json
            $entry | Add-Member -NotePropertyName ended_at   -NotePropertyValue (Get-Date -Format o) -Force
            $entry | Add-Member -NotePropertyName end_reason -NotePropertyValue "$($evt.reason)" -Force
            Save-Entry $entryPath $entry
        }
        exit 0
    }

    # ---- SessionStart ----
    # Find the owning claude process: its PID backs the "still running?" check at
    # restore time, its command line lets restore replay launch flags.
    $claudePid = $null; $claudeCmd = $null
    try {
        $procs = @{}
        Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine |
            ForEach-Object { $procs[[uint32]$_.ProcessId] = $_ }
        $cur = $procs[[uint32]$PID]
        for ($i = 0; $i -lt 8 -and $cur; $i++) {
            $parent = $procs[[uint32]$cur.ParentProcessId]
            if (-not $parent) { break }
            if ($parent.Name -match '^(claude|node)') {
                $claudePid = [int]$parent.ProcessId
                $claudeCmd = $parent.CommandLine
                break
            }
            # only walk through shell wrappers claude may have used to spawn us
            # (Claude Code on Windows can run hooks through Git Bash, so bash/sh must be
            #  walkable)
            if ($parent.Name -notmatch '^(pwsh|powershell|cmd|conhost|bash|sh)') { break }
            $cur = $parent
        }
    } catch { Write-Log "parent walk failed: $_" }

    # Headless runs are not restorable interactive sessions.
    if ($claudeCmd -and $claudeCmd -match '(^|\s)(-p|--print)(\s|$)') { exit 0 }

    # A session that crestore started from a handoff pack carries on an older one: Start-HandoffSession.ps1 sets
    # CRESTORE_WAKE to the older id for that one claude process. Only the process's first session is the successor
    # (a /clear or a fork in it starts an unrelated id), and a later resume of that session keeps the link.
    # Restore-ClaudeSessions.ps1 stops offering the older session once this one is running or has taken a turn,
    # unless the older one was used again after `continued_at`. That time is the launcher's (CRESTORE_WAKE_AT), not
    # this hook's clock: a claude started later from inside the session inherits both variables, and so records the
    # same moment instead of a later one that would hide work done in the older session in between.
    $continues = $null; $continuedAt = $null
    if ("$($evt.source)" -eq 'startup' -and "$($env:CRESTORE_WAKE)" -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -and $env:CRESTORE_WAKE -ne $evt.session_id) {
        $continues = $env:CRESTORE_WAKE
        $at = [datetimeoffset]::MinValue
        $continuedAt = if ([datetimeoffset]::TryParse("$($env:CRESTORE_WAKE_AT)", [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$at)) { $at.UtcDateTime.ToString('o') } else { (Get-Date).ToUniversalTime().ToString('o') }
    } elseif (Test-Path $entryPath) {
        try {
            $prev = Get-Content $entryPath -Raw | ConvertFrom-Json
            if ($prev.continues) {
                $continues = "$($prev.continues)"
                if ($prev.continued_at) { $continuedAt = ([datetime]$prev.continued_at).ToUniversalTime().ToString('o') }
            }
        } catch {}
    }

    $entry = [ordered]@{
        session_id      = $evt.session_id
        cwd             = $evt.cwd
        transcript_path = $evt.transcript_path
        source          = "$($evt.source)"
        started_at      = Get-Date -Format o
        pid             = $claudePid
        claude_cmdline  = $claudeCmd
    }
    if ($continues) { $entry.continues = $continues; if ($continuedAt) { $entry.continued_at = $continuedAt } }
    Save-Entry $entryPath $entry

    # /clear and forking start a NEW session id inside the same claude process:
    # the previous id is no longer the one to restore for this terminal.
    if ($claudePid -and "$($evt.source)" -in @('clear', 'fork')) {
        foreach ($f in Get-ChildItem $registry -Filter '*.json' -ErrorAction SilentlyContinue) {
            if ($f.BaseName -eq $evt.session_id) { continue }
            try {
                $other = Get-Content $f.FullName -Raw | ConvertFrom-Json
                if (-not $other.ended_at -and $other.pid -eq $claudePid) {
                    $other | Add-Member -NotePropertyName ended_at   -NotePropertyValue (Get-Date -Format o) -Force
                    $other | Add-Member -NotePropertyName end_reason -NotePropertyValue 'superseded' -Force
                    Save-Entry $f.FullName $other
                }
            } catch {}
        }
    }

    # Registry GC
    $cutoff = (Get-Date).AddDays(-14)
    Get-ChildItem $registry -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch {
    Write-Log "hook error: $_"
}
exit 0
