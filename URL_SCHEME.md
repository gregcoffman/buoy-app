# Buoy URL scheme (`buoy://`)

Agents (and scripts) can add, change and delete tasks, projects and notes by opening `buoy://` links. Buoy carries out each
link through the same code the app's own buttons use, so **Buoy stays the only writer to its
database**. Nothing else should ever write to `Buoy.sqlite`; reading it is fine.

```bash
open -g "buoy://add?key=YOUR_KEY&title=Renew%20passport&due_on=2026-12-01&lead_days=30"
```

`open -g` delivers the link without bringing Buoy to the front. If Buoy isn't running, the link
launches it and is then processed. Links never open a window.

## Setup

1. Open **Buoy ▸ Settings ▸ Agent** and click **Copy Key**.
2. Give the key to your agent. Every link must include `key=…`; a link without the right key is
   ignored, so a web page or another app can't change your tasks.
3. **New Key…** makes a fresh key; links with the old one stop working.

## Rules for every link

- Percent-encode values: space is `%20`, newline `%0A`, `#` is `%23`, `&` is `%26`.
  A `+` stays a literal plus sign.
- Dates are `YYYY-MM-DD` and must be real (`2026-02-30` is rejected).
- IDs are UUIDs. Buoy stores them uppercase, like `3F2504E0-4F89-11D3-9A0C-0305E82C3301`.
- Unknown actions, unknown or repeated parameters, missing required values and malformed
  values are **rejected as a whole**: nothing changes, and the reason is logged.

## Actions

| Action | Parameters | What it does |
|---|---|---|
| `buoy://add` | `title` (required), `notes`, `expectations` (projects only), `show_on`, `due_on`, `lead_days` (0–365, needs `due_on`), `tags` (comma-separated), `id` (optional UUID you choose), `kind` (`task` or `project`; default `task`), `later` (`1` to park it in Later), `effort_hours`, `repeat` | Adds a task or project. A new project always goes to the top of **Shaping**. The title is used exactly as given: it is **not** read for dates the way quick entry is. Passing your own `id` lets you refer to it later; an `id` that's already used is rejected. |
| `buoy://complete` | `id` **or** `title_match` | Completes an open task. **Not for projects**: hand a project in with `update` `column=review` and a `result`; only the user moves it to Done. `title_match` must match exactly one open task or project title (case-insensitive, surrounding spaces ignored). Zero or several matches → nothing happens, and the candidates are logged. Buoy never guesses. |
| `buoy://snooze` | `id`, `until` (a date after today) | Hides the task until that day. Its due date doesn't change. |
| `buoy://update` | `id`, plus any of `title`, `notes`, `show_on`, `due_on`, `lead_days`, `tags`, `kind`, `later`, `effort_hours`, `repeat`, and for projects `expectations`, `column`, `status`, `result` | Changes only the fields given. `later=1` parks it in Later, `later=0` brings it back. An empty value clears a date (`due_on=`), the tags (`tags=`), the estimate (`effort_hours=`), the repeat (`repeat=`), the status (`status=`) or the result. `tags` replaces the existing tags. `kind=project` turns a task into a project (top of Shaping); `kind=task` turns a project back into a task. `column` moves a project between Ready, In progress and Ready for review (see below). |
| `buoy://note` | `text` (required) | Saves a plain-text note in Notes, exactly as given. |
| `buoy://delete` | `id` | Deletes a task, project or note. Agent deletes are **recoverable for 30 days** (see below). |
| `buoy://suggest` | `id`, one of `later=1`, `show_on`, `due_on`, plus `reason`; or `clear=1` | Suggests parking a task in Later, or giving it a Show On or due date. It waits at the top of Today until the user accepts or dismisses it. See **Suggestions** below. |
| `buoy://reorder` | `list` (`tasks` or `ready`), `ids` (comma-separated, top first) | Puts the todo list or the Ready column in order. See **Ordering** below. |

## Later

`later=1` keeps a task out of Today until you (or the agent, with `later=0`) move it back. Deadlines
still win: a Later task shows in Today anyway when it's due, overdue, or inside its lead time. In
the database it's `tasks.later` (`1` or `0`).

## Repeating tasks

`repeat` takes the same phrases as quick entry: `every day`, `every 2 weeks`, `every other week`,
`every monday`, `every other thursday`, `every mon wed fri`, `every weekday`, `every 2nd tuesday`,
`every last friday`, `every last day of the month`, `every 90 days after done`. The series is
anchored on the task's due date, or its Show On date. A weekday pattern with no dates starts on
the next matching day. When the task is completed, the next one appears on its own with the same
notes, tags, lead time and estimate. An empty `repeat=` stops it repeating. Anything else in the
phrase (dates, tags) is rejected: pass those as their own parameters.

```bash
open -g "buoy://add?key=$KEY&id=$(uuidgen)&title=Exec%20update&due_on=2026-11-05&repeat=every%202%20weeks"
```

## Level of effort

`effort_hours` is a rough estimate in hours on any task or project: `2`, `0.5`, `1.5` (more than 0,
at most 1000). An empty value clears it. It shows quietly: a grey "~2h" on board cards and an
Effort chip on an open task or project, never in the lists. The agent usually sets it; the user can
change it. In the database it's `tasks.effort_hours` (NULL when not estimated).

## Ordering

The agent can put two lists in order, separately. Each reorder shows "Your agent reordered …" with
**Undo**.

- **`list=tasks`: the todo list.** List open tasks, top first: all of them, or just the ones you
  care about. Today shows its tasks in that order, and tasks that rise into Today later arrive in
  their place. Anything you leave out, and anything added since, sits on **top** of Today (most
  urgent first) until you order again, so nothing new gets buried. Overdue and due-today tasks
  keep their red and orange labels wherever you put them. Completed tasks or tasks waiting for
  review are rejected. Dated projects that show in Today can be listed too. In the database:
  `tasks.agent_rank` (smaller is higher; NULL when not ordered).
- **`list=ready`: the Delegated queue.** `ids` must name **every** project in Ready exactly
  once; otherwise nothing changes and the log names what's missing or extra. Shaping, In progress
  and Ready for review can't be reordered by the agent.

```bash
open -g "buoy://reorder?key=$KEY&list=tasks&ids=$ID1,$ID2,$ID3"
open -g "buoy://reorder?key=$KEY&list=ready&ids=$P1,$P2"
```

## Suggestions

When the agent thinks a task belongs somewhere else, it suggests rather than moves it:

- `later=1`: park it in Later.
- `show_on=YYYY-MM-DD` (after today): schedule it to show on that day. Accepting also takes it
  out of Later.
- `due_on=YYYY-MM-DD` (today or later): give it that due date.

`reason` is required: one line the user reads to decide ("No date, in Today 3 weeks"). Suggestions
appear in a strip at the top of Today and The Bridge, **Your agent suggests**, with Accept,
Dismiss and Accept All. Nothing changes until the user accepts; accepting does exactly what
editing the task would (and can be undone). A task with a suggestion doesn't show the "Not now"
nudge.

One suggestion per task: a new one replaces the old. `clear=1` withdraws it. Suggestions are for
open tasks only, not projects, completed tasks or tasks waiting for review.

Dismissed suggestions are kept on the task (`suggestion_dismissed_at`), so the agent can see the
user said no and not suggest the same thing again.

```bash
open -g "buoy://suggest?key=$KEY&id=$ID&later=1&reason=No%20date%2C%20in%20Today%203%20weeks"
open -g "buoy://suggest?key=$KEY&id=$ID&show_on=2026-11-03&reason=You%27re%20free%20Tuesday%20morning"
open -g "buoy://suggest?key=$KEY&id=$ID&clear=1"
```

## Delegated: the agent board

Projects live on one board that hands work to an agent:
**Shaping · Ready · In progress · Ready for review · Done**.

- **Shaping** is where the user writes the ask. The agent may add cards here (they always land
  at the top), but **only the user moves a card out of Shaping**.
- **Ready** is the agent's queue. The agent orders it (`reorder` `list=ready`) and takes cards
  from the top.
- **In progress**: the agent moves a card here when it starts, and can set a one-line `status`
  ("Comparing three vendors") that shows on the card. If it can't finish because it needs
  something from the user, it sends the card **back to Shaping with a `status` saying what it
  needs** ("Blocked: need the bank logins"). The card lands at the top of Shaping with that line on
  it; when the user drags it out of Shaping again, the old status is cleared. (Back to Ready would
  loop: the agent takes the top of Ready.)
- **Ready for review**: when the work is done, the agent moves the card here with `result`, a
  short description of what it delivered and where. The deliverable itself lives wherever the
  work was done. **Only the user moves a card out of review**: to Done, or back for more work.
- **Done**: the user's call. `buoy://complete` doesn't work on projects.

A card's fields: the **title** is the ask; **notes** are the why and context; **expectations**
is the user's description of what done looks like (format, where it goes, how it's judged);
`status` and `result` are the agent's; `effort_hours` is shared. Read all three of the user's
fields before starting. A project is a task with `kind=project`, so it also has dates, lead
time, tags and repeat. A project **without dates** stays on the board; one with a Show On or Due
date also shows up in Today and Upcoming when it's time.

| `column` value | Agent may move a project there from |
|---|---|
| `in_progress` | Ready |
| `ready` | In progress |
| `review` | Ready or In progress, with a `result` (in the same link or already set). The old `status` is cleared unless the link sets one. |
| `shaping` | Ready or In progress, only with a `status` in the same link saying what's needed |

Handing a card in to review puts a count on **Delegated** in the sidebar and, unless it's turned
off in Settings ▸ Notifications, sends a notification ("Ready for review") that opens the card.

Moves the agent isn't allowed (out of Shaping, into Shaping without a status, out of Ready for review,
`column=done`) are rejected and logged, and nothing changes. Projects an agent adds skip the
review strip: Shaping is where the user looks them over.

```bash
open -g "buoy://update?key=$KEY&id=$ID&column=in_progress&status=Reading%20the%20brief"
open -g "buoy://update?key=$KEY&id=$ID&status=Drafting%20section%202%20of%204"
open -g "buoy://update?key=$KEY&id=$ID&column=review&result=Wrote%20the%20one-page%20comparison%20and%20emailed%20it"
```

## Deletes are recoverable

When an agent deletes something, it disappears from Buoy but is kept for 30 days in
**Settings ▸ Agent ▸ Deleted by agents**, where you can **Restore** it. After 30 days it's removed
for good. (Your own deletes work as before: Undo, or ⌘Z.)

## Reading Buoy's data

Agents read the database directly, read-only. Never write to it.

```bash
DB="$HOME/Library/Application Support/Buoy/Buoy.sqlite"

# Open tasks (not projects), with their dates, tags, estimate and the agent's order
sqlite3 -readonly -json "$DB" "SELECT t.id, t.title, t.notes, t.show_on, t.due_on, t.lead_days, t.later, t.source,
  t.effort_hours, t.agent_rank,
  (SELECT group_concat(g.name) FROM task_tags tt JOIN tags g ON g.id = tt.tag_id WHERE tt.task_id = t.id) AS tags
  FROM tasks t WHERE t.kind = 'task' AND t.deleted_at IS NULL AND t.pending_review = 0
  AND t.id NOT IN (SELECT task_id FROM completions) ORDER BY t.agent_rank IS NULL, t.agent_rank, t.created_at"

# The agent's queue: Ready, top first (title is the ask, notes the context)
sqlite3 -readonly -json "$DB" "SELECT id, title, notes, expectations, due_on, show_on, effort_hours FROM tasks
  WHERE kind = 'project' AND board_column = 'ready' AND deleted_at IS NULL AND pending_review = 0
  AND id NOT IN (SELECT task_id FROM completions) ORDER BY board_position, created_at"

# Everything on the board, column by column
sqlite3 -readonly -json "$DB" "SELECT id, title, board_column, status, result, effort_hours, notes FROM tasks
  WHERE kind = 'project' AND deleted_at IS NULL AND pending_review = 0
  AND id NOT IN (SELECT task_id FROM completions)
  ORDER BY CASE board_column WHEN 'shaping' THEN 0 WHEN 'ready' THEN 1 WHEN 'in_progress' THEN 2 ELSE 3 END, board_position"

# Notes waiting in Notes (to ingest, then buoy://delete each one)
sqlite3 -readonly -json "$DB" "SELECT id, text, created_at FROM notes
  WHERE deleted_at IS NULL AND archived_at IS NULL ORDER BY created_at"
```

Rows with `deleted_at` set are in the 30-day restore list; skip them.

## Review gate (on by default)

Tasks an agent adds **don't join your lists straight away**. They wait in a strip at the top of
Today ("From your agent · N to review") until you click **Accept** (the task goes wherever its
dates put it) or **Dismiss** (it's deleted; Undo brings it back). Double-click one to edit it
first. While waiting, a task is in no list, count or notification, and agents can `update` it
but not `complete` or `snooze` it; `title_match` doesn't see it.

Turn this off in **Settings ▸ Agent ▸ Review new tasks from agents** to let agent tasks go
straight to your lists. Notes skip the gate: the Notes list is already something you review.

## Telling agent items apart

Everything an agent creates is marked with a small ✦ sparkle in Buoy (and "Added by an agent"
when a task is open). In the database:

| Column | Values |
|---|---|
| `tasks.source`, `notes.source` | `'user'` or `'agent'` |
| `tasks.pending_review` | `1` while waiting for review, `0` once accepted (or for your own tasks) |
| `tasks.kind` | `'task'` or `'project'` |
| `tasks.board_column`, `tasks.board_position` | a project's column (`shaping`, `ready`, `in_progress`, `review`) and its order within it (smaller is higher) |
| `tasks.effort_hours` | rough level of effort in hours (NULL if not estimated) |
| `tasks.suggested_move`, `tasks.suggested_on`, `tasks.suggestion_reason`, `tasks.suggested_at`, `tasks.suggestion_dismissed_at` | the agent's suggestion: `later`, `show_on` or `due_on` (NULL if none), its date, reason, when it was made, and when the user dismissed it (NULL while waiting) |
| `tasks.agent_rank` | the agent's order for the todo list (smaller is higher; NULL if not ordered) |
| `tasks.expectations` | a project's delivery expectations, written by the user (empty if none) |
| `tasks.status`, `tasks.result` | a project's one-line status and what it delivered (empty if none) |
| `tasks.deleted_at`, `notes.deleted_at` | set when an agent deleted it (restorable for 30 days) |

A task is complete when it has a row in `completions`.

## Logs

Every link is logged, with the key masked:

```bash
/usr/bin/log stream --predicate 'subsystem == "app.buoy.Buoy" AND category == "url"'
```

(Use `/usr/bin/log`: in zsh, plain `log` is a shell built-in.) To see the last few minutes
instead of watching live: `/usr/bin/log show --last 5m --predicate 'subsystem == "app.buoy.Buoy" AND category == "url"'`.

## Try every action

Paste these into Terminal one block at a time. The checks only **read** the database.

```bash
KEY=paste-your-key-here
DB="$HOME/Library/Application Support/Buoy/Buoy.sqlite"
ID=0B0E5E4A-1D2B-4C3D-8E4F-5A6B7C8D9E01
```

**1. Add** (choosing the ID so the next steps can use it):

```bash
open -g "buoy://add?key=$KEY&id=$ID&title=URL%20scheme%20test&notes=Delete%20me%20afterwards&due_on=2026-12-15&lead_days=3&tags=Test"
sqlite3 -readonly "$DB" "SELECT title, due_on, lead_days, source, pending_review FROM tasks WHERE id='$ID'"
```

Expect `URL scheme test|2026-12-15|3|agent|1`, and the task waiting at the top of Today.
Click **Accept** in Buoy, then run the `sqlite3` line again: `pending_review` is now `0`.

**2. Update:**

```bash
open -g "buoy://update?key=$KEY&id=$ID&title=URL%20scheme%20test%20(renamed)&due_on=2026-12-20"
sqlite3 -readonly "$DB" "SELECT title, due_on FROM tasks WHERE id='$ID'"
```

**3. Snooze** (pick any date after today):

```bash
open -g "buoy://snooze?key=$KEY&id=$ID&until=2026-12-01"
sqlite3 -readonly "$DB" "SELECT title, date(snoozed_until, 'unixepoch', 'localtime') FROM tasks WHERE id='$ID'"
```

**4. Complete by title** (exact title, any case):

```bash
open -g "buoy://complete?key=$KEY&title_match=url%20scheme%20test%20(renamed)"
sqlite3 -readonly "$DB" "SELECT count(*) FROM completions WHERE task_id='$ID'"
```

Expect `1`, and the task in the Logbook. (`buoy://complete?key=$KEY&id=$ID` does the same by ID.)

**5. Note:**

```bash
open -g "buoy://note?key=$KEY&text=Note%20from%20the%20URL%20scheme%0Asecond%20line%20%23test"
sqlite3 -readonly "$DB" "SELECT text, source FROM notes ORDER BY created_at DESC LIMIT 1"
```

**6. A project**: added to Shaping, a refused move, then deleted (restorable in Settings ▸ Agent):

```bash
PID=1A2B3C4D-0000-4000-8000-00000000AAAA
open -g "buoy://add?key=$KEY&id=$PID&title=URL%20scheme%20test%20project&kind=project"
open -g "buoy://update?key=$KEY&id=$PID&column=in_progress"
sqlite3 -readonly "$DB" "SELECT title, kind, board_column FROM tasks WHERE id='$PID'"
open -g "buoy://delete?key=$KEY&id=$PID"
sqlite3 -readonly "$DB" "SELECT title, deleted_at IS NOT NULL FROM tasks WHERE id='$PID'"
```

The move is refused (it's still in Shaping), so `board_column` stays `shaping`, and the log says why.

**7. A rejected link** (wrong key), then the log that explains it:

```bash
open -g "buoy://add?key=wrong&title=Should%20not%20appear"
/usr/bin/log show --last 1m --predicate 'subsystem == "app.buoy.Buoy" AND category == "url"'
```

When you're done, delete the test task from the Logbook and the note from Notes, and remove
the test project from Settings ▸ Agent ▸ Deleted by agents (or just let it expire).
