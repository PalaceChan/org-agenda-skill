# AGENTS.md

## Repository purpose

This repo contains an ECA skill for working with Org agenda data in a running Emacs session, plus the supporting Elisp bridge and its ERT regression suite.

## Important files

- `SKILL.md` — skill instructions and documented public API.
- `scripts/eca-org-agenda-bridge.el` — runtime Elisp bridge used by the skill.
- `test/eca-org-agenda-bridge-test.el` — ERT suite for the bridge.
- `test/fixtures/` — golden Org fixtures for formatting-sensitive body-editing tests.

## Current bridge scope

Capture support is via:

- `eca-org-agenda-capture-task`

Fallback agenda-file behavior is limited to:

- `todo.org`

If that scope changes, update **all three** of these together:

1. `scripts/eca-org-agenda-bridge.el`
2. `SKILL.md`
3. `test/eca-org-agenda-bridge-test.el`

## Maintenance rules

- Treat `eca-org-agenda-*` functions documented in `SKILL.md` as the public surface.
- Treat `eca-org-agenda--*` helpers as private implementation details unless there is a strong reason to expose them.
- Preserve exact-targeting semantics (`-id`, `-by-path`, `-at`) unless intentionally redesigning the API.
- Be careful around body-region logic, tag parsing/formatting, and refile/archive behavior; these have dedicated regression coverage because they are easy to break.
- Prefer fixed ISO dates and explicit fixture IDs in tests so results stay deterministic.

## Testing

In this environment, run tests with `emacsclient`:

```bash
emacsclient --eval '
(progn
  (load-file "/path/to/org-agenda-skill/test/eca-org-agenda-bridge-test.el")
  (ert-run-tests-batch "^eca-org-agenda-bridge-test-"))'
```

Notes:

- The suite uses isolated temporary Org workspaces and should not depend on the user's normal Org files.
- The selector `^eca-org-agenda-bridge-test-` is intentional; it avoids unrelated ERT tests from other loaded projects.

## When changing behavior

Prefer this order:

1. Update or add tests.
2. Change bridge code.
3. Update `SKILL.md` examples or API lists if needed.
4. Re-run the ERT suite.

If a change is hard to test semantically, consider adding or adjusting a fixture-based golden regression test.
