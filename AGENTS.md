# Agent rules for iTalk (Claude and Codex)

## Build output and disk (owner rule, 2026-10-30)
The Mac ran out of disk because every task built into its own derived-data tree (`build/Physical`, `build/QA`,
`build/Device`, `build/AvatarTransitionQA`, scratchpad `dd-phone`, ...; each ~3-5 GB with its own 1 GB copy of the Swift packages).

- One derived-data folder per agent, reused for every build (device, simulator and tests share it):
  - Codex: `-derivedDataPath build/dd-codex`
  - Claude: `-derivedDataPath build/dd-claude`
  - The owner's Xcode app keeps Xcode's default `~/Library/Developer/Xcode/DerivedData/iTalk-*`.
- Do not create new derived-data trees per task, branch or QA pass, and never put one in a temp/scratchpad folder.
  If a second parallel build is unavoidable, use `build/dd-<agent>-2` and delete it when the build is done.
- Test results: `-resultBundlePath build/results/<name>.xcresult`. Cite the ones that matter in `docs/` or `WORK_COORDINATION.md`;
  uncited result bundles and screen recordings older than 7 days may be removed.
- Simulators: reuse `iTalk QA iOS 26` and `iTalk QA iOS 27`. Do not create new simulators; if one is unavoidable, name it
  `TEMP <task> <date>`, shut it down when done and delete it with `xcrun simctl delete <udid>`.
- Models: the iPhone downloads its own models. Mac-side test models are cached once (e.g. `~/Library/Caches/qwen3-speech`); reuse
  the cache, do not download model weights into the repo, `build/` or a scratchpad.
- Never delete another agent's derived-data folder, result bundles or simulator while it is in use.
- Check `df -h /` before large builds; keep at least 20 GiB free.
