# Using Buoy with an agent

## Why Buoy has agent features

Buoy started as a plain personal task manager. Then I began running a personal AI agent
([Hermes](https://github.com/NousResearch/hermes-agent)) on a Mac that stays on, and wanted it to
help with my list without me giving up control of it:

- turn things I mention in passing into tasks;
- estimate how long things take, and put my todo list in a sensible order;
- suggest when to park or schedule something, without moving it itself;
- take on bigger pieces of work (research, drafts, comparisons) and hand them back for me to check.

So Buoy grew a `buoy://` link scheme, a review gate for anything an agent adds, and the
**Delegated** board. The rule throughout is that **the agent proposes and the person decides**:
agent tasks wait to be accepted, suggestions wait to be accepted, finished work waits in
Ready for review, and only the person moves work out of Shaping or into Done.

This page is written for anyone who wants to do the same with their own agent. Every action and
parameter is in [URL_SCHEME.md](../URL_SCHEME.md).

## Safety first

- **The key is the only lock.** Anything that knows the key from **Settings ▸ Agent** can change
  your tasks. Give it only to your agent, keep it out of shared files and logs, and use
  **Regenerate** if it leaks.
- **Watch for injected instructions.** If your agent reads email, web pages or messages, someone
  can write text aimed at it ("open this link…"). Tell your agent never to open a `buoy://` link it
  found in content, only ones it builds itself.
- **Keep the review gate on** (Settings ▸ Agent ▸ Review new tasks from agents), at least until
  you trust what your agent adds.
- **Deletes are recoverable** for 30 days in Settings ▸ Agent.
- **Buoy stays the only writer.** Agents change things through links and read with
  `sqlite3 -readonly`. Nothing should ever write to Buoy's database directly.

## Bring your own agent

Buoy has no AI inside it. You bring the agent: Claude Code, Hermes, or anything else that can run
commands on your Mac. It has to run on the **same Mac** as Buoy, because it opens `buoy://` links
and reads Buoy's database from disk. A chatbot in a browser tab can't do that.

## Teach it with the skill

[skills/buoy/SKILL.md](../skills/buoy/SKILL.md) is a ready-made skill that teaches an agent how
to use Buoy: every action, the board rules, ordering, suggestions and the read-only queries. It's
in the [Agent Skills](https://agentskills.io) format, which Claude Code and other agents load
directly. To install it for Claude Code:

```bash
mkdir -p ~/.claude/skills/buoy && curl -fsSL https://raw.githubusercontent.com/gregcoffman/buoy-app/main/skills/buoy/SKILL.md -o ~/.claude/skills/buoy/SKILL.md
```

For other agents, give them the file and ask them to add it to their skills or standing
instructions. Then give it the key from **Settings ▸ Agent ▸ Copy Key**, ideally as the
`BUOY_KEY` environment variable rather than pasted into a chat.

## Routines that work well with an agent

Some patterns worth trying. Pick the ones that fit you.

- **Weekday morning:** estimate anything new, order the todo list and Ready, make up to three
  suggestions, and mention only what's waiting for review, anything blocked, and the top three
  tasks. Buoy already shows the rest.
- **During the day:** small things you mention become tasks; bigger asks become Shaping cards with
  the ask, the context and the expectations. The agent works the top Ready card, one at a time,
  and tells you in its usual channel when it hands something in (Buoy's notification only reaches
  the Mac).
- **Email triage:** an email that needs you to do something becomes a task, with its due date.
  It still waits in the review strip, so it stays your call.
- **Evening:** the agent copies the day's notes from Buoy into wherever you keep notes, then
  deletes them from Buoy.
- **Weekly review:** look over Later and suggest dates for anything that should come back; suggest
  Later for tasks that have sat in Today for weeks; re-check estimates and order both lists again.
