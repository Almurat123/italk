---
name: find-documents
description: Find a document on this Mac by name, topic or date (Spotlight), then read and summarize it.
version: 1.0.0
platforms: [macos]
tags: [files, documents, search]
---

# Find and summarize documents

## When to use
"Find the contract I signed in March", "where is the PDF about ...", "summarize that report".

## Procedure
1. Search with Spotlight, which understands content and metadata: `mdfind -onlyin ~ 'kMDItemDisplayName == "*invoice*"c'` for names, `mdfind -onlyin ~ '<words>'` for content, add `kMDItemContentModificationDate >= $time.iso(2026-03-01)` style filters for dates. Limit output with `| head -30`.
2. If Spotlight finds nothing, fall back to `find ~ -iname '*keyword*' -not -path '*/Library/*' 2>/dev/null | head -30`.
3. Rank by recency and by location (Documents/Desktop/Downloads first). If several plausible matches remain, list the top 5 with folder and date and ask with `clarify`.
4. Read the chosen file: text/markdown with `read_file`; PDF with `mdls`/`textutil` is not enough, so try `pdftotext -layout <file> -` when installed, otherwise `strings <file> | head -200` and say the text is approximate; Word/Pages/RTF: `textutil -convert txt -stdout <file>`; spreadsheets: `head` on exported CSV or say that a spreadsheet needs opening.
5. Summarize for a phone: three to six bullets with the facts the person asked about (names, dates, amounts), then the path in backticks. Quote numbers exactly.

## Pitfalls
- Never read files in password managers, keychains, or browser profiles; they are blocked anyway.
- Do not send the content anywhere; summarizing stays in the conversation.
- If the text could not be extracted, say so rather than guessing.

## Verification
The summary only contains facts that appear in the extracted text; the path is the one you read.
