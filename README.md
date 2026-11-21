# crestore

A PowerShell tool for Claude Code on Windows. It brings back every Claude Code session that a restart closed: each one in
its own terminal tab, in its own folder. A session comes back whole (`claude --resume <id>`), or, with acct-sync, as a
fresh session that reads a handoff of it on your first message, where that costs less.

```powershell
crestore              # the closed sessions of the last 72 hours, in a picker: Enter brings them all back
```

A hook records every session Claude Code starts. A session that never ended cleanly is one that a reboot, a crash or a
closed terminal took away, and crestore offers it. Nothing is sent to a model until you type in a tab.

## What it is for

| When | What is lost | What crestore does |
|---|---|---|
| Windows restarts for an update, or you reboot | Every terminal, and every Claude Code session in them | `crestore` reopens them, one Windows Terminal tab or VS Code terminal each |
| A crash: the machine, Windows Terminal, or VS Code's terminal host | The same | The same. [bring-back.mjs](#bring-backmjs) also recovers sessions that died with a VS Code terminal |
| A planned restart | Whatever the sessions did since their last handoff | `crestore -Prepare` first has every open session write an up-to-date handoff, then restarts if you ask |
| An account switch: a usage limit makes you change login | The prompt cache: it belongs to one organization, so a resume there sends the whole conversation again at the cache-write price | `crestore -From auto -To <label>` plans each closed session for the other login, and brings the large ones back from a handoff pack worded for it |

Resuming a closed session sends its whole conversation again, uncached. For a session of several hundred thousand tokens
a fresh session that reads a handoff pack of at most 14k tokens is far cheaper. `-From auto` asks
[acct-sync](https://github.com/gjovanov/acct-sync) which way fits each session. Without acct-sync crestore resumes every
session whole.

## Install

1. Put the files in `%USERPROFILE%\.claude\session-restore\`. The VS Code extension and `bring-back.mjs` look for
   crestore there.

   ```powershell
   git clone https://github.com/gjovanov/crestore "$env:USERPROFILE\.claude\session-restore"
   ```

   `git pull` in that folder updates it. What crestore writes there while it runs (`registry/`, `wake/`,
   `vscode-pending/`, logs) is ignored by git.

2. Add the `crestore` command to your PowerShell 7 profile (`notepad $PROFILE`):

   ```powershell
   function crestore { & "$env:USERPROFILE\.claude\session-restore\Restore-ClaudeSessions.ps1" @args }
   ```

3. Register the hook in your Claude Code user settings (`%USERPROFILE%\.claude\settings.json`). Merge these two entries
   into the `hooks` you have. Write the path with `/`: Claude Code can run hooks through Git Bash.

   ```json
   {
     "hooks": {
       "SessionStart": [
         { "matcher": "startup|resume|clear|fork",
           "hooks": [{ "type": "command", "command": "pwsh -NoProfile -NoLogo -File C:/Users/<you>/.claude/session-restore/hook.ps1", "timeout": 30, "async": true }] }
       ],
       "SessionEnd": [
         { "hooks": [{ "type": "command", "command": "pwsh -NoProfile -NoLogo -File C:/Users/<you>/.claude/session-restore/hook.ps1", "timeout": 15 }] }
       ]
     }
   }
   ```

   The hook writes one file per session to `registry/`: its id, folder, transcript, the claude process and its command
   line. A session whose SessionEnd hook runs (`/exit`, `/clear` and the like) is marked ended and is not offered. A
   `claude -p` run and a subagent are not recorded. The hook never fails a session: an error goes to `hook.log`, and it
   always exits 0.

4. Sessions that were already open when you installed the hook have no registry entry. For them, run `crestore -Scan`
   once: it also offers sessions found in recent transcripts.

5. For the VS Code target, nothing to install by hand. The first `crestore -Target vscode` copies `vscode-ext/` to
   `%USERPROFILE%\.vscode\extensions\gjovanov.claude-session-restore-0.1.0\`, and every later run keeps that copy in
   sync. VS Code loads extensions when it starts: if it was already running at that first run, restart it once.

Optional: `crestore -InstallStartup` adds a Scheduled Task that opens the picker 45 seconds after you log on.
`crestore -UninstallStartup` removes it.

## Requirements

- **Windows 10 or 11**, with **Windows Terminal** for the default target. Without `wt.exe` each session opens in a
  PowerShell window of its own.
- **PowerShell 7** (`pwsh`). The tabs run in it as well.
- **Claude Code 2.1.322 or newer.** crestore reads its hook events and a few transcript fields. Neither is a public
  interface, so a later release may change what crestore can read.
- **Node.js**, for [acct-sync](https://github.com/gjovanov/acct-sync) (`-From handoff|auto`), `bring-back.mjs` and the
  extension's test. Without Node crestore still resumes.
- **VS Code 1.75 or newer**, for `-Target vscode`.

## Commands

| Command | What it does |
|---|---|
| `crestore` | The picker: every closed session of the last 72 hours, across all folders. |
| `crestore <folder>[,<folder>...]` | Only sessions whose folder matches one of these (a part of the path, or the full path). |
| `-List` | Show the candidates, start nothing. |
| `-All` | No picker: bring back every candidate. |
| `-DryRun` | Print the command each tab would run, start nothing. |
| `-From resume\|handoff\|auto` | How each session comes back: whole (`resume`, the default), from a handoff pack (`handoff`), or whichever acct-sync advises (`auto`). |
| `-HandoffOnly` | `-From handoff`, and a session that gets no pack stays closed instead of coming back whole. Its resume line is printed. |
| `-To <label>` | With `-From`: plan for the acct-sync login with that label, not the one in use. For an account switch. |
| `-Target wt\|vscode` | Windows Terminal tabs (the default), or VS Code terminals, one window per folder. |
| `-Today` | Sessions that took a turn since midnight, in place of the 72-hour window. |
| `-MaxAgeHours <n>` | The window, in hours since each session's last turn (72). |
| `-Effort <level>` | The effort every restored session starts at: `inherit` (the default: what each was started with, and no `--effort` for one started without it), `low`, `medium`, `high`, `xhigh`, `max`, or `none` (no `--effort`). A higher effort spends more tokens per turn. |
| `-Scan` | Also offer sessions found in recent transcripts that have no registry entry. |
| `-Prepare [-DryRun] [-IncludeCold] [-Reboot]` | Before a planned restart: have every open session write an up-to-date handoff, and wait for the answers. See [Before a planned restart](#before-a-planned-restart). |
| `-AsIfRestarted` | What a restart would offer now: every open session counts as closed. Always a dry run. |
| `-HandoffCommand <name>` | The handoff command crestore names where it tells you to write a handoff by hand. Default: handoff-guard's `command` setting, else `hub-handoff`. |
| `-Prune` | Mark every open registry entry as ended, and remove handoff-guard records older than a week. |
| `-Window <name>` | The Windows Terminal window the tabs open in (`claude-restore`). |

One example each:

```powershell
crestore -From resume                  # every session comes back whole, under its own id
crestore -From handoff                 # every session from a pack: a fresh session that reads it on your first message
crestore -From auto                    # per session, whichever acct-sync advises
crestore -Target vscode                # into VS Code terminals instead of Windows Terminal tabs
crestore -Target wt                    # into Windows Terminal tabs (the default)
crestore -Today                        # only sessions used today
crestore api,web -HandoffOnly -All     # every session of two folders from a pack, none whole, no picker
crestore -Prepare -DryRun              # where each open session's handoff stands; asks nothing
crestore -Prepare -IncludeCold         # every open session writes a handoff, cold caches included
crestore -Prepare -Reboot              # the same, then asks, and restarts Windows in 60 seconds
crestore -AsIfRestarted -List          # what a restart would bring back, while everything still runs
crestore -From auto -To work           # plan for the login labelled work in acct-sync, then switch to it
```

In the picker, Enter brings back all of them, except one that `-Scan` found and marks `[!]` (its transcript changed in
the last 5 minutes, so it may still be running). `1,3-5` picks some. With a plan from acct-sync, a letter after a number
overrides its way back: `2h,4-6r` brings 2 back from a handoff and 4 to 6 whole, and `h` or `r` alone does that for
all. `q` brings back none.

Three settings change the defaults: `CRESTORE_TARGET`, `CRESTORE_FROM` and `CRESTORE_EFFORT` (see [Settings](#settings)).

## How a session comes back

| Way | What the tab runs | What it sends on your first message |
|---|---|---|
| Whole | `claude --resume <id>` with the session's launch flags | The whole conversation, under the same session id |
| From a pack | `Start-HandoffSession.ps1 <id>`: a fresh `claude` with the session's name and one line in its system prompt that points at the pack | The pack (at most 14k tokens by default) instead of the conversation. A new session id; the old conversation stays on disk and `claude --resume <id>` still opens it. |
| From its own handoff | The same, pointing at the newest handoff the session wrote itself | That handoff. Only for a session that saved no transcript ([below](#the-no-transcript-trap)). |

The launch flags it replays are `--dangerously-skip-permissions`, `--model`, `--permission-mode` and `--add-dir`, so a
session comes back in the permission mode it ran in. `--effort` comes from `-Effort`: by default the session's own level,
and none for a session started without one. acct-sync writes the packs, with no model call, under
`<config dir>/handoffs/<project>/acct/`. The line that points at a pack holds only for the conversation the process starts
with: after a `/clear` in that tab it is spent.

The list says how each session would come back, and what the first turns cost each way, at API prices. Once a session
started from a handoff is open or has taken a turn, crestore stops offering the older one, unless the older one was
used again after that.

## Before a planned restart

`crestore -Prepare` asks every open session for an up-to-date handoff before you restart. It needs
[handoff-guard](https://github.com/gjovanov/handoff-guard) in those sessions. crestore writes a request to
`<config dir>/handoff-guard/request.json`. Each session's guard looks every 10 seconds, writes a handoff if its own is
stale (one turn, with its handoff command), and answers in its record. crestore waits up to 10 minutes
(`-PrepareMinutes`) and lists each answer:

| Answer | Meaning |
|---|---|
| `written` | It wrote a handoff now. The path follows. |
| `current` | Its handoff was up to date already. |
| `skipped` | Its prompt cache is cold, so a handoff would re-read the whole conversation at the full price (`-IncludeCold` asks anyway), or it is a worker of an orchestrator, which brings it back itself. |
| `NO ANSWER` | No handoff-guard in that session, or it did not answer in time. Run the handoff command there by hand. |
| `FAILED` | The reason follows. |

`-DryRun` asks nothing and shows where each session's handoff stands. `-Reboot` then asks before it restarts Windows
in 60 seconds; `shutdown /a` cancels. Nothing restarts without a yes.

After the restart, `crestore -From auto` brings each session back from that handoff or from its conversation.

## The no-transcript trap

Claude Code (2.1.322) saves no transcript for a `claude` whose environment has `CLAUDE_CODE_CHILD_SESSION`, and a Claude
Code session sets that variable for every command it runs. So a `claude` started from a terminal that a session opened,
or from a VS Code window that a session started with `code`, inherits it and saves nothing. `/resume` cannot find such
a session, and neither can acct-sync.

To keep VS Code's terminals clear of it, add this to your VS Code user settings (`settings.json`). A `null` removes the
variable from every terminal VS Code opens:

```json
"terminal.integrated.env.windows": {
  "CLAUDE_CODE_CHILD_SESSION": null
}
```

`CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1` in a session's environment makes Claude Code save the transcript anyway.

crestore removes that variable, and the other markers of a parent session (`CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`,
`CLAUDE_PID` and the like), from its own environment before it starts a tab or a VS Code window. The extension removes
them again from each terminal it opens, and the handoff launcher from the claude it starts. So a session crestore
brings back saves its transcript even when crestore runs from inside a Claude Code session.

A session that saved no transcript cannot be resumed and cannot be packed. crestore brings it back from its own newest
handoff, the file its handoff-guard record names (`<config dir>/handoff-guard/live/<id>.json`), whatever `-From` says.
The list says when work came after that handoff. One with neither a transcript nor a handoff is listed as one that
cannot be brought back; while it is still open, a handoff written in it is what can save it. A worker session
(handoff-guard records one as a worker when its environment sets `HUB_WORKER`) is left to the orchestrator that runs
it, and the list counts it as a hub worker.

## With acct-sync, handoff-guard and Cache Keeper

Each is optional, and crestore works without them.

- **[acct-sync](https://github.com/gjovanov/acct-sync)** plans and writes the packs. With `-From auto` or `-From handoff`
  crestore runs `acct-sync.mjs wake --json` for the plan and `wake --mode handoff --write --json` for the packs, and
  starts each pack's session with the line acct-sync prints. crestore looks for it where its README installs it,
  `<config dir>/tools/account-sync/acct-sync.mjs`; `CRESTORE_ACCT_SYNC` names another path.
- **[handoff-guard](https://github.com/gjovanov/handoff-guard)** keeps each session's handoff current and answers
  `-Prepare`. Its record of each session names the newest handoff, which is how a session without a transcript comes
  back. crestore reads its `command` setting for the lines that tell you to write a handoff by hand.
- **[Cache Keeper](https://github.com/gjovanov/cache-keeper)** keeps a snapshot of each session. crestore reads only its
  name and context size, for sessions without a transcript.

## bring-back.mjs

A session in a VS Code terminal dies with VS Code's terminal host. `bring-back.mjs` resumes such sessions inside Claude
Code's background daemon under the same id (`claude --bg --resume`), and opens a `claude attach` viewer in the VS Code
window that owns the folder. From then on the terminal is only a viewer, and VS Code can die without touching the session.

```powershell
node bring-back.mjs list   [--since <iso>] [--until <iso>]   # who died in that window (the last 6 hours)
node bring-back.mjs resume [--dry] [--min-free-gb 7] <id[=name]>...
node bring-back.mjs attach <job> <windowFolder> <tabName>    # a viewer for a job already running
node bring-back.mjs reattach <folder>                        # a fresh viewer tab for every job under <folder>
```

`list` offers every session that died in the window. It leaves out a session that is still running, saved no
transcript, ended cleanly or handed off, and the sessions of Claude Code's VS Code extension. Two settings narrow it, each
a regular expression. `CRESTORE_LIST_MATCH` keeps only the sessions whose recorded command line matches it.
`CRESTORE_SKIP_NAME` keeps the sessions whose name matches it out of `list` and `reattach`: the workers of an orchestrator
that brings them back itself, say.

`resume` refuses a session that is still running, one that saved no transcript, and one that handed off. It skips a
session while free memory is below `--min-free-gb` (7 GB by default). It starts each session with its own launch flags,
the ones crestore replays: `--dangerously-skip-permissions`, `--model`, `--permission-mode` and `--add-dir`. `--effort`
follows `CRESTORE_EFFORT`, as in crestore: by default the session's own level, and none for a session started without
one. `--dry` prints each command and starts nothing.

So a session comes back in the permission mode it ran in. One that ran in the default mode still asks before a tool call
that needs your approval. In the background it waits for your answer: `claude agents` shows it as waiting, and you
answer in its viewer (`claude attach <job>`).

## Settings

All from the environment.

| Variable | Default | Meaning |
|---|---|---|
| `CRESTORE_TARGET` | `wt` | The default `-Target`. |
| `CRESTORE_FROM` | `resume` | The default `-From`. |
| `CRESTORE_EFFORT` | `inherit` | The default `-Effort`, and the effort `bring-back.mjs resume` passes. The author sets `max`. A higher effort spends more tokens per turn. A value that is none of the seven gets a note, and `inherit`. |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code's config folder, where crestore finds `projects/` (`-Scan`), `settings.json`, `handoff-guard/`, `cache-keeper/` and acct-sync. |
| `CRESTORE_ACCT_SYNC` | `<config dir>/tools/account-sync/acct-sync.mjs` | acct-sync's script. |
| `CRESTORE_GUARD_DIR` | `<config dir>/handoff-guard` | handoff-guard's folder. |
| `CRESTORE_CACHE_KEEPER_DIR` | `<config dir>/cache-keeper` | Cache Keeper's folder. Only read. |
| `CRESTORE_ROOT` | `%USERPROFILE%\.claude\session-restore` | Where the hook and the scripts keep `registry/` and `wake/`. The extension and `bring-back.mjs` always use the default. |
| `CRESTORE_LIST_MATCH` | none | `bring-back.mjs list`: only the sessions whose recorded command line matches this regular expression. The author sets `--dangerously-skip-permissions`. |
| `CRESTORE_SKIP_NAME` | none | `bring-back.mjs`: sessions whose name matches this regular expression stay out of `list` and `reattach`. |

The handoff command comes from `-HandoffCommand`, else handoff-guard's `command` setting
(`pluginConfigs."handoff-guard@<marketplace>".options.command` in `settings.json`), else `hub-handoff`, handoff-guard's
default. That default is the author's own skill and is not published, so set yours in handoff-guard. crestore only names
the command; it never runs it.

The tests use a few more: `CRESTORE_TEST_DIR` (their work folder), `CRESTORE_PREPARE_ID` and `CRESTORE_PREPARE_GRACE_S`
(a fixed request id and a shorter wait), and `CRESTORE_REBOOT_CMD` with `CRESTORE_REBOOT_ANSWER` (a stand-in restart
command and its answer). The answer is read only together with a stand-in command: a real restart is always asked.

## Files

| Path | What it is |
|---|---|
| `Restore-ClaudeSessions.ps1` | crestore. |
| `hook.ps1` | The SessionStart and SessionEnd hook. |
| `Start-HandoffSession.ps1` | What a handoff tab runs: a fresh `claude` from the session's wake file. |
| `vscode-ext/` | The VS Code extension for `-Target vscode`. It opens a terminal per queued session in the window whose folder holds it, and claims each queue file by deleting it, so with several windows open each session starts once. |
| `bring-back.mjs` | Recovers sessions that died with a VS Code terminal. |
| `close-terminal.ps1` | Closes an old viewer tab with exit code 0, for `bring-back.mjs reattach`. |
| `tests/` | The tests. |

Written beside them while it runs, and ignored by git:

| Path | What it holds | Kept |
|---|---|---|
| `registry/<id>.json` | One session: id, folder, transcript, start, claude's process id and command line, the session it carries on | 14 days |
| `wake/<id>.json` | A handoff tab's arguments: the pack, the name, the line for the system prompt | 14 days |
| `vscode-pending/<id>.json` | A session queued for a VS Code window | 15 minutes |
| `hook.log`, `vscode-ext.log` | Errors and what the extension did | |

crestore reads transcripts and Cache Keeper's records, and never changes one. In handoff-guard's folder it writes
`request.json` (`-Prepare`) and removes the records of sessions gone for a week (`-Prepare`, `-Prune`). Nothing leaves
the machine.

## Limits

- **Windows only.** Windows Terminal, `pwsh` tabs, process lookups through CIM, and a Scheduled Task.
- **The install folder is fixed** for the extension and `bring-back.mjs`: `%USERPROFILE%\.claude\session-restore`.
- **Claude Code's hook events and transcript format are not public interfaces.** crestore was written against 2.1.322.
- **A session counts as running** while a `claude` or `node` process holds the process id the hook recorded for it.
  After a restart another `node` process can get that id, and the session is then not offered. `-AsIfRestarted -List`
  still lists it, and `claude --resume <id>` brings it back by hand.
- **Only some launch flags are replayed** (above), by crestore and by `bring-back.mjs`. A session started with other
  flags comes back without them.
- **`-Prepare` reaches only sessions with handoff-guard.** A session started before the plugin was installed does not
  answer.
- **Costs are API prices.** How a subscription counts cache reads and writes toward its limits is not documented.

## Tests

```powershell
pwsh -NoProfile -File tests/run-all.ps1
```

runs 16 lanes: PowerShell's parser on the four scripts, then the hook, the handoff launcher, the pointer line,
`bring-back.mjs`, the launch flags a session comes back with (the same from crestore and `bring-back.mjs`), the VS Code
extension, which sessions are offered once one was carried on, the window and folder filters, sessions without a
transcript, `-Prepare` twice, and the real restore path four times (`-From auto`, `handoff`, `-HandoffOnly`, and as
without acct-sync).

Nothing real is started or read. Windows Terminal and claude are stand-ins that only record how they were started, and
every registry, transcript and record a test reads is one it made, in its work folder (`%TEMP%\crestore-tests`, or
`CRESTORE_TEST_DIR`). Where acct-sync is installed, the restore and pointer tests run it on their synthetic sessions;
without it the pointer test is skipped. With long paths off (`LongPathsEnabled` 0), keep the work folder's path short.

## Background

crestore was built for [Roomler](https://github.com/gjovanov/roomler-ai)'s development, where many Claude Code sessions
run at once. Its design history and field log are in Roomler's spec
[FR-8](https://github.com/gjovanov/roomler-ai/blob/master/docs/fr/FR-8-claude-session-restore.md). That spec describes
the author's own setup, so where its defaults differ from the ones above, they are settings here.

## License

MIT. See [LICENSE](LICENSE).
