# Agent Instructions

Follow the parent `../AGENTS.md` worklog policy strictly.

For this repository:

- Do not recreate `docs/worklog/` for agent worklogs.
- Do not add NEW `.org`, `.md`, or `.txt` worklog handoff files to the repo.
  Grandfathered exceptions are `FINDINGS.md`, `build-notes-p1.md`,
  `build-notes-p2.md`, `build-notes-p3ab.md`, `build-notes-p3c.md`,
  `build-notes-p4b.md`, and `build-notes-p4c.md`.
- Record nelisp work through `anvil-worklog` only, and verify searchability before deleting any migrated file-based log.
- When MCP worklog tools are not available, use the local `nelisp` command
  (`./target/nelisp` from this repo, or an explicit `NELISP` path) for
  worklog add/search operations.  Do not use `emacsclient` as the fallback
  command path for nelisp work.
