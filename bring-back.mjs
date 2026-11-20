// bring-back: recover Claude sessions lost with a VS Code terminal.
//
// A session that lived in a VS Code terminal dies with the pty host. This resumes it inside the Claude
// daemon instead, under the same session id, then opens a `claude attach` viewer in the VS Code window
// that owns its folder. From then on the terminal is only a viewer: VS Code can die without touching the
// session, and the daemon's Remote Control bridge lists it in Claude Desktop and on claude.ai.
//
//   node bring-back.mjs list   [--since <iso>] [--until <iso>]      who died in that window
//   node bring-back.mjs resume [--dry] [--min-free-gb 7] <id[=name]>...
//   node bring-back.mjs attach <job> <windowFolder> <tabName>       viewer only, for a job already running
//   node bring-back.mjs reattach <folder>                           fresh viewer tab for every job under <folder>
//
// reattach rebuilds the tabs after a VS Code restart, and replaces any older viewer tab. A viewer holds no
// state, so closing one costs nothing. New tabs take the terminal panel's focus, so run it knowingly.
//
// resume starts each session with its own launch flags, the ones crestore replays (below): a session that ran in the
// default permission mode comes back in it. --dry prints each command and starts nothing. list offers every session
// that died in the window; CRESTORE_LIST_MATCH narrows it.
//
// Never resume by hand with a second writer: a session id that is still live is refused here.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const BASE = path.join(os.homedir(), '.claude', 'session-restore');
const REGISTRY = path.join(BASE, 'registry');
const PENDING = path.join(BASE, 'vscode-pending');
const STAGGER_MS = 6000;
const CLAIM_WAIT_MS = 6000;
// Sessions whose name matches CRESTORE_SKIP_NAME, a regular expression (unset: none), stay out of list and reattach:
// the workers of an orchestrator, say, which brings its own workers back.
const SKIP_NAME = process.env.CRESTORE_SKIP_NAME ? new RegExp(process.env.CRESTORE_SKIP_NAME) : null;
const skipName = (name) => Boolean(SKIP_NAME && name && SKIP_NAME.test(name));
// list offers only sessions whose recorded claude command line matches CRESTORE_LIST_MATCH, a regular expression
// (unset: every session). --dangerously-skip-permissions, say, offers only the sessions that ran with that flag.
const LIST_MATCH = process.env.CRESTORE_LIST_MATCH ? new RegExp(process.env.CRESTORE_LIST_MATCH) : null;
// The name a claude command line gives its session: -n <name> or --name <name>.
const nameIn = (cmd) => { const m = /(?:^|\s)(?:-n|--name)(?:\s+|=)("[^"]*"|\S+)/.exec(cmd || ''); return m ? m[1].replace(/^"|"$/g, '') : ''; };

// The launch flags a session is resumed with: its own, from the claude command line the hook recorded. The same set,
// read the same way, as in Restore-ClaudeSessions.ps1 (Get-ReplayFlags, Get-LaunchFlags): argv[0] skipped, a "quoted"
// argument is one token, `--flag value` or `--flag=value`, and names match without regard to case, as in PowerShell.
// No other flag is added, so a session that ran in the default permission mode comes back in it.
const REPLAYED = new Map([['--dangerously-skip-permissions', 0], ['--model', 1], ['--permission-mode', 1], ['--add-dir', 1], ['--effort', 1]]);
function replayFlags(cmdline) {
  const tokens = [...(cmdline || '').matchAll(/"([^"]*)"|(\S+)/g)].map((m) => m[1] ?? m[2]);
  const flags = [];
  for (let i = 1; i < tokens.length; i++) {
    const t = tokens[i];
    const eq = /^(--[a-z-]+)=(.*)$/i.exec(t);
    if (eq) {
      if (REPLAYED.get(eq[1].toLowerCase()) === 1) flags.push(eq[1], eq[2]);
      continue;
    }
    const arity = REPLAYED.get(t.toLowerCase());
    if (arity === undefined) continue;
    flags.push(t);
    if (arity === 1 && i + 1 < tokens.length) flags.push(tokens[++i]);
  }
  return flags;
}
// --effort follows crestore's -Effort default: CRESTORE_EFFORT, else inherit. inherit replays the session's own
// --effort, and passes none when it recorded none; low, medium, high, xhigh or max gives every session that level;
// none passes no --effort. (crestore also asks `claude --help` whether --effort exists: every claude with --bg has it.)
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max', 'inherit', 'none'];
function effortSetting() {
  const v = (process.env.CRESTORE_EFFORT || 'inherit').toLowerCase();
  if (EFFORTS.includes(v)) return v;
  console.log(`Note: CRESTORE_EFFORT='${process.env.CRESTORE_EFFORT}' is not one of ${EFFORTS.join(', ')}: using inherit.`);
  return 'inherit';
}
function launchFlags(cmdline, effort) {
  const replayed = replayFlags(cmdline);
  const flags = [];
  let own = null;
  for (let i = 0; i < replayed.length; i++) {
    // A replayed --effort pair is left out: the effort setting decides, so the flag never comes twice.
    if (replayed[i].toLowerCase() === '--effort') { if (own === null && i + 1 < replayed.length) own = replayed[i + 1]; i++; continue; }
    flags.push(replayed[i]);
  }
  const level = effort === 'none' ? null : effort === 'inherit' ? own : effort;
  if (level) flags.push('--effort', level);
  return flags;
}
// A command as it would be typed, for --dry.
const shown = (args) => args.map((a) => (a === '' || /\s/.test(a) ? `"${a}"` : a)).join(' ');

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const gb = (n) => (n / 2 ** 30).toFixed(1);
const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, ''));

// Run from a Claude Code session (its Bash tool), this process carries that session's markers, and a claude that
// inherits CLAUDE_CODE_CHILD_SESSION saves no transcript and no prompt history (2.1.322: "nested_marker"); a daemon
// this call starts would pass them to every session it runs. CLAUDE_CONFIG_DIR and the variables of settings.json's
// own env stay. The same list is in Restore-ClaudeSessions.ps1, Start-HandoffSession.ps1 and vscode-ext/extension.js.
const SESSION_MARKERS = new Set(['CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_PID',
  'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_EXECPATH', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN',
  'CLAUDE_CODE_SSE_PORT', 'CLAUDE_EFFORT']);
const cleanEnv = () => Object.fromEntries(Object.entries(process.env).filter(([k]) => !SESSION_MARKERS.has(k.toUpperCase()) && !/^HUB_/i.test(k)));

function claude(args, opts = {}) {
  return spawnSync('claude', args, { encoding: 'utf8', timeout: 60000, windowsHide: true, env: cleanEnv(), ...opts });
}

function liveSessions() {
  const r = claude(['agents', '--json']);
  if (r.status !== 0) throw new Error('claude agents failed: ' + (r.stderr || r.error));
  return JSON.parse(r.stdout || '[]');
}

function registryEntries() {
  return fs.readdirSync(REGISTRY).filter((f) => f.endsWith('.json')).flatMap((f) => {
    try { return [readJson(path.join(REGISTRY, f))]; } catch { return []; }
  });
}

// Last title and turn state from a transcript. A session that handed off (continued-in) is not resumable.
function inspect(transcript) {
  const out = { title: '', handedOff: false, state: '?', lastAt: 0 };
  let last = null;
  for (const line of fs.readFileSync(transcript, 'utf8').split('\n')) {
    if (!line) continue;
    let j;
    try { j = JSON.parse(line); } catch { continue; }
    if (j.type === 'custom-title' && j.customTitle) out.title = j.customTitle;
    else if (j.type === 'ai-title' && j.aiTitle && !out.title) out.title = j.aiTitle;
    else if (j.type === 'agent-name' && j.agentName) out.title = j.agentName;
    else if (j.type === 'continued-in') out.handedOff = true;
    const t = Date.parse(j.timestamp || '');
    if (t && (j.type === 'assistant' || j.type === 'user')) { out.lastAt = t; last = j; }
  }
  const c = last?.message?.content;
  if (last?.type === 'assistant') {
    out.state = last.message?.stop_reason === 'end_turn' ? 'finished' : 'MID-WORK';
  } else if (last?.type === 'user') {
    out.state = Array.isArray(c) && c.some((b) => b.type === 'tool_result') ? 'MID-WORK' : 'unanswered';
  }
  return out;
}

function queueViewer(id, cwd, name, command) {
  const now = new Date();
  const entry = {
    session_id: id, cwd, name, command,
    created_at: now.toISOString(), expires_at: new Date(now.getTime() + 15 * 60e3).toISOString(),
  };
  const file = path.join(PENDING, `${id}.json`);
  const tmp = path.join(PENDING, `.${id}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(entry));
  fs.renameSync(tmp, file);
  const deadline = Date.now() + CLAIM_WAIT_MS;
  while (Date.now() < deadline) {
    if (!fs.existsSync(file)) return true;
    sleep(250);
  }
  return false;
}

// Every `claude attach` running in a pwsh terminal, with the shell that owns its tab.
function viewers() {
  // Plain lines, not ConvertTo-Json: PowerShell 5.1 leaves control characters from command lines unescaped.
  const script = "Get-CimInstance Win32_Process -Filter 'Name=''claude.exe'' OR Name=''pwsh.exe''' | "
    + "ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.ProcessId,$_.ParentProcessId,$_.Name,($_.CommandLine -replace '[\\r\\n|]',' ') }";
  const r = spawnSync('powershell.exe', ['-NoProfile', '-Command', script],
    { encoding: 'utf8', timeout: 60000, maxBuffer: 2 ** 26, windowsHide: true });
  const all = r.stdout.split(/\r?\n/).filter(Boolean).map((line) => {
    const [pid, ppid, name, ...cmd] = line.split('|');
    return { ProcessId: Number(pid), ParentProcessId: Number(ppid), Name: name, CommandLine: cmd.join('|') };
  });
  const byId = new Map(all.map((p) => [p.ProcessId, p]));
  return all.flatMap((p) => {
    const job = p.Name === 'claude.exe' && p.CommandLine?.match(/\sattach\s+([0-9a-f]{8})\b/)?.[1];
    const shell = job && byId.get(p.ParentProcessId);
    return shell?.Name === 'pwsh.exe' ? [{ job, shellPid: shell.ProcessId }] : [];
  });
}

function reattach(folder) {
  if (!folder) throw new Error('reattach needs the folder of an open VS Code window');
  const root = folder.replace(/[\\/]+$/, '').toLowerCase();
  const under = (p) => { const c = (p || '').toLowerCase(); return c === root || c.startsWith(root + path.sep); };
  // Sessions named by CRESTORE_SKIP_NAME stay out (see above).
  const jobs = liveSessions().filter((s) => s.kind === 'background' && under(s.cwd) && !skipName(s.name));
  const entries = registryEntries();
  const open = viewers();
  let reopened = 0, closed = 0;
  for (const s of jobs) {
    const e = entries.find((x) => x.session_id === s.sessionId);
    const title = /^[0-9a-f]{8}$/.test(s.name || '') && e && e.transcript_path && fs.existsSync(e.transcript_path) ? inspect(e.transcript_path).title : s.name;
    if (!queueViewer(`attach-${s.id}`, s.cwd, (title || s.id).slice(0, 30), `claude attach ${s.id}`)) {
      console.log(`${s.id}: no VS Code window claimed it, old tab kept`);
      continue;
    }
    reopened++;
    for (const v of open.filter((x) => x.job === s.id)) {
      spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        path.join(BASE, 'close-terminal.ps1'), '-ShellPid', String(v.shellPid)], { windowsHide: true });
      closed++;
    }
    sleep(1500);
  }
  console.log(`reopened ${reopened} of ${jobs.length} jobs, closed ${closed} old tabs`);
}

function list(args) {
  const opt = (k) => { const i = args.indexOf(k); return i >= 0 ? Date.parse(args[i + 1]) : undefined; };
  const until = opt('--until') ?? Date.now();
  const since = opt('--since') ?? until - 6 * 3600e3;
  const live = new Set(liveSessions().map((s) => s.sessionId));
  for (const e of registryEntries()) {
    const cmd = e.claude_cmdline || '';
    if ((LIST_MATCH && !LIST_MATCH.test(cmd)) || skipName(nameIn(cmd)) || /\.vscode.extensions/.test(cmd)) continue;
    if (!e.transcript_path || !fs.existsSync(e.transcript_path) || live.has(e.session_id)) continue;
    if (e.end_reason && e.end_reason !== 'other') continue;
    const mtime = fs.statSync(e.transcript_path).mtimeMs;
    if (mtime < since || mtime > until) continue;
    const t = inspect(e.transcript_path);
    if (t.handedOff) continue;
    console.log(e.session_id.slice(0, 8), t.state.padEnd(10), new Date(t.lastAt).toISOString().slice(5, 16), path.basename(e.cwd).padEnd(14), t.title.slice(0, 60));
  }
}

function resume(args) {
  const dry = args.includes('--dry');
  const floorIdx = args.indexOf('--min-free-gb');
  const floor = (floorIdx >= 0 ? Number(args[floorIdx + 1]) : 7) * 2 ** 30;
  const wanted = args.filter((a, i) => /^[0-9a-f]{8}/.test(a) && (floorIdx < 0 || i !== floorIdx + 1));
  const effort = effortSetting();
  const entries = registryEntries();
  const live = liveSessions();
  const done = [], skipped = [];

  for (const spec of wanted) {
    const [prefix, forcedName] = spec.split('=');
    const e = entries.find((x) => x.session_id.startsWith(prefix));
    if (!e) { skipped.push(`${prefix}: not in the registry`); continue; }
    if (live.some((s) => s.sessionId === e.session_id)) { skipped.push(`${prefix}: already running, refusing a second writer`); continue; }
    // A claude that inherited CLAUDE_CODE_CHILD_SESSION saved no transcript: nothing to resume (crestore brings such
    // a session back from its own handoff).
    if (!e.transcript_path || !fs.existsSync(e.transcript_path)) { skipped.push(`${prefix}: saved no transcript, so it cannot be resumed (crestore brings it back from its handoff, if it has one)`); continue; }
    const t = inspect(e.transcript_path);
    if (t.handedOff) { skipped.push(`${prefix}: handed off to another session`); continue; }
    if (os.freemem() < floor) { skipped.push(`${prefix}: stopped at the RAM floor, ${gb(os.freemem())} GB free`); continue; }

    const name = forcedName || t.title.slice(0, 40) || prefix;
    // Its own launch flags (above): its permission mode and its effort are not raised here.
    const flags = ['--bg', '--resume', e.session_id, '-n', name, ...launchFlags(e.claude_cmdline, effort)];
    if (dry) { console.log(`would resume ${prefix} ${t.state.padEnd(10)} "${name}" in ${e.cwd}: claude ${shown(flags)}`); continue; }

    const r = claude(flags, { cwd: e.cwd });
    const job = (r.stdout || '').match(/backgrounded\s+\S\s+([0-9a-f]{8})/)?.[1];
    // A different job id means the CLI started a copy instead of continuing this session.
    if (r.status !== 0 || job !== e.session_id.slice(0, 8)) {
      skipped.push(`${prefix}: resume did not land cleanly: ${(r.stdout + r.stderr).trim().slice(0, 120)}`);
      continue;
    }
    const claimed = queueViewer(`attach-${job}`, e.cwd, name.slice(0, 30), `claude attach ${job}`);
    done.push(`${job} ${t.state.padEnd(10)} ${claimed ? 'viewer open' : 'VIEWER NOT CLAIMED'}  ${path.basename(e.cwd)}  ${name}`);
    console.log(done[done.length - 1]);
    sleep(STAGGER_MS);
  }
  console.log(`\nresumed ${done.length}, skipped ${skipped.length}, free RAM ${gb(os.freemem())} GB`);
  skipped.forEach((s) => console.log('  skipped ' + s));
}

const [mode, ...rest] = process.argv.slice(2);
if (mode === 'list') list(rest);
else if (mode === 'resume') resume(rest);
else if (mode === 'reattach') reattach(rest[0]);
else if (mode === 'attach') {
  const [job, folder, tab] = rest;
  console.log(queueViewer(`attach-${job}`, folder, tab || job, `claude attach ${job}`) ? 'viewer open' : 'NOT CLAIMED: no window owns that folder');
} else console.log('usage: bring-back.mjs list | resume [--dry] [--min-free-gb N] <id[=name]>... | attach <job> <folder> <tab>');
