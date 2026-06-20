# Claude Code Status Line

A shell script that adds a live status bar to [Claude Code](https://claude.ai/code), showing your active model, context window usage, rolling usage windows, estimated session cost, elapsed time, and current workspace — updated automatically after every message.

```
Claude Sonnet 4.6  [████████░░░░░░░░░░░░░░░░] 33%/200k  5h:12  7d:45  ~$0.12  14m22s  GitHub
```

---

## How it works

Claude Code has a built-in `statusLine` hook. When enabled, Claude Code **automatically pipes a JSON payload to this script's stdin** after every API call. The payload contains the current model, token counts, context window size, and the path to the session transcript file.

The script reads that payload **and** scans your local Claude Code transcript files (`~/.claude/projects/**/*.jsonl`) to compute the 5-hour and 7-day usage windows. **No additional API or network calls are made** — everything is derived from what Claude Code already writes to disk.

```
Claude Code  ──(session JSON on stdin)──────────────────────>  statusline.sh
~/.claude/projects/**/*.jsonl  ──(window counts, workspace)──>  statusline.sh
                                                                      │
                                               formatted string ▼
                                                           status bar
```

---

## What it displays

| Field | Example | Description |
|---|---|---|
| **Model** | `Claude Sonnet 4.6` | Active model name from the API payload |
| **Context bar** | `[████████░░░░░░░░]` | Visual fill of context window used |
| **Usage** | `33%/200k` | Percentage used / total context window size |
| **5h** | `5h:12` | Prompts you sent across all projects in the last 5 hours |
| **7d** | `7d:45` | Prompts you sent across all projects in the last 7 days |
| **Cost** | `~$0.12` | Estimated API cost for the current session |
| **Duration** | `14m22s` | Time elapsed since the first message in this session |
| **Workspace** | `GitHub` | Basename of the working directory when this session started |

### About the 5h and 7d windows

Claude Pro has a rolling 5-hour usage limit. The `5h` counter shows how many prompts you have personally sent (across **all** your Claude Code projects) within the last 5 hours, giving you a real-time view of where you stand in that window. The `7d` counter gives the same view over a 7-day period.

These counts come from scanning your local transcript JSONL files. Only your direct top-level messages are counted — tool call relays and subagent turns are excluded.

---

## Prerequisites

### 1. An Anthropic API key

Claude Code authenticates with the Anthropic API using your API key. This is what drives the session data the script reads.

Get one at [console.anthropic.com](https://console.anthropic.com) → **API Keys** → **Create Key**.

Set it in your shell environment — add to your `~/.bashrc`, `~/.zshrc`, or Windows user environment variables:

```sh
export ANTHROPIC_API_KEY="sk-ant-..."
```

Or configure it when you first launch Claude Code — it will prompt you for the key on first run.

> **Never hardcode your API key inside this script or commit it to a repository.**
> The script does not use the key directly — it only reads local data that Claude Code provides.

### 2. jq

A lightweight command-line JSON processor used to parse the status line payload.

| Platform | Command |
|---|---|
| **Linux (apt)** | `sudo apt install jq` |
| **Linux (dnf)** | `sudo dnf install jq` |
| **macOS (Homebrew)** | `brew install jq` |
| **Windows (WinGet)** | `winget install jqlang.jq` |
| **Windows (Scoop)** | `scoop install jq` |
| **Windows (Chocolatey)** | `choco install jq` |

The script auto-detects `jq` installed via WinGet or Scoop on Windows, so no path configuration is needed.

### 3. Shell (Windows only)

On Windows, Claude Code's `statusLine` command runs via **Git Bash** (the `sh` that ships with [Git for Windows](https://git-scm.com/download/win)). The script relies on standard POSIX tools (`awk`, `find`, `grep`, `date`, `head`) that are all included in Git Bash.

---

## Installation

### Step 1 — Download the script

```sh
# Clone the repo
git clone https://github.com/YOUR_USERNAME/claude-statusline.git

# Or download just the script
curl -L -o statusline.sh \
  https://raw.githubusercontent.com/YOUR_USERNAME/claude-statusline/main/statusline.sh
chmod +x statusline.sh
```

Place it somewhere permanent:

| Platform | Suggested path |
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

## Customisation

### Adjust cost pricing

The default rates match the **Claude Sonnet 4** family. Edit these two lines in `statusline.sh`:

```sh
PRICE_IN=3.0    # USD per million input tokens
PRICE_OUT=15.0  # USD per million output tokens
```

Current Anthropic pricing: [anthropic.com/pricing](https://www.anthropic.com/pricing)

| Model | Input (per M tokens) | Output (per M tokens) |
|---|---|---|
| Claude Opus 4 | $15.00 | $75.00 |
| Claude Sonnet 4 | $3.00 | $15.00 |
| Claude Haiku 4 | $0.80 | $4.00 |

### Change bar width

Find `BAR_WIDTH=24` and set any value:

```sh
BAR_WIDTH=32   # wider bar
BAR_WIDTH=16   # compact bar
```

---

## How the transcript files are read

Claude Code writes one JSONL file per session to `~/.claude/projects/<project-slug>/`. Each line in the file is a JSON object representing one event in the conversation. For example, a user prompt looks like this:

```json
{
  "type": "user",
  "parentUuid": null,
  "timestamp": "2026-06-20T10:30:00.000Z",
  "cwd": "/home/user/my-project",
  "message": { "role": "user", "content": "Hello Claude" },
  "sessionId": "abc123"
}
```

The script uses these fields as follows:

| Field | Used for |
|---|---|
| `type` | Identifying user prompts (`"user"`) vs other events |
| `parentUuid` | Filtering to top-level prompts only (`null` = root turn, not a tool relay) |
| `timestamp` | Window cutoff comparisons (ISO 8601 strings sort lexicographically) |
| `cwd` | Extracting the current workspace name |

The `5h` and `7d` counts are computed by scanning all non-subagent JSONL files modified in the last 7 days across the entire `projects/` directory, then filtering by timestamp per line.

---

## How the session JSON payload looks

Claude Code sends a payload like this to the script's stdin after each turn:

```json
{
  "model": {
    "display_name": "Claude Sonnet 4.6"
  },
  "context_window": {
    "used_percentage": 33.1,
    "context_window_size": 200000,
    "total_input_tokens": 45200,
    "total_output_tokens": 3100
  },
  "transcript_path": "/home/user/.claude/projects/my-project/session.jsonl"
}
```

---

## Troubleshooting

**`statusline.sh: jq not found`**
Install jq (see Prerequisites). On Windows, confirm the command in `settings.json` starts with `sh` (Git Bash), not `powershell`.

**No status bar appears at all**
- Confirm the path in `settings.json` uses forward slashes and is absolute.
- On Linux/macOS, run `chmod +x statusline.sh`.
- Test the script manually: `echo '{}' | sh statusline.sh` — it should print a line without errors.

**5h / 7d counts are always 0**
The script looks for JSONL files in the directory two levels above `transcript_path`. If your Claude Code transcript directory is in a non-standard location, open the script and verify that `projects_root` resolves correctly by logging it: add `echo "root: $projects_root" >&2` temporarily after it is set.

**Duration shows `0m00s`**
macOS ships with BSD `date`, which does not support the `-d` flag. Install GNU coreutils (`brew install coreutils`) then replace every `date` call in the script with `gdate`.

**Workspace shows as empty**
The workspace is read from the `cwd` field of the first `"type":"user"` entry in the current session's transcript. This is populated after the first message is sent. If it remains empty, check that the transcript file exists and is not empty.

**Cost always shows `~$0.00`**
This is expected at the start of a session. The display switches to a real dollar value once usage crosses $0.01.

**API key errors in Claude Code**
This script does not handle API authentication — that is entirely managed by Claude Code. If you see API key errors, set `ANTHROPIC_API_KEY` in your shell environment or run `claude` and follow the first-run setup prompts.

---

## Security

- **Never hardcode your API key** in this script or any file you commit to a repository.
- The script reads only local files written by Claude Code — it makes no outbound network requests of any kind.
- Your transcript files stay entirely on your local machine.

---

## License

MIT — see [LICENSE](LICENSE).
