# Buoy
## Product Requirements Document

**Version:** 1.0  
**Platform:** macOS  
**Product type:** Local-first personal task manager

> **What needs your attention rises.**

---

# 1. Product Overview

Buoy is a personal task manager designed around a simple idea:

**The user should not have to constantly organize, prioritize, and resurface their own tasks.**

Tasks should appear when they become relevant and get out of the way when they are not.

Traditional task managers tend to mix several concepts together:

- when something needs to be completed
- when the user wants to start thinking about it
- when the user wants it visible
- how much advance warning is needed

Buoy separates those concepts.

The primary interface should remain intentionally simple while allowing sophisticated scheduling underneath.

---

# 2. Product Philosophy

Buoy is not primarily a list manager.

It is an **attention manager**.

The system should answer:

> What deserves my attention right now?

Tasks that are not yet relevant should remain out of the way.

Tasks should naturally **rise** into the user's working view as they become relevant.

The user should be able to trust Buoy enough that they do not need to repeatedly scan a giant backlog looking for something they may have forgotten.

---

# 3. Core Navigation

The primary application structure consists of three main views:

## Today

The primary working surface.

Today contains tasks that currently require the user's attention.

A task can appear in Today because:

- its **Show On** date has arrived
- its **Lead Time** window has started
- it is due today
- it is overdue
- it was manually surfaced
- a snooze period has expired

Today should feel actionable rather than archival.

---

## Upcoming

Shows tasks that Buoy knows about but that do not require attention yet.

Upcoming allows the user to understand what is coming without filling Today with premature work.

Tasks should generally be organized chronologically based on when they will next become relevant.

---

## Logbook

Contains completed tasks.

The Logbook should provide a historical record without cluttering active task views.

Completed recurring tasks should appear in the Logbook while the next occurrence remains active separately.

---

# 4. Task Model

A task should support the following core properties.

### Title

Required.

The primary description of the task.

### Notes

Optional free-form supporting information.

### Show On

The date when the task should become visible as active work.

This answers:

> When do I want to start seeing this?

A task may have a Show On date without having a Due Date.

Example:

**Task:** Research new monitor  
**Show On:** October 1  
**Due Date:** None

The task stays out of the working view until October 1.

---

### Due Date

The date by which the task should be completed.

This answers:

> When does this actually need to be done?

A Due Date should not automatically mean that the task needs to occupy Today weeks in advance.

---

### Lead Time

The amount of time before a Due Date that the task should begin surfacing.

This answers:

> How much advance warning do I need?

Example:

**Task:** Renew passport  
**Due Date:** December 1  
**Lead Time:** 30 days

Buoy begins surfacing the task approximately November 1.

Lead Time allows the system to calculate attention automatically without requiring the user to manually determine a Show On date.

---

# 5. Show On vs. Due Date vs. Lead Time

These are intentionally separate concepts.

| Field | Meaning |
|---|---|
| **Show On** | Start showing me this task |
| **Due Date** | This must be completed by this date |
| **Lead Time** | Start showing it this long before it is due |

A task may use any appropriate combination.

### Simple task

Buy light bulbs.

No dates required.

---

### Deferred task

Research landscaping ideas.

**Show On:** March 1

No deadline exists, but the user does not need to think about it until March.

---

### Deadline task

Submit registration.

**Due Date:** October 15

---

### Deadline with preparation time

Renew driver's license.

**Due Date:** November 30  
**Lead Time:** 14 days

The task begins surfacing November 16.

---

# 6. Snooze

Tasks in Today can be snoozed.

Snoozing means:

> I know about this, but I do not want it occupying my attention right now.

Common snooze choices may include:

- Later today
- Tomorrow
- This weekend
- Next week
- Pick a date

When snoozed, the task temporarily disappears from Today.

When the snooze period ends, it rises again.

Snoozing should **not modify the task's actual Due Date**.

---

# 7. Completing Tasks

A task can be marked complete from the primary interface.

Completion should:

1. Remove it from active views.
2. Record the completion timestamp.
3. Add it to the Logbook.
4. Generate the next occurrence if the task is recurring.

Completion should feel immediate.

An undo mechanism should be available for accidental completion.

---

# 8. Recurring Tasks

Buoy should support recurring tasks.

Initial recurrence patterns should include common schedules such as:

- Daily
- Weekly
- Monthly
- Yearly
- Custom interval

Recurrence should support the distinction between:

### Schedule-based recurrence

Example:

> Pay mortgage on the 1st of every month.

The next occurrence is based on the calendar schedule.

### Completion-based recurrence

Example:

> Replace HVAC filter 90 days after I last replace it.

The next occurrence is calculated from completion.

Recurring tasks should retain their relevant metadata, including:

- notes
- tags
- lead time
- recurrence rule

Each completed occurrence should remain independently visible in the Logbook.

---

# 9. Tags

Tasks may have one or more tags.

Examples:

- Work
- Home
- Errands
- Finance
- Computer
- Someday

Tags are organizational metadata rather than the primary navigation model.

Buoy should not require the user to build an elaborate folder hierarchy before the application becomes useful.

---

# 10. Notifications

Notifications should support Buoy's attention-management model rather than become a second task list.

Potential notification events include:

- a task becomes active
- a task reaches its Due Date
- a snoozed task resurfaces

Notifications should be configurable.

The application should avoid excessive notification noise.

Today remains the canonical place for understanding current work.

---

# 11. Quick Task Entry

Adding a task should be extremely fast.

At minimum, quick entry should make it easy to enter:

- title
- Show On
- Due Date
- Lead Time

Advanced properties should remain available without making basic task creation cumbersome.

The default interaction should favor:

> Capture now, organize only when necessary.

---

# 12. Task Editing

Selecting a task should provide access to its full details.

The detail interface should support editing:

- title
- notes
- Show On
- Due Date
- Lead Time
- recurrence
- tags

Changes should persist immediately.

---

# 13. Sorting and Attention Logic

The application should determine task visibility based on task state.

Conceptually:

```text
IF completed
    -> Logbook

ELSE IF snoozed and snooze date is in the future
    -> hidden from Today

ELSE IF overdue
    -> Today

ELSE IF due today
    -> Today

ELSE IF Show On <= today
    -> Today

ELSE IF Due Date - Lead Time <= today
    -> Today

ELSE
    -> Upcoming
```

The precise sorting algorithm may evolve, but urgency and relevance should determine prominence.

---

# 14. Local-First Architecture

Buoy should be **local-first**.

The user's tasks should not require an external SaaS account or cloud service to function.

Primary goals:

- fast startup
- fast interaction
- offline operation
- data ownership
- minimal infrastructure
- long-term reliability

The application should continue functioning normally without internet connectivity.

---

# 15. Technical Architecture

## Application

Native macOS application using **SwiftUI**.

Use native macOS interaction patterns wherever practical.

## Persistence

Local **SQLite** database.

The persistence layer should support future schema migrations without requiring destructive resets.

Core conceptual entities include:

```text
Task
Tag
TaskTag
RecurrenceRule
Completion
ApplicationSetting
```

Task state should be derived from persisted task attributes rather than requiring unnecessary duplicated status information.

---

# 16. Data Reliability

The database is the user's personal task history and should be treated as durable data.

The application must avoid destructive database behavior during normal upgrades.

Schema changes should use explicit migrations.

Development builds should not silently destroy existing production data.

---

# 17. Backup and Restore

Buoy should support backing up its task database.

Backups should be portable enough that the user can recover their data if the application or computer is replaced.

At minimum:

- database backups must be possible
- backup files should be restorable
- restoration should not require manually editing SQLite

Automatic backup functionality may be added as the product matures.

---

# 18. Privacy

Task data remains local by default.

Buoy should not require:

- an account
- analytics
- advertising
- external task storage
- third-party tracking

Any future synchronization capability should be explicitly designed rather than quietly changing the local-first model.

---

# 19. UX Principles

The interface should feel:

- native
- calm
- fast
- minimal
- trustworthy

Buoy should avoid turning into a project-management platform.

The user should not need to manage statuses, workflows, boards, projects, priorities, and metadata simply to remember to do something.

Sophistication should exist primarily in **when tasks surface**, not in interface complexity.

---

# 20. Non-Goals for MVP

The initial version is **not** intended to be:

- Jira
- Asana
- Trello
- a collaborative team system
- a project portfolio manager
- a chat application
- a document management platform
- an enterprise workflow engine

MVP does not require:

- collaboration
- shared lists
- web application
- Windows application
- Android application
- cloud account system
- complex project dependencies
- AI task generation
- calendar replacement

These capabilities can be considered independently later.

---

# 21. MVP Scope

MVP should provide a complete personal task-management loop:

```text
Capture
   ↓
Hide until relevant
   ↓
Surface
   ↓
Do / Snooze
   ↓
Complete
   ↓
Log
```

Required capabilities:

- create task
- edit task
- delete task
- complete task
- undo completion
- Today
- Upcoming
- Logbook
- Show On
- Due Date
- Lead Time
- Snooze
- Tags
- Recurrence
- Local persistence
- Basic notifications
- Backup capability

---

# 22. MVP Acceptance Criteria

Buoy v1 is successful when:

1. The application launches as a native macOS application.

2. A user can quickly create a task.

3. Tasks persist after quitting and reopening the application.

4. Tasks with future Show On dates remain out of Today until the appropriate date.

5. Tasks with Due Dates and Lead Times automatically surface when the lead-time window begins.

6. Due and overdue tasks appear in Today.

7. A user can snooze a task without altering its Due Date.

8. Snoozed tasks automatically return at the appropriate time.

9. A user can complete a task.

10. Completed tasks appear in the Logbook.

11. Recurring tasks generate the appropriate next occurrence.

12. Tags can be assigned to tasks.

13. The application functions without an internet connection.

14. Existing user data survives application updates and database migrations.

15. Task data can be backed up and restored.

16. The primary workflow does not require navigating a complex organizational hierarchy.

17. The application reliably answers the core Buoy question:

> **What needs my attention now?**

---

# 23. Product Principle

When deciding whether to add functionality, use this test:

> Does this help Buoy determine what deserves the user's attention, or does it simply add more task-management machinery?

When possible, choose the simpler interaction.

Buoy should handle complexity so the user does not have to.
