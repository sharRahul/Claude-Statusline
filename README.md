# Claude Code Status Line

A shell script that adds a live status bar to [Claude Code](https://claude.ai/code), showing your active model, session cost, context window usage, Claude.ai rolling usage percentages, session duration, current folder, git branch with sync status, and Claude infrastructure health — updated automatically after every message.

```
Sonnet 4.6 [Low] | $0.042 | ████░░░░░░ 37% 74K/200K | 5h:12% ↺ 2h 14m | 7d:45% ↺ 3d 6h | 1h 23m | my-project (main* ↑2↓1)
```

---

## How it works

Claude Code has a built-in `statusLine` hook. When enabled, Claude Code **automatically pipes a JSON payload to this script's stdin** after every API call. The payload contains the current model, effort level, session ID, transcript path, and working directory.

The script reads that payload and:

1. Parses the transcript file at `transcript_path` to count used tokens, compute session cost, and derive session duration.
2. Reads `~/.claude/usage_cache.json` for your Claude.ai 5-hour and 7-day utilization percentages.
3. Triggers a background refresh of that cache (via `~/.claude/refresh_usage.sh`) if it is older than 5 minutes.
4. Detects the git branch, dirty state, and ahead/behind remote sync count of the current working directory.
5. Polls `status.claude.com` every 10 minutes for Claude infrastructure health, only showing an indicator when there is an active incident.

Background refreshes are file-locked so only one process runs at a time, even when multiple terminal windows are open.

```
Claude Code  ──(session JSON on stdin)──────────────>  statusline.sh
transcript file  ──(tokens, timestamps)─────────────>  statusline.sh
~/.claude/usage_cache.json  ──(5h/7d utilization)──>  statusline.sh
git repo  ──(branch, dirty, ahead/behind)──────────>  statusline.sh
status.claude.com  ──(infrastructure health)────────>  statusline.sh
                                                             │
                                          formatted string  ▼
                                                      status bar
```

---

## What it displays

| Segment | Example | Description |
|---|---|---|
| **Model** | `Sonnet 4.6` | Active model, color-coded (purple = Opus, blue = Sonnet, green = Haiku) |
| **Effort** | `[Low]` | Effort level from the session payload or `~/.claude/settings.json`; omitted if not set |
| **Session cost** | `$0.042` | Cumulative cost of the current session in USD, computed from transcript token counts and model pricing; omitted when zero |
| **Context bar** | `████░░░░░░` | Visual fill of context window consumed; color turns bright yellow ≥40%, yellow ≥60%, red ≥80% |
| **Context %** | `37%` | Percentage of context window used |
| **Used / Limit** | `74K/200K` | Tokens consumed and total window size (switches to `1M` if `exceeds_200k` is set) |
| **5h utilization** | `5h:12%` | Your Claude.ai rolling 5-hour usage limit, as a percentage |
| **5h reset** | `↺ 2h 14m` | Time until the 5-hour window resets |
| **7d utilization** | `7d:45%` | Your Claude.ai rolling 7-day usage limit, as a percentage |
| **7d reset** | `↺ 3d 6h` | Time until the 7-day window resets |
| **Session duration** | `1h 23m` | How long the current session has been running, derived from the first transcript timestamp |
| **Folder** | `my-project` | Basename of the current working directory |
| **Git branch** | `(main*)` | Current git branch; `*` suffix means uncommitted changes exist; omitted if not in a git repo |
| **Ahead/behind** | `↑2↓1` | Commits ahead (green ↑) or behind (red ↓) the remote tracking branch; omitted when in sync or no upstream |
| **Claude status** | `⚠` / `✗` | Infrastructure incident indicator from status.claude.com; only shown when there is an active incident |

### Color coding

Utilization segments (context bar, 5h, 7d) are colored based on percentage:

| Range | Color |
|---|---|
| < 40% | Green |
| 40–59% | Bright yellow |
| 60–79% | Yellow |
| ≥ 80% | Red |

Git branch is shown in cyan when clean, bright yellow when dirty (`*`). Ahead commits are green, behind commits are red. The Claude status indicator is yellow for minor incidents, red for major/critical.

---

## Prerequisites

### 1. jq

A lightweight command-line JSON processor used to parse the status line payload.

| Platform | Command |
|---|---|
| **Linux (apt)** | `sudo apt install jq` |
| **Linux (dnf)** | `sudo dnf install jq` |
| **macOS (Homebrew)** | `brew install jq` |
| **Windows (WinGet)** | `winget install jqlang.jq` |
| **Windows (Scoop)** | `scoop install jq` |
| **Windows (Chocolatey)** | `choco install jq` |

### 2. curl

Required by `refresh_usage.sh` to fetch your Claude.ai usage data. Usually pre-installed on Linux and macOS. On Windows, Git Bash ships with curl.

### 3. git

Required for git branch, dirty-state, and ahead/behind detection. Usually pre-installed everywhere. On Windows, Git Bash includes it automatically.

### 4. Shell (Windows only)

On Windows, Claude Code's `statusLine` command runs via **Git Bash** (the `sh` that ships with [Git for Windows](https://git-scm.com/download/win)). All POSIX tools the script needs (`awk`, `date`, `stat`, `basename`, `git`) are included in Git Bash.

### 5. refresh_usage.sh (optional — 5h/7d data)

The 5h and 7d utilization fields are read from `~/.claude/usage_cache.json`. The script refreshes this cache automatically via one of two paths — no manual setup is required for either:

- **If `~/.claude/refresh_usage.sh` exists** — the script calls it in the background when the cache is older than 5 minutes. Use this path if you have a custom refresh script (e.g. one that uses a Claude.ai session cookie).
- **If `refresh_usage.sh` is absent** — the script falls back to reading the OAuth access token that Claude Code stores automatically in `~/.claude/.credentials.json` and calls `https://api.anthropic.com/api/oauth/usage` directly. This works out of the box with no extra configuration as long as you are logged in to Claude Code.

If neither path produces data the 5h and 7d segments display `-`.

---

## Installation

### Step 1 — Download the script

```sh
# Clone the repo
git clone https://github.com/rahulsharma2196/claude-statusline.git

# Or download just the script
curl -L -o ~/.claude/statusline.sh \
  https://raw.githubusercontent.com/rahulsharma2196/claude-statusline/main/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Suggested installation path:

| Platform | Path |
|---|---|
| Linux / macOS | `~/.claude/statusline.sh` |
| Windows | `C:/Users/YourName/.claude/statusline.sh` |

### Step 2 — Configure Claude Code

Open (or create) your Claude Code **settings file**:

| Scope | Path |
|---|---|
| Global (all projects) | `~/.claude/settings.json` |
| Project-only | `.claude/settings.json` inside your project |

Add the `statusLine` block:

**Linux / macOS**
```json
{
  "statusLine": {
    "type": "command",
    "command": "sh /home/YOUR_USERNAME/.claude/statusline.sh"
  }
}
```

**Windows (use forward slashes in the path)**
```json
{
  "statusLine": {
    "type": "command",
    "command": "sh C:/Users/YOUR_USERNAME/.claude/statusline.sh"
  }
}
```

If `settings.json` already has other content, add `statusLine` as a new key alongside the existing ones.

### Step 3 — Restart Claude Code

Close and reopen Claude Code. Start a conversation — the status bar appears at the bottom of your terminal after the first response.

---

## How the session JSON payload looks

Claude Code sends a payload like this to the script's stdin after each turn:

```json
{
  "model": "claude-sonnet-4-6",
  "effort": { "level": "low" },
  "session_id": "abc12345-...",
  "transcript_path": "/home/user/.claude/projects/my-project/session.jsonl",
  "cwd": "/home/user/my-project",
  "exceeds_200k_tokens": false
}
```

The `model` field may also be an object with a `display_name`, `name`, or `id` key — the script handles both forms.

---

## How the usage cache is structured

`~/.claude/usage_cache.json` must contain:

```json
{
  "five_hour": {
    "utilization": 12.4,
    "resets_at": "2026-06-20T15:30:00Z"
  },
  "seven_day": {
    "utilization": 45.1,
    "resets_at": "2026-06-27T00:00:00Z"
  }
}
```

`utilization` is a number between 0 and 100. `resets_at` is an ISO 8601 timestamp. The script displays a countdown to reset derived from this timestamp.

---

## Troubleshooting

**No status bar appears at all**
- Confirm the path in `settings.json` uses forward slashes and is absolute.
- On Linux/macOS, run `chmod +x ~/.claude/statusline.sh`.
- Test the script manually: `echo '{}' | sh ~/.claude/statusline.sh` — it should print a line without errors.

**`jq: command not found`**
Install jq (see Prerequisites). On Windows, confirm the `statusLine` command starts with `sh` (Git Bash), not `powershell`.

**5h / 7d always show `-`**
The usage data comes from `~/.claude/usage_cache.json`. The script refreshes it automatically — first via `~/.claude/refresh_usage.sh` if present, otherwise via the OAuth token in `~/.claude/.credentials.json`. If both are absent the segments stay at `-`. Confirm you are logged in to Claude Code (`claude auth status`) so the credentials file exists.

**Context bar always shows 0%**
The script reads token counts from the transcript file at `transcript_path`. Verify that `transcript_path` is present in the stdin payload (`echo '{}' | sh statusline.sh` uses an empty payload and will show 0%). After sending at least one message the real payload will contain the path.

**Session duration shows `-`**
The duration is derived from the first `.timestamp` field in the transcript file. If the transcript is missing or has no timestamps, it falls back to `-`.

**Git branch not showing**
The script runs `git -C <cwd> symbolic-ref --short HEAD`. If the working directory is not inside a git repository, no branch is shown — this is expected. If you are in a git repo and it still doesn't appear, ensure `git` is on the `PATH` available to your shell.

**Countdown shows garbled output on macOS**
macOS ships with BSD `date`, which does not support the `-d` flag. Install GNU coreutils (`brew install coreutils`) and ensure `gdate` is on your `PATH`, or create an alias `date=gdate`.

**Effort level not showing**
Effort is read from the session payload's `.effort.level` field, or falls back to `.effortLevel` in `~/.claude/settings.json`. If neither is set, the effort label is omitted.

**Session cost shows `$0.000` or nothing**
Cost is computed from each API call's token usage in the transcript file. If the transcript has no usage data yet (e.g. the very first turn), the cost segment is hidden. Cost uses approximate per-model pricing: Opus $15/$75, Sonnet $3/$15, Haiku $0.80/$4 per million input/output tokens.

**Ahead/behind not showing**
The `↑`/`↓` counts require a remote tracking branch (`git branch --set-upstream-to=origin/main main`). If the current branch has no upstream configured, the sync indicators are omitted — this is expected.

**Claude status indicator not appearing**
The indicator is only shown during an active incident — silence means all systems operational. The status is cached in `~/.claude/claude_status_cache.json` and refreshed every 10 minutes via a background `curl` call. If curl is unavailable or the endpoint is unreachable, the indicator is simply omitted.

**Colors appearing in output that doesn't support them**
Set the `NO_COLOR` environment variable before running Claude Code and the script will strip all ANSI color codes from its output.

---

## Security

- **Never hardcode credentials** inside this script or any file you commit to a repository.
- The script reads only local files written by Claude Code and `~/.claude/usage_cache.json` — it makes no outbound network requests directly.
- Your transcript files stay entirely on your local machine.

---

## License

MIT — see [LICENSE](LICENSE).
