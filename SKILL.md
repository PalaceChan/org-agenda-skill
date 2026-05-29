---
name: org-agenda
description: Manage Org agenda and capture top-level TODO tasks in a running Emacs server via emacsclient. Use when the user wants to capture top-level TODO tasks, inspect agenda or TODO views, locate arbitrary Org headings, jump to Org entries, or operate on stable Org metadata.
metadata:
  version: "1.0"
---

# Org agenda and capture management

Manage the user's live Org workflow inside an existing Emacs session.

Use this skill when the user wants help with the same Org agenda they normally view with `(org-agenda)`.

This skill assumes the user already has an Emacs server running, and you must use `emacsclient` for all interactions.

## What this skill is good at

- Capturing top-level TODOs into `todo.org`
- Inspecting agenda and TODO views
- Locating arbitrary Org headings exactly by title or outline path
- Creating or ensuring child headings like `Plan` and `Memory`
- Reading subtree metadata and body/subtree content under headings
- Replacing and appending body content under headings, including large content from files
- Updating known tasks by ID or exact target
- Archiving and refiling known entries

## Important orientation

- `oab-capture-task` still creates **top-level** TODO entries.
- For structured subtree work under an existing heading, prefer this pattern:
  1. Find the target heading exactly.
  2. Ensure the child heading you want exists.
  3. Replace or append body content under that child.
- Prefer `-id` when you already have a stable ID.
- Prefer `-by-path` when targeting a non-TODO organizational heading.
- Prefer `-at` only when you already have `:file` and `:pos` from a previous result.

## Preconditions

- Org mode is available in the running Emacs session.
- Load the bridge once per Emacs session before first use.
- `org-agenda-files` should already point at the user's agenda files when possible.
- If `org-agenda-files` is empty, the bridge falls back to this file under `org-directory`:
  - `todo.org`

## Load the bridge elisp

If the skill is installed under the default skills directory, load it like this:

```bash
emacsclient --eval '
(load "~/.agents/skills/org-agenda/scripts/oab.el" nil t)'
```

When developing this skill from a repo checkout, load the repo-local copy instead, for example:

```bash
emacsclient --eval '
(load "/path/to/org-agenda-skill/scripts/oab.el" nil t)'
```

## Naming conventions

- `find-*`: exact lookup only; errors on zero or multiple matches.
- `insert-child-*`: always append a fresh direct child.
- `ensure-child-*`: return an existing exact direct child, or create it if missing.
- `get-body-*`: inspect the body directly under a heading.
- `get-subtree-*`: inspect a full subtree, optionally including the heading line.
- `replace-body-*`: replace only the body region under a heading.
- `append-body-*`: append only to the body region under a heading.
- `*-from-file`: read replacement/appended body text inside Emacs from a file, useful for large generated content.
- `-id`: target a known stable Org ID.
- `-by-path`: target an exact outline path.
- `-at`: target an exact `file` + `pos` pair.
- `ensure-id` options mutate files by creating missing `:ID:` properties only on the specific matched heading.

## Public API

- `Capture`:
  - `oab-capture-task`

- `Subtree authoring`:
  - `oab-insert-child-heading-id`, `oab-insert-child-heading-by-path`
  - `oab-find-child-heading-id`, `oab-find-child-heading-by-path`
  - `oab-ensure-child-heading-id`, `oab-ensure-child-heading-by-path`
  - `oab-get-body-id`, `oab-get-body-by-path`
  - `oab-get-subtree-id`, `oab-get-subtree-by-path`, `oab-get-subtree-at`
  - `oab-replace-body-id`, `oab-replace-body-by-path`
  - `oab-replace-body-id-from-file`, `oab-replace-body-by-path-from-file`
  - `oab-append-body-id`, `oab-append-body-by-path`
  - `oab-append-body-id-from-file`, `oab-append-body-by-path-from-file`

- `Query and navigation`:
  - `oab-agenda-items`, `oab-todo-items`, `oab-summary`
  - `oab-find-heading-in-file`, `oab-find-heading-by-path`, `oab-find-id`

- `State and planning updates`:
  - `oab-set-todo-at`, `oab-set-todo-id`
  - `oab-schedule-at`, `oab-schedule-id`
  - `oab-deadline-at`, `oab-deadline-id`

- `Tags`:
  - `oab-set-tags-at`, `oab-set-tags-id`
  - `oab-add-tags-at`, `oab-add-tags-id`
  - `oab-remove-tags-at`, `oab-remove-tags-id`

- `Archive and refile`:
  - `oab-archive-at`, `oab-archive-id`
  - `oab-refile-id-to-file`, `oab-refile-id-to-id`

## Returned metadata

Most lookup, open, and update functions return a plist including:

- `:id`
- `:file`
- `:pos`
- `:line`
- `:level`
- `:path`
- `:todo`
- `:title`
- `:tags`
- `:scheduled`
- `:deadline`
- `:has-children`
- `:child-count`
- `:body-lines`, `:body-chars`
- `:subtree-lines`, `:subtree-chars`

Agenda and TODO queries also include:

- `:agenda-line`

Body-oriented functions include `:body` unless called with `:return-body nil`, or with `:quiet t` where supported.

Subtree-oriented functions include `:subtree` unless called with `:return-subtree nil`.

## Golden-path workflows

### 1. Get a quick overview

```bash
emacsclient --eval '
(oab-summary
 7
 "today"
 t)'
```

Or inspect TODOs directly:

```bash
emacsclient --eval '
(oab-todo-items
 t)'
```

Use `ensure-id` sparingly; it mutates files by adding missing `:ID:` properties.

### 2. Target a non-TODO subtree exactly

Find an exact heading title in a known file:

```bash
emacsclient --eval '
(oab-find-heading-in-file
 "todo.org"
 "qol")'
```

Find an exact path and ensure that heading has an ID:

```bash
emacsclient --eval '
(oab-find-heading-by-path
 "qol/improve org-agenda skill/Plan"
 "todo.org"
 t)'
```

### 3. Build or maintain a structured subtree

Ensure a standard child heading exists under a known parent:

```bash
emacsclient --eval '
(oab-ensure-child-heading-by-path
 "qol/improve org-agenda skill"
 "Plan"
 :file "todo.org")'
```

Replace the body under that heading:

```bash
emacsclient --eval '
(oab-replace-body-by-path
 "qol/improve org-agenda skill/Plan"
 "Learn the exact heading lookup should stay targeted\nChild-heading helpers should be idempotent"
 :file "todo.org")'
```

Append more body content later:

```bash
emacsclient --eval '
(oab-append-body-by-path
 "qol/improve org-agenda skill/Plan"
 "Body editing should preserve child subtrees"
 :file "todo.org")'
```

For large generated body content, write the content to a temporary file and let Emacs read it. The `*-from-file` helpers default to metadata-only results so large checkpoint updates do not echo the full body back to the agent:

```bash
emacsclient --eval '
(oab-replace-body-by-path-from-file
 "qol/improve org-agenda skill/Plan"
 "/tmp/checkpoint-body.org"
 :file "todo.org"
 :return-body nil)'
```

Confirm a large replacement without printing the full body by requesting metadata only:

```bash
emacsclient --eval '
(oab-get-body-by-path
 "qol/improve org-agenda skill/Plan"
 :file "todo.org"
 :return-body nil)'
```

For headings with child subtrees, inspect subtree metadata before deciding whether to read or mutate body content:

```bash
emacsclient --eval '
(oab-get-subtree-by-path
 "qol/improve org-agenda skill/Plan"
 :file "todo.org"
 :return-subtree nil)'
```

When you need the actual subtree text, omit `:return-subtree nil`. Pass `:include-heading nil` to return text below the heading line only.

These body functions edit only the body region directly under the matched heading. They preserve the heading itself, planning lines, drawers, and child subtrees.

### 4. Create new child headings under an existing parent

Always append a fresh child heading:

```bash
emacsclient --eval '
(oab-insert-child-heading-by-path
 "foo"
 "the headline"
 :file "todo.org"
 :todo-state "TODO"
 :tags "bar")'
```

For repeatable structures like `Plan` / `Memory`, prefer `ensure-child-heading-*` instead of `insert-child-heading-*`.

### 5. Capture a top-level TODO task

```bash
emacsclient --eval '
(oab-capture-task
 "Refactor the data loader"
 "+1d"
 "+7d")'
```

If the user wants the new item under an existing subtree, use subtree-authoring helpers or capture first and refile later.

### 6. Mutate a known task by ID

Mark a task `DONE`:

```bash
emacsclient --eval '
(oab-set-todo-id
 "11111111-2222-3333-4444-555555555555"
 "DONE")'
```

Schedule or clear scheduling:

```bash
emacsclient --eval '
(oab-schedule-id
 "11111111-2222-3333-4444-555555555555"
 "+1d")'
```

```bash
emacsclient --eval '
(oab-schedule-id
 "11111111-2222-3333-4444-555555555555"
 nil)'
```

### 7. Archive or refile a known entry

Archive by ID:

```bash
emacsclient --eval '
(oab-archive-id
 "11111111-2222-3333-4444-555555555555")'
```

Refile under another known entry:

```bash
emacsclient --eval '
(oab-refile-id-to-id
 "11111111-2222-3333-4444-555555555555"
 "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")'
```

## Guardrails

- Only use `emacsclient` for Org agenda operations. Never use `emacs` or `emacs --batch`.
- Prefer exact targeting (`ID`, exact path, or exact `file` + `pos`) over fuzzy title matching.
- For repeated subtree-structure workflows like `Plan` / `Memory`, prefer `ensure-child-heading-*` over `insert-child-heading-*` so reruns stay idempotent.
- Confirm destructive actions like archiving, refiling, or broad TODO-state changes unless the user already asked for them.
- Avoid mass rewrites of Org files unless the user explicitly wants bulk maintenance.
- For large generated bodies, prefer `replace-body-*-from-file` / `append-body-*-from-file` with metadata-only results over passing or returning huge strings.
- Use `get-subtree-* :return-subtree nil` to inspect child and size metadata before body edits that might otherwise be confused with subtree rewrites.
- Tag operations are intentionally local-tag operations; they do not remove inherited tags from parent or file-level configuration.

## Limitations and troubleshooting

- `oab-capture-task` still creates top-level headings only.
- Query results are snapshots; rerun the query after mutations if you need fresh state or positions.
- `find-child-heading-*` and `ensure-child-heading-*` operate on direct children of the matched parent.
- Body functions edit only the body directly under the matched heading; they do not rewrite child subtrees.
- Existing body readers and mutators return `:body` by default for compatibility; pass `:return-body nil` or `:quiet t` where supported to omit it.
- Subtree readers return `:subtree` by default; pass `:return-subtree nil` to get metadata only.
- If `org-agenda-files` cannot be found, configure it or create `todo.org` under `org-directory`.
- `oab-set-todo-at` and `oab-set-todo-id` respect the user's Org configuration. If TODO transitions require notes or logging, be prepared for follow-up work.
- `oab-refile-id-to-file` appends the moved subtree as a top-level heading in the destination file.
- If natural-language dates behave oddly in the current Emacs session, prefer ISO dates like `2026-03-12` or Org-relative formats like `+1d`.
- Indirect buffers are useful for focused editing, but they still point at the same underlying Org subtree; edits there affect the source entry.
