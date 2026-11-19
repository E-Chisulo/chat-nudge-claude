import type { EngineInterface, Register, TurnCompleteInput } from 'claude-code'

// The mod half of Chat Nudge. It runs inside every Claude chat and talks to
// the menu-bar app through plain files under ~/.claude/nudge:
//
//   pending/<session>.json  written when a turn finishes, removed when the next
//                           turn starts (you replied, here or from the app)
//   replies/<session>.txt   written by the app; picked up here and submitted
//                           into this chat as your next prompt
//
// Nothing leaves the machine.

const POLL_MS = 3000
const APP_BUNDLE_ID = 'local.chat-nudge'
const RECAP_TOOL = /(^|__)wrap_up$/

let sid = ''
let hostId = ''
let root = ''
let enabled = false
let lastPrompt = ''
let polling = false

function pendingPath(): string {
  return `${root}/pending/${sid}.json`
}

function replyPath(): string {
  return `${root}/replies/${sid}.txt`
}

function plain(md: string): string {
  return md
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/^#+\s*/gm, '')
    .replace(/^\s*[-*•]\s+/gm, '')
    .replace(/[*_>|]+/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

function clip(s: string, n: number): string {
  return s.length <= n ? s : s.slice(0, n - 1).trimEnd() + '…'
}

async function remove($: EngineInterface, path: string): Promise<void> {
  await $.process.run(['/bin/rm', '-f', path]).catch(() => undefined)
}

async function setup($: EngineInterface): Promise<void> {
  const entry = (await $.env.get('CLAUDE_CODE_ENTRYPOINT')) ?? ''
  const attended = (await $.env.get('CLAUDE_CODE_SESSION_ATTENDED')) ?? '1'
  // Desktop chats and terminal sessions only: no `claude -p` runs, SDK
  // scripts or unattended scheduled tasks.
  enabled = (entry === 'claude-desktop' || entry === 'cli') && attended !== '0'
  if (!enabled) return

  const home = (await $.env.get('HOME')) ?? ''
  root = `${home}/.claude/nudge`
  sid = await $.session.id()
  hostId = (await $.env.get('CLAUDE_CODE_HOST_SESSION_ID')) ?? ''

  await $.process.run(['/bin/mkdir', '-p', `${root}/pending`, `${root}/replies`])
  // Start the menu-bar app if it is installed and not running yet.
  void $.process.run(['/usr/bin/open', '-g', '-b', APP_BUNDLE_ID]).catch(() => undefined)

  $.clock.every(POLL_MS, () => void checkReply($))
}

async function checkReply($: EngineInterface): Promise<void> {
  if (polling || !enabled) return
  polling = true
  try {
    if (!(await $.fs.exists(replyPath()))) return
    const text = (await $.fs.read(replyPath())).trim()
    await remove($, replyPath())
    if (text) await $.prompt.submit({ text })
  } catch {
    // A failed read or submit leaves the reply file in place: the app sees it
    // was never picked up and falls back to opening the chat.
  } finally {
    polling = false
  }
}

async function recapOf($: EngineInterface): Promise<{ recap: string; ask: string }> {
  try {
    const rows = await $.session.messages({ last: 40 })
    if ('deny' in rows) return { recap: '', ask: '' }
    for (const row of [...rows].reverse()) {
      // Stop at the prompt that started this turn.
      if (row.role === 'user' && row.text && !row.toolResults?.length) break
      if (row.role !== 'assistant') continue
      const use = row.toolUses.find(u => RECAP_TOOL.test(u.tool))
      if (use) {
        return {
          recap: typeof use.input.recap === 'string' ? use.input.recap : '',
          ask: typeof use.input.ask === 'string' ? use.input.ask : '',
        }
      }
    }
  } catch {
    // fall through to the answer text
  }
  return { recap: '', ask: '' }
}

async function report($: EngineInterface, e: TurnCompleteInput): Promise<void> {
  const { recap, ask } = await recapOf($)
  const answer = plain(e.answer)
  const fallback =
    e.reason === 'error'
      ? 'Stopped on an error.'
      : e.reason === 'refusal'
        ? 'Claude declined to continue.'
        : clip(answer, 280)
  const item = {
    v: 1,
    sessionId: sid,
    hostSessionId: hostId,
    cwd: await $.session.cwd(),
    finishedAt: Date.now(),
    durationMs: e.durationMs,
    reason: e.reason,
    asked: clip(plain(lastPrompt), 160),
    brief: clip(plain(recap || fallback || 'Finished.'), 400),
    question: clip(plain(ask), 140),
    answer: clip(answer, 2000),
  }
  const tmp = `${pendingPath()}.tmp`
  await $.fs.write(tmp, JSON.stringify(item, null, 2))
  await $.process.run(['/bin/mv', '-f', tmp, pendingPath()])
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await setup($).catch(() => {
      enabled = false
    })
    return result
  })

  on('turn.start', async ($, e, next) => {
    if (enabled && e.agentId === undefined) {
      if (e.text) lastPrompt = e.text
      // You're back (or a reply from the app just landed): stop nagging.
      void remove($, pendingPath())
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    // Main conversation only, and not when you interrupted it yourself.
    if (enabled && e.agentId === undefined && e.reason !== 'aborted') {
      await report($, e).catch(() => undefined)
    }
    return result
  })
  // No session.end cleanup on purpose: the desktop app may stop an idle chat's
  // engine, and that is exactly the chat you forgot. The menu-bar app drops
  // items for chats that are archived or gone.
}
