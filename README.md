# Chat Nudge

A small macOS menu bar app that pings me when a Claude chat finishes, so I stop
forgetting about tasks I handed off and coming back 40 minutes later. It shows
a short summary of what the chat did, lets me reply with the next instruction
straight from the notification, and keeps reminding me, louder each time,
until I deal with it.

## How it works

Two parts that talk through plain files in `~/.claude/nudge/`:

- `mod/` is a Claude Code mod (function hooks) that loads into every chat.
  When a turn finishes it writes `pending/<session>.json` with a short summary.
  Every 3 seconds it checks `replies/<session>.txt`, and if there's something
  there it sends it into the chat as the next prompt. When the chat starts a
  new turn it deletes the pending file, which stops the reminders. It ignores
  `claude -p` runs and unattended scheduled tasks.
- `app/` is the menu bar app. It watches `pending/`, posts notifications with
  Reply, Open chat, Snooze 15 min and Got it, and keeps a list of waiting
  chats under the bell icon, each with its own reply box.

Nothing leaves your machine.

## Reminders

The default interval is 5 minutes. You can change it in the menu.

- 0 min: notification with the summary, one Glass sound
- 5 min: "Still waiting" notification, Glass twice
- 10 min: Submarine three times and a spoken "Claude is still waiting on ..."
- 15 min and after: all of that, plus a floating window on every desktop that
  stays up until you reply, snooze, open the chat or dismiss it

It holds off while you're looking at that chat in the Claude app. Opening the
chat pauses it for one round. Replying, snoozing or Got it stop it. Pause in
the menu silences everything for 1 or 3 hours, and Test plays the loudest level
so you know what to listen for. The app plays its own sounds, so they still
come through when a Focus mode mutes notifications.

Chats older than 24 hours, or archived in Claude, get dropped.

## Replying

Type in the notification's Reply field or in the reply box in the menu. The
chat picks it up within about 3 seconds and runs it as your next message.

If the chat isn't running anymore (you closed it, or the desktop app stopped
it), the app waits 15 seconds, then opens the chat and puts your reply on the
clipboard so you can paste it.

## Setup

You need macOS 13 or later and the Xcode command line tools.

1. Build and install the app:

   ```bash
   ./app/build.sh install
   ```

   This puts `Chat Nudge.app` in `~/Applications` and starts it. Allow
   notifications when macOS asks. Setting the style to Persistent in System
   Settings > Notifications > Chat Nudge keeps the banners up until you act on
   them.

2. Load the mod. Either point every session at this folder by adding this to
   `~/.claude/settings.json`, with the full path to `mod` in your clone:

   ```json
   "env": { "CLAUDE_CODE_PLUGIN_DIRS": "/path/to/chat-nudge-claude/mod" }
   ```

   or install it as a plugin. At the prompt of a terminal session:

   ```
   /plugin install chat-nudge --marketplace E-Chisulo/chat-nudge-claude
   ```

   From a shell:

   ```bash
   claude plugin install chat-nudge --marketplace E-Chisulo/chat-nudge-claude
   ```

   In the desktop app, click + next to the prompt box, then Plugins, Add
   marketplace with `E-Chisulo/chat-nudge-claude`, then Add plugin.

Chats that were already open pick the mod up after they restart. Every new
session also starts the app if it isn't running, and "Open at login" in the
menu keeps it running all the time.

To check the menu layout without clicking around, this renders it with two
sample chats:

```bash
"app/build/Chat Nudge.app/Contents/MacOS/ChatNudge" --snapshot menu.png
```

## Files

- `mod/hooks/register.ts`: the mod
- `app/ChatNudge.swift`: the whole app, SwiftUI menu bar plus UserNotifications
- `app/build.sh`, `app/Info.plist`, `app/make-icon.swift`: build script,
  bundle info and the icon
- Chat titles come from the Claude app's own session records in
  `~/Library/Application Support/Claude/claude-code-sessions/`, and Open chat
  uses `claude://code/continue?session=<id>`.
