// Claude Session Restore - consumes one-shot pending files written by
// Restore-ClaudeSessions.ps1 -Target vscode and opens an integrated terminal
// per session, cd'ed to the session's folder, running `claude --resume <id>`.
//
// Pending files live in ~/.claude/session-restore/vscode-pending/<session>.json:
//   { session_id, cwd, name, command, created_at, expires_at }
// A window only consumes entries whose cwd lies under one of its workspace
// folders. Consumption claims the file by deleting it first, so with several
// windows open each session spawns exactly once. Expired files are discarded.
// A watcher on the pending dir means the order doesn't matter: run crestore
// before or after opening VS Code, terminals appear either way.

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');

const BASE = path.join(os.homedir(), '.claude', 'session-restore');
const PENDING_DIR = path.join(BASE, 'vscode-pending');
const LOG = path.join(BASE, 'vscode-ext.log');

// A VS Code that a Claude Code session started (crestore run from a session cold-starts windows with `code`) passes
// that session's markers to every terminal it opens, and a claude that inherits CLAUDE_CODE_CHILD_SESSION saves no
// transcript and no prompt history (2.1.322: "nested_marker"). A null in a terminal's env deletes the variable for
// that terminal. CLAUDE_CONFIG_DIR and the variables of settings.json's own env stay. The same list is in
// Restore-ClaudeSessions.ps1, Start-HandoffSession.ps1 and bring-back.mjs.
const SESSION_MARKERS = ['CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_PID',
  'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_EXECPATH', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN',
  'CLAUDE_CODE_SSE_PORT', 'CLAUDE_EFFORT'];

function cleanEnv() {
  const env = {};
  for (const k of SESSION_MARKERS) env[k] = null;
  for (const k of Object.keys(process.env)) if (/^HUB_/i.test(k)) env[k] = null;
  return env;
}

function log(msg) {
  try { fs.appendFileSync(LOG, new Date().toISOString() + ' ' + msg + '\n'); } catch {}
}

function folderPaths() {
  return (vscode.workspace.workspaceFolders || [])
    .filter((f) => f.uri.scheme === 'file')
    .map((f) => f.uri.fsPath.replace(/[\\/]+$/, '').toLowerCase());
}

function matchesWorkspace(cwd) {
  const c = String(cwd).replace(/[\\/]+$/, '').toLowerCase();
  return folderPaths().some((f) => c === f || c.startsWith(f + path.sep));
}

let busy = false;
async function consumePending(reason) {
  if (busy) return;
  busy = true;
  try {
    let files;
    try {
      files = fs.readdirSync(PENDING_DIR).filter((f) => f.endsWith('.json'));
    } catch (e) {
      log('readdir failed: ' + e.message);
      return;
    }
    if (files.length > 0) {
      log('check (' + reason + '): ' + files.length + ' pending vs [' + folderPaths().join(', ') + ']');
    }
    for (const f of files) {
      const full = path.join(PENDING_DIR, f);
      let entry;
      try {
        entry = JSON.parse(fs.readFileSync(full, 'utf8').replace(/^\uFEFF/, ''));
      } catch (e) {
        log('unparseable pending ' + f + ': ' + e.message);
        continue;
      }
      if (!entry || !entry.cwd || !entry.command) { log('incomplete pending: ' + f); continue; }
      if (entry.expires_at && Date.parse(entry.expires_at) < Date.now()) {
        try { fs.unlinkSync(full); log('discarded expired: ' + f); } catch {}
        continue;
      }
      if (!matchesWorkspace(entry.cwd)) continue;
      try { fs.unlinkSync(full); } catch { continue; } // claim: exactly one window wins
      log('spawning (' + reason + '): "' + (entry.name || 'claude') + '" in ' + entry.cwd);
      try {
        // No name: VS Code only follows the title a running program sets on unnamed terminals,
        // and that title carries Claude's live working indicator. entry.name is for the log.
        const term = vscode.window.createTerminal({ cwd: entry.cwd, env: cleanEnv() });
        term.show(true);
        await new Promise((r) => setTimeout(r, 400)); // let the shell come up
        term.sendText(entry.command, true);
      } catch (e) {
        log('spawn failed: ' + e.message);
      }
    }
  } finally {
    busy = false;
  }
}

function activate(context) {
  try { fs.mkdirSync(PENDING_DIR, { recursive: true }); } catch {}
  log('activated in: ' + (folderPaths().join(', ') || '(no folder)'));
  consumePending('startup');

  let timer = null;
  let watcher = null;
  try {
    watcher = fs.watch(PENDING_DIR, () => {
      clearTimeout(timer);
      timer = setTimeout(() => consumePending('watch'), 500);
    });
  } catch (e) {
    log('watch failed: ' + e.message);
  }
  context.subscriptions.push(
    { dispose() { try { if (watcher) watcher.close(); } catch {} } },
    vscode.commands.registerCommand('claude-session-restore.check', () => consumePending('manual')),
    vscode.workspace.onDidChangeWorkspaceFolders(() => consumePending('folders-changed'))
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
