---
name: git-repo-report
description: Summarize the state of a git repository — branch, uncommitted work, recent commits, unpushed changes — without changing anything.
version: 1.0.0
platforms: [macos]
tags: [git, development]
---

# Git repository report

## When to use
"What's the state of this repo", "what did I change", "what's unpushed", "summarize recent work".

## Procedure
1. Make sure it is a repository: `git -C <path> rev-parse --show-toplevel`.
2. State: `git -C <path> status -sb` (branch, ahead/behind, changed files).
3. Uncommitted work: `git -C <path> diff --stat` and `git -C <path> diff --stat --cached`; for the biggest files read the actual diff with `git -C <path> diff -- <file>`.
4. History: `git -C <path> log --oneline -15`, and `git -C <path> log --since='7 days ago' --pretty='%h %an %s' | head -30` for recent activity.
5. Unpushed: `git -C <path> log @{u}..HEAD --oneline` (skip quietly when there is no upstream).
6. Report in this order: where you are, what is uncommitted (by area, not file by file), what is unpushed, what was done recently. Offer next steps (commit message draft, what to review) but do not commit, push, reset or checkout unless asked.

## Pitfalls
- Read-only git subcommands only here (`status`, `diff`, `log`, `show`, `branch`, `remote -v`).
- Large diffs: summarize with `--stat`, then read only the files that matter.

## Verification
Every number in the report (files changed, commits ahead) comes from a command output you saw.
