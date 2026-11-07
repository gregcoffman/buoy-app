# Buoy

> What needs your attention rises.

A local-first macOS task manager built around **when tasks surface**, not how they're filed.
See [docs/PRD.md](docs/PRD.md) for the product requirements.

## Build & run

Requires macOS 14+ and the Swift toolchain (Command Line Tools are enough; Xcode is optional).

```bash
scripts/build-app.sh --run        # build build/Buoy.app and launch it
scripts/build-app.sh --install    # build and copy to /Applications
swift run BuoyChecks              # run the core logic checks
swift run Buoy                    # debug run (uses a separate Buoy-Dev data folder)
```

You can also open `Package.swift` in Xcode.

## Using Buoy

- **The Bridge**: everything on one page, near to far: Today, then Upcoming, then Later. Each section collapses. Today, Upcoming and Later in the sidebar show just that one.
- **Today**: what needs attention now. Overdue first, then due today, then anything with a deadline, then undated tasks.
- **Upcoming**: what Buoy knows about, grouped by the day it will rise.
- **Later**: tasks you've parked to keep them out of Today. Right-click ▸ **Move to Later**, ⌥⌘L, the Later button, drag a task onto Later in the sidebar, or end a quick entry with "later" (`Research standing desks later`). **Move to Today** brings one back. Deadlines still win: a Later task that comes due, goes overdue, or reaches its lead time shows in Today anyway.
- **Logbook**: completed tasks, including each completed occurrence of a repeating task.
- **Notes**: plain-text thoughts that aren't tasks, waiting to be copied somewhere else (Obsidian, an email, a doc). Start a ⌃Space line with `>` to save a note, or press ⌥⌘N. Notes have no dates or tags: `#work` stays plain text, so it becomes a tag wherever you paste it. **Copy** puts a note on the clipboard exactly as typed. **Copy All & Archive** copies every waiting note, separated by blank lines, and archives them. Archived notes are kept and searchable, and can be moved back or copied again.
- **Convert** by right-clicking: a task's **Convert to Note** keeps its title and notes (tags come along as `#tags`, dates and repeats are dropped); a note's **Convert to Task** makes the first line the title and the rest its notes, as an undated task in Today. Both undo in one step.
- **Delegated**: one board that hands work to your agent, **Shaping · Ready · In progress · Ready for review · Done**. Open a card to write its brief on a full-size page: the ask, **Why / context** and **Delivery expectations**, with Save and Cancel. Drag it to Ready when it's ready; the agent orders Ready, takes it from the top, shows a one-line status while it works, and hands it in to Ready for review with a description of what it delivered. Only you move cards out of Shaping and out of review (to Done, or back). Drag cards to order them. A project with a Show On or Due date also shows up in Today and Upcoming when it's time; undated ones stay on the board. Right-click a task ▸ **Convert to Project**, or a project ▸ **Convert to Task**.
- **Level of effort**: any task or project can carry a rough estimate in hours, usually from your agent. It stays quiet: a grey "~2h" on board cards, and an Effort chip when a task is open.
- **Suggestions**: your agent can suggest parking a task in Later or giving it a Show On or due date, with a one-line reason. They wait at the top of Today ("Your agent suggests") until you click Accept or Dismiss.
- **Agent order**: your agent can put your todo list in order (Today follows it; anything new sits on top until it orders again) and the Ready column, separately. Each reorder can be undone from the message that appears.
- **Tags** appear in the sidebar once used, but you never have to organize anything to get started.
- **Open a task** by double-clicking it: it expands in place into a card for notes, dates, lead time, repeat and tags. Changes save as you go.
- **Tomorrow peek**: the bottom of Today quietly lists what rises tomorrow.
- **Not now**: a task with no due date that has sat in Today for two weeks shows its age and offers to snooze it.
- **Skip This Occurrence** (context menu or a task's ⋯ menu) moves a repeating task on without logging it.
- **Notifications** have Complete and Snooze Until Tomorrow buttons. When several tasks are combined into one notification, it offers only Snooze All. When your agent hands a Delegated card in for review, you get a notification right away (turn it off in Settings ▸ Notifications), and Delegated shows a count in the sidebar.
- **Open Buoy at login** is in Settings ▸ General. It works best with Buoy in /Applications (`scripts/build-app.sh --install`).

### Quick entry

Type naturally in a new task (the **+** button or ⌘N), the menu bar popover, or the global quick-entry panel (**⌃Space** by default, configurable in Settings):

| You type | Buoy understands |
|---|---|
| `Renew passport due dec 1 lead 30d #finance` | Due Dec 1, rises Nov 1, tagged Finance |
| `Research landscaping show mar 1` | Hidden until March 1 |
| `Call mom tomorrow` | Shows tomorrow |
| `Pay mortgage due oct 1 every month` | Repeats on the calendar schedule |
| `Replace HVAC filter every 90 days after done` | Repeats 90 days after each completion |
| `Team sync every monday` | Weekly, starting Monday |
| `Gym every mon wed fri` | Specific weekdays (also `every weekday`) |
| `Exec update every other thursday` | Every two weeks on Thursday, starting with the next one |
| `Book club every 2nd tuesday` | Nth weekday of the month (also `every last friday`) |
| `Pay card every last day of the month` | Month-end |
| `> gate code is 4471` | A note, not a task: saved to Notes exactly as typed |
| `Research standing desks later` | Parked in Later instead of Today |

Dates: `today`, `tomorrow`, weekdays, `next week`, `next month`, `weekend`, `in 3 days`, `in 2 weeks`, `dec 1`, `1 dec`, `12/1`, `2026-12-01`, `end of month`.
Keywords only take effect when a valid value follows, so "Work on report" stays a plain title.
The Show On / Due / Lead chips let you set or correct dates: one click on Today, Tomorrow, This Weekend, Next Week or In a Month, or any day on the calendar.

### Keyboard

| | |
|---|---|
| ⌘N | New task in the current list |
| ⌥⌘N | New note |
| ⇧⌘N | Quick-entry panel |
| ⌘K | Complete selected |
| ⌥⌘T | Snooze until tomorrow |
| ⇧⌘T | Move to Today |
| ⌥⌘L | Move to Later |
| ⌘I or double-click | Open or close a task in place (Esc closes) |
| ⌘1 … ⌘7 | The Bridge, Today, Upcoming, Later, Logbook, Delegated, Notes (sidebar order) |
| ⌘C / ⇧⌘C | Copy selected notes / Copy all notes and archive them |
| ⌫ | Delete selected |
| ⌘Z | Undo complete, snooze, archive, delete, and so on |

## How attention works

A task's state is derived from its dates and is never stored separately (`Sources/BuoyCore/Attention.swift`):

1. Completed → **Logbook**
2. Snoozed into the future → **Upcoming** (Due Date untouched)
3. Overdue, due today, Show On reached, or inside its lead-time window → **Today**
4. Manually moved to Today, or back from an expired snooze → **Today**
5. No dates at all → **Today** (a simple "buy light bulbs" task)
6. Otherwise → **Upcoming**, placed on the day it will rise

Editing a task's dates clears any manual snooze or "Move to Today", so the new schedule takes over.

**Repeating tasks.** Schedule-based repeats are measured from a fixed anchor date, so a task on the 31st returns to the 31st after February. Missed occurrences are skipped rather than piled up. Completion-based repeats count from the day you complete the task. Notes, tags, lead time, and the rule carry over to the next occurrence.

## Agents (buoy:// links)

An agent can add, complete, snooze, update and delete tasks and projects, and save or delete notes, by opening `buoy://` links, for example `open -g "buoy://add?key=…&title=Renew%20passport&due_on=2026-12-01"`. Buoy applies each link through its own code, so it stays the only writer to its database.

- Every link needs the key from **Settings ▸ Agent**; anything else is ignored and logged.
- Agent tasks wait at the top of Today for you to **Accept** or **Dismiss** (turn this off in Settings ▸ Agent).
- It can estimate effort, order your todo list and the Ready column, and hand finished projects in to **Ready for review**; only you move them to Done.
- Anything an agent adds is marked with a small sparkle. Anything it deletes can be restored for 30 days (Settings ▸ Agent).

See [URL_SCHEME.md](URL_SCHEME.md) for every action and parameter, and Terminal examples to try each one. [docs/USING_AN_AGENT.md](docs/USING_AN_AGENT.md) explains why Buoy has these features (a personal agent built on Hermes was the use case), how to keep an agent safe with them, and a starting skill to give your own agent.

## Data

- Stored in `~/Library/Application Support/Buoy/Buoy.sqlite`. Debug builds use `Buoy-Dev`, and `BUOY_DATA_DIR` overrides both.
- No account, network access, analytics, or tracking.
- **Migrations** are explicit and append-only (`Sources/BuoyCore/Migrations.swift`), tracked by `PRAGMA user_version`. Each runs in a transaction, and a copy of the database is saved to `Backups/` before any migration. A database from a newer Buoy is refused, never modified.
- **Backups**: File ▸ Back Up Database… writes a single portable `.sqlite` file. File ▸ Restore from Backup… validates the file, saves your current data to `Backups/` first, and then replaces it. Buoy also keeps a daily automatic backup (the last 14).

## Layout

```
Sources/BuoyCore/     model, attention engine, recurrence, parser, SQLite, migrations, backup, notification planning
Sources/Buoy/         SwiftUI app: windows, menu bar, quick-entry panel, global hotkey, notifications
Sources/BuoyChecks/   check runner for BuoyCore (XCTest needs full Xcode)
scripts/              build-app.sh, make-icon.sh
```

For development, `BUOY_SNAPSHOT_DIR=/tmp/snaps swift run Buoy` walks through the main screens, writes a PNG of each window, and quits. This is available in debug builds only.

## License

MIT. See [LICENSE](LICENSE).
