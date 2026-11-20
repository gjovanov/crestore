// A synthetic set of closed Claude Code sessions for test-restore.ps1: transcripts in the record shapes Claude Code
// 2.1.322 writes, crestore's registry, a handoff-guard record, a Cache Keeper record and a login. Nothing here comes
// from a real session: the ids are made at run time and every text is invented.
//
//   node synth-sessions.mjs <dir>        builds the set under <dir> (emptied first) and prints a JSON manifest
//
//   <dir>/home/.claude/                  the config folder (CLAUDE_CONFIG_DIR): projects/, handoffs/, handoff-guard/,
//                                        cache-keeper/ and .claude.json, the login, with a made-up organization id
//   <dir>/root/registry/                 crestore's registry (CRESTORE_ROOT), one entry per session, all closed
//   <dir>/stray/                         a transcript outside the projects folder, which acct-sync cannot find
//   <dir>/work/demo/                     the folder every session ran in
//
// The sessions:
//   big    480k of context, its cache long cold, with a handoff it wrote itself one turn before its end
//   small  90k of context: about what a fresh session holds, so little to save
//   stray  its transcript lies outside the projects folder: acct-sync has no plan for it
//   notx   saved no transcript (as a claude started from inside a Claude Code session does); its handoff-guard record
//          names a handoff it wrote, and Cache Keeper's record names it
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

const dir = process.argv[2]
if (!dir) { console.error('usage: node synth-sessions.mjs <dir>'); process.exit(2) }
fs.rmSync(dir, { recursive: true, force: true })
const config = path.join(dir, 'home', '.claude')
const root = path.join(dir, 'root')
const cwd = path.join(dir, 'work', 'demo')
const stray = path.join(dir, 'stray')
const projectDir = path.join(config, 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'))
for (const d of [config, path.join(root, 'registry'), cwd, stray, projectDir]) fs.mkdirSync(d, { recursive: true })
const fwd = p => p.replace(/\\/g, '/')
const write = (file, text) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text) }

const org = crypto.randomUUID()
write(path.join(config, '.claude.json'), JSON.stringify({ oauthAccount: { accountUuid: crypto.randomUUID(), organizationUuid: org, planDisplayName: 'Test plan' } }))

const now = Date.now(), hour = 3600e3
const sids = { big: crypto.randomUUID(), small: crypto.randomUUID(), stray: crypto.randomUUID(), notx: crypto.randomUUID() }

function records(sid, t0) {
  const base = { sessionId: sid, cwd, version: '2.1.322', gitBranch: 'main', userType: 'external', isSidechain: false }
  const at = s => new Date(t0 + s * 1000).toISOString()
  const usage = ctx => ({ input_tokens: 10, cache_creation_input_tokens: 2000, cache_read_input_tokens: Math.max(0, ctx - 2070), output_tokens: 60, cache_creation: { ephemeral_1h_input_tokens: 2000, ephemeral_5m_input_tokens: 0 } })
  let n = 0
  return {
    prompt: (s, text) => ({ ...base, type: 'user', uuid: `u${++n}`, parentUuid: null, timestamp: at(s), message: { role: 'user', content: text } }),
    reply: (s, content, { ctx = 30000, stop = 'end_turn' } = {}) => {
      const k = ++n
      return { ...base, type: 'assistant', uuid: `a${k}`, parentUuid: null, timestamp: at(s), requestId: `req_${k}`, message: { id: `msg_${k}`, type: 'message', role: 'assistant', model: 'claude-opus-5-5', stop_reason: stop, content, usage: usage(ctx) } }
    },
    text: t => ({ type: 'text', text: t }),
    tool: (id, name, input) => ({ type: 'tool_use', id, name, input }),
    result: (s, id, content) => ({ ...base, type: 'user', uuid: `r${++n}`, parentUuid: null, timestamp: at(s), message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content }] } }),
    credential: s => ({ ...base, type: 'attachment', uuid: `t${++n}`, parentUuid: null, timestamp: at(s), attachment: { type: 'credential_org', organizationUuid: org } }),
    title: t => ({ type: 'custom-title', customTitle: t, sessionId: sid }),
  }
}
function session(name, { t0, ctx, file, extra = () => [] }) {
  const r = records(sids[name], t0)
  const recs = [r.title(`demo ${name}`), r.credential(0), r.prompt(1, `Work on the ${name} part of the demo.`), r.reply(5, [r.text(`Started on the ${name} part.`)], { ctx: Math.round(ctx * 0.6) })]
  recs.push(...extra(r))
  recs.push(r.prompt(600, `Carry on with the ${name} part.`), r.reply(610, [r.text(`The ${name} part is done.`)], { ctx }))
  write(file, recs.map(x => JSON.stringify(x)).join('\n') + '\n')
  return file
}

const transcripts = {}
// The handoff big wrote: a Markdown file under <config>/handoffs/<project>/, named for when it was written.
const bigHandoff = path.join(config, 'handoffs', 'demo', '2026-01-31-0930-demo-big-handoff.md')
write(bigHandoff, '# Handoff: demo big\n\n## Goal\n\nFinish the big part of the demo.\n\n## Next steps\n\n1. Run the tests.\n')
transcripts.big = session('big', {
  t0: now - 6 * hour, ctx: 480000, file: path.join(projectDir, `${sids.big}.jsonl`),
  extra: r => [r.reply(300, [r.tool('toolu_w', 'Write', { file_path: fwd(bigHandoff), content: '# Handoff' })], { ctx: 400000, stop: 'tool_use' }), r.result(302, 'toolu_w', 'File created successfully'), r.reply(303, [r.text('Handoff written.')], { ctx: 401000 })],
})
transcripts.small = session('small', { t0: now - 3 * hour, ctx: 90000, file: path.join(projectDir, `${sids.small}.jsonl`) })
transcripts.stray = session('stray', { t0: now - 2 * hour, ctx: 200000, file: path.join(stray, `${sids.stray}.jsonl`) })
// notx: the path the hook records, where no file was ever written.
transcripts.notx = path.join(projectDir, `${sids.notx}.jsonl`)

const notxHandoff = path.join(config, 'handoffs', 'demo', '2026-01-31-1000-demo-notx-handoff.md')
write(notxHandoff, '# Handoff: demo notx\n\nWhere the work stands.\n')
const ms = minutesAgo => Math.round(now - minutesAgo * 60e3)
write(path.join(config, 'handoff-guard', 'live', `${sids.notx}.json`), JSON.stringify({
  v: 1, sid: sids.notx, cwd: fwd(cwd), role: null, startedAt: ms(300), updatedAt: ms(1), upToDate: true,
  track: { workAt: ms(20), handoffAt: ms(10), handoffPath: fwd(notxHandoff), turnsAfter: 0 },
  busy: false, pending: null, request: null, lastTurnAt: ms(10), ctxTokens: null, endedAt: null, endReason: null,
}, null, 2))
write(path.join(config, 'cache-keeper', 'live', `${sids.notx}.json`), JSON.stringify({ sessionName: 'demo notx', context: { tokens: 120000 } }))

// crestore's registry: what hook.ps1 records. pid 4 is the System process on Windows: alive, but no claude, so every
// entry counts as a session whose process is gone.
for (const name of Object.keys(sids)) {
  write(path.join(root, 'registry', `${sids[name]}.json`), JSON.stringify({
    session_id: sids[name], cwd, transcript_path: transcripts[name], source: 'startup',
    started_at: new Date(now - 7 * hour).toISOString(), pid: 4, claude_cmdline: 'claude.exe --dangerously-skip-permissions',
  }, null, 2))
}

console.log(JSON.stringify({ config, root, cwd, sids, transcripts, handoffs: { big: fwd(bigHandoff), notx: fwd(notxHandoff) } }))
