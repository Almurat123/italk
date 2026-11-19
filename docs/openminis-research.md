# OpenMinis research

Reviewed 2026-11-02: [OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis), commit `1a71df0f381cefde80bf912b723de6f9831bc177`, GPL-3.0. iTalk does not copy or embed that project's source.

- `src/ios/Agent/Chat/ChatStore+Search.swift` searches user-visible content rather than opaque message metadata, with bounded query terms and literal wildcard handling. iTalk's remote `sessions_search` independently searches task prompts and streamed answer text; it avoids tool arguments and internal reasoning. Its retention, approval and phone isolation are iTalk-specific.
- `src/ios/Agent/Chat/AIChatViewModel+MemoryTools.swift` gates memory reads and writes when memory is disabled and instructs the model to treat old memories as context rather than standing instructions. iTalk already has an on-device memory switch; remote sharing is not implemented and is not enabled by session search.
- `src/ios/Agent/Chat/AIChatViewModel+ToolPreflight.swift` checks model tool arguments and includes repair strategies. Do not auto-repair arguments for destructive iTalk actions: the current strict validation and approval must continue to apply to the actual request.
- `src/ios/Agent/BrowserUse/BrowserUseManager.swift` uses an in-app `WKWebView`, reports navigation errors and places explicit timeouts on JavaScript operations. This is useful reference for a future on-phone browser, but it is not a remote-computer browser or an encrypted relay.

This is source-level research, not evidence that the two projects have equivalent runtime behavior. GPL obligations and dependency licensing must be evaluated before any future direct reuse or distribution.
