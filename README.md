[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

# org-agenda skill

An ECA skill and supporting Elisp bridge for working with a running Org agenda inside Emacs.

## What it provides

- Capture top-level TODO tasks into `todo.org`
- Query agenda and TODO views
- Find Org headings exactly by title or path
- Create and maintain structured child headings such as `Plan`
- Read, replace, and append body content under headings
- Update TODO state, scheduling, deadlines, and tags
- Archive and refile known entries

## Repository layout

- `SKILL.md` — skill definition and usage guidance
- `scripts/eca-org-agenda-bridge.el` — Org bridge functions used by the skill
- `test/eca-org-agenda-bridge-test.el` — ERT regression suite
- `test/fixtures/` — golden Org fixtures for formatting-sensitive tests

## Current scope

The bridge currently supports only task capture:

- `eca-org-agenda-capture-task`

If `org-agenda-files` is unset or empty, the bridge falls back to `todo.org` under `org-directory`.

## Running tests

In an environment with an Emacs server running:

```bash
emacsclient --eval '
(progn
  (load-file "/path/to/org-agenda-skill/test/eca-org-agenda-bridge-test.el")
  (ert-run-tests-batch "^eca-org-agenda-bridge-test-"))'
```

The test selector is intentionally scoped so only this repository's bridge tests run.
