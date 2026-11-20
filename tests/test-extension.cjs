// The VS Code extension (vscode-ext/extension.js) with a stand-in `vscode` module: one pending file in a scratch
// home, a window whose folder holds it, and what the extension asks createTerminal for. VS Code itself deletes a
// variable whose value in a terminal's env is null; this checks that the extension asks for that.
//
//   node tests/test-extension.cjs        (run-all.ps1 runs it through test-extension.ps1)
const Module = require('module');
const fs = require('fs');
const os = require('os');
const path = require('path');

let fail = 0;
const check = (what, ok, detail = '') => {
  if (ok) console.log(`ok    ${what}`);
  else { fail++; console.log(`FAIL  ${what}  ${detail}`); }
};

const home = fs.mkdtempSync(path.join(os.tmpdir(), 'crestore-ext-'));
process.env.USERPROFILE = home;
process.env.HOME = home;
// What a VS Code that a Claude Code session cold-started has in its environment.
const markers = { CLAUDECODE: '1', CLAUDE_CODE_CHILD_SESSION: '1', CLAUDE_CODE_SESSION_ID: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', CLAUDE_PID: '4242', HUB_CALL: 'test' };
Object.assign(process.env, markers, { CLAUDE_CRESTORE_TEST_KEEP: '1' });

const pending = path.join(home, '.claude', 'session-restore', 'vscode-pending');
const cwd = path.join(home, 'work dir');
fs.mkdirSync(pending, { recursive: true });
fs.mkdirSync(cwd);
const command = 'pwsh -NoLogo -NoProfile -File "C:\\x\\Start-HandoffSession.ps1" aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
fs.writeFileSync(path.join(pending, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.json'),
  JSON.stringify({ session_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', cwd, name: 'test', command, expires_at: new Date(Date.now() + 60_000).toISOString() }));

const made = [];
const vscode = {
  workspace: { workspaceFolders: [{ uri: { scheme: 'file', fsPath: cwd } }], onDidChangeWorkspaceFolders: () => ({ dispose() {} }) },
  window: {
    createTerminal(options) {
      const t = { options, sent: [] };
      made.push(t);
      return { show() {}, sendText(text) { t.sent.push(text); } };
    },
  },
  commands: { registerCommand: () => ({ dispose() {} }) },
};
const load = Module._load;
Module._load = function (request, ...rest) { return request === 'vscode' ? vscode : load.call(this, request, ...rest); };

const ext = require(path.join(__dirname, '..', 'vscode-ext', 'extension.js'));
const context = { subscriptions: [] };
ext.activate(context);

setTimeout(() => {
  try {
    check(`one terminal for the one pending session (${made.length})`, made.length === 1);
    const t = made[0] ?? { options: {}, sent: [] };
    const env = t.options.env ?? {};
    check("the terminal opens in the session's folder", t.options.cwd === cwd, String(t.options.cwd));
    check('the queued command is typed into it', t.sent.length === 1 && t.sent[0] === command, JSON.stringify(t.sent));
    const kept = Object.keys(markers).filter(k => env[k] !== null);
    check("every marker of the parent session is deleted for it (null in its env)", kept.length === 0, `not deleted: ${kept.join(', ')}`);
    check('any other CLAUDE* variable is left alone', !('CLAUDE_CRESTORE_TEST_KEEP' in env) && !('CLAUDE_CONFIG_DIR' in env), Object.keys(env).join(', '));
    check('it deletes, and sets nothing', Object.values(env).every(v => v === null), JSON.stringify(env));
    check('the pending file was claimed', fs.readdirSync(pending).length === 0);
  } finally {
    for (const d of context.subscriptions) { try { d.dispose(); } catch {} }
    fs.rmSync(home, { recursive: true, force: true });
    console.log(`failures: ${fail}`);
    process.exit(fail);
  }
}, 1500);
