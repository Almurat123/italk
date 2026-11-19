---
name: disk-usage-report
description: Find out what is taking disk space on this Mac and suggest safe things to clean up — read-only; never deletes.
version: 1.0.0
platforms: [macos]
tags: [disk, storage]
---

# Disk usage report

## When to use
"Why is my disk full", "what is big", "free up space".

## Procedure
1. Free space: `df -h /` (and `df -h ~` if the home folder is on another volume).
2. Biggest top-level places, one command at a time so each stays quick: `du -sh ~/* 2>/dev/null | sort -rh | head -15`, then `du -sh ~/Library/* 2>/dev/null | sort -rh | head -10`.
3. Known space hogs worth checking by name (report size only if the folder exists): `~/Library/Caches`, `~/Library/Developer/Xcode/DerivedData`, `~/Library/Developer/CoreSimulator`, `~/Library/Containers`, `~/.npm`, `~/.cache`, `~/Downloads`, `~/Library/Application Support/MobileSync/Backup` (iPhone backups), Docker/Ollama model folders.
4. Large single files: `find ~ -type f -size +500M -not -path '*/Library/*' 2>/dev/null | head -20` (use `-exec ls -lh {} +` for sizes).
5. Report: a short ranked list with sizes, what each is, and whether removing it is safe ("caches: safe, apps rebuild them", "iPhone backups: only if you have another backup"). Offer to clean specific items, and wait for the person to choose.

## Pitfalls
- `du` on a huge folder can take minutes; use `timeout_seconds` up to 300 and narrow the path rather than rerunning the same command.
- Never recommend deleting anything under `~/Library/Application Support` apps' data, Photos libraries or Mail without saying what it is.
- Do not delete in this skill. If asked to clean something up afterwards, ask first and list exactly what will be removed.

## Verification
Sizes add up roughly to the `df` used space; the report names the folders it measured.
