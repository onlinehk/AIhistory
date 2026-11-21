# AIhistory

A native macOS app (SwiftUI) for browsing your local AI coding history: **Claude Code** and **Codex**.

It reads:

- Claude Code: `~/.claude/projects/*/*.jsonl`
- Codex: plain `.jsonl` and compressed `.jsonl.zst` rollouts in `~/.codex/sessions/` and `archived_sessions/`, with titles from `session_index.jsonl`. Compressed history requires `zstd` (`brew install zstd`).

## Features

- **Split by source**: each record's `entrypoint` field tells you which client a session came from
  - `cli` → 終端機 CLI
  - `claude-vscode` → VS Code (also Cursor / Windsurf forks)
  - `claude-desktop` → Claude Desktop (Code tab)
  - JetBrains / Agent SDK / other, which appear only when you have sessions from them
- **Codex** uses `session_meta.originator`:
  - `codex_cli_rs` / `codex_exec` → 終端機 CLI
  - `codex_vscode` → VS Code
  - `Codex Desktop` → Codex App
  - `codex_sdk_*` → Codex SDK
  - Codex's auto-review (guardian) sub-sessions are hidden, like Claude's sidechains
- Filter by project, search titles and everything you typed (⌘F)
- Grouped by time: 今日 / 昨日 / 過去 7 日 / by month
- Full transcript: your messages, Claude's replies (Markdown), tool calls (expand to see input and result), thinking (off by default)
- Session info: project path, git branch, model, cost, Claude Code version
- Copy a `claude --resume <id>` command, copy as Markdown, show the .jsonl in Finder
- **Stats** (shown on the right when no conversation is selected, or via toolbar 📊 / ⇧⌘S): follows the current source, project and search filters
  - Summary cards: estimated cost, tokens, cache hit rate, conversation count, average per conversation / per prompt
  - Token breakdown (uncached input, cache read, cache write, output), daily chart (cost or tokens, split by Claude / Codex), tables by model and by source, top projects, most expensive conversations; 7 / 30 / 90 days / all time
  - **Claude and Codex costs use API list prices**. Claude counts each reply's `usage`, including sub-agent usage and both cache write durations. Codex counts the change in each `token_count` running total, prices applicable long-context requests at the higher rate, and folds auto-review usage into the parent conversation. Cached input is part of total input, and reasoning is part of output.
  - Prices: Settings (⌘,) → 價錢表, editable; models without a price (e.g. `codex-auto-review`) show 「未定價」 and aren't counted in the cost
  - Claude Code's own `cost-state` only covers the latest app launch (earlier usage from resumed / reopened conversations isn't included), so this app recounts from the transcripts instead
  - If you're on a subscription (Claude Pro / Max, ChatGPT Plus / Pro), the cost is only an API-equivalent estimate for comparison, not what you actually pay
- **OpenRouter**: click OpenRouter in the sidebar or **詳細統計與計費** in Stats. In Settings (⌘,) → OpenRouter, configure one or both keys. Each is stored separately in the macOS Keychain.
  - **All Sources** shows the account's lifetime charges and balance when available, plus 30-day and today totals across the Activity scope of the Management key. These OpenRouter periods are independent of the Claude and Codex date filters.
  - A regular API key shows its lifetime, today, week and month spend, limit and BYOK estimates. The Stats page plots differences between local snapshots.
  - A [Management key](https://openrouter.ai/settings/management-keys) shows OpenRouter charges, estimated BYOK provider costs, requests, tokens and cache hit rate by model, provider and day for the last 7 or 30 UTC days, including today. If Analytics is unavailable, the app reports the issue and shows completed UTC days from the Activity API. A read-only account-level key with credits access also shows credits purchased, used and remaining. Activity covers the key’s permitted account or workspace scope and does not follow the Claude/Codex filters.
  - The details window can look up the billed cost and usage of a request by its generation ID with a key that has access to it. It links to OpenRouter Logs for the request list.
- **Attachments**: images you pasted and tool screenshots appear as thumbnails; files referenced by path appear as chips
  - Click a thumbnail to open it in the default app; hover and click ⬇︎ (or right-click → 另存為…) to save it
  - Files Claude / Codex generated and linked in a reply (e.g. `[PDF 版](/path/quote.pdf)`) are clickable and open with the default app; relative links like `app/Foo.php:48` resolve against the project folder. Documents, images and archives also appear as chips under the reply
  - ⋯ → 「下載所有附件」 saves every attachment in a conversation into a folder named after the conversation
  - Images are embedded in the history as base64, so they can be saved even after the original is deleted. Files that are only referenced by path (e.g. Codex's "Files mentioned") can only be opened if the original still exists; otherwise they show 「已不存在」
- **Delete**: right-click → 移去垃圾桶, the Delete key, or the toolbar 🗑 (⌘⌫); select several with ⌘/⇧-click. Moves the `.jsonl` together with its `<id>/` folder (tool-results, subagents), `file-history/<id>` and `session-env/<id>` **to the Trash**, so you can restore it from Finder. Asks first, and warns if a session was updated in the last 2 minutes (it may still be open)
- Refreshes automatically when you switch back to the app; ⌘R to refresh manually. Unchanged files aren't re-parsed.

> Chat history from Claude Desktop's regular chat (not the Code tab) is stored in the cloud, not in local files, so it isn't shown here.

## Build

```bash
./scripts/build-app.sh
open "build/AIhistory.app"
```

Needs Xcode Command Line Tools (Swift 5.10+) and macOS 14+. To install it, drag `build/AIhistory.app` into `/Applications`.

Development: `swift run`. Debugging the parser: `.build/release/AIhistory --dump`.

If `CLAUDE_CONFIG_DIR` is set, the app reads `$CLAUDE_CONFIG_DIR/projects`; if `CODEX_HOME` is set, it reads Codex data from there.

Deleting a Codex session moves only its rollout file to the Trash. The Codex App keeps its own database, so its sidebar may still list the thread.
