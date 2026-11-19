---
name: organize-folder
description: Tidy a messy folder (Downloads, Desktop, a project dump) safely — survey, propose a plan, move only after approval, never delete.
version: 1.0.0
platforms: [macos]
tags: [files, cleanup]
---

# Organize a folder

## When to use
The person asks to clean up, sort or organize a folder, or to find out what is in it before deciding.

## Procedure
1. Survey without changing anything: `ls -la <folder>`, then group by kind with `find <folder> -maxdepth 1 -type f` and `file`/extension counts. Note total size with `du -sh`.
2. Look for the person's own structure first (existing subfolders, a README, naming habits) and extend it instead of inventing a new one.
3. Write a plan with `todo`, then show the person a short table of proposed moves: *file or pattern → destination*, plus a count. Do not move anything yet when the folder has more than ~20 files; ask with `clarify` ("Move these 124 files into 6 folders?") with choices.
4. After the go-ahead, move with `mv -n` (never overwrite) in batches by category; create destination folders with `mkdir -p`.
5. Verify: list the folder again and report what moved where, what stayed, and anything skipped.

## Pitfalls
- Never delete. Offer a "Review later" folder for things that look like duplicates or installers instead.
- Files modified in the last 24 hours, anything inside `.git`, `node_modules`, app bundles (`*.app`) and sync folders stay where they are.
- Names with spaces: quote every path.

## Verification
`ls` of the folder and of each destination shows the expected counts; nothing was removed.
