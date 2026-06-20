#!/bin/sh
# =============================================================================
# Claude Code Status Line
# =============================================================================
# Hooks into Claude Code's built-in statusLine feature.
#
# HOW IT WORKS
#   Claude Code authenticates with the Anthropic API using your ANTHROPIC_API_KEY.
#   After every API call, Claude Code automatically pipes a JSON payload to this
#   script's stdin containing the current model, token counts, context window
#   size, and the path to the session transcript file.
#   This script parses that payload and reads your local Claude Code transcript
#   files to compute usage windows and workspace — no additional API or network
#   calls are made.
#
#   Data flow:  Claude Code  ──(session JSON on stdin)──>  statusline.sh
#               ~/.claude/projects/**/*.jsonl  ──(window counts)──>  statusline.sh
#                                                               │
#                                              formatted string ▼
#                                                          status bar
#
#   Never put your API key inside this script or commit it to a repository.
#
# OUTPUT EXAMPLE
#   Claude Sonnet 4.6  [████████░░░░░░░░░░░░░░░░] 33%/200k  5h:12  7d:45  ~$0.12  14m22s  GitHub
#
# FIELDS
#   Model       — active model name from the API payload
#   Context     — progress bar of context window used + percentage + total size
#   5h          — number of prompts you have sent across all projects in the
#                 last 5 hours (mirrors Claude Pro's rolling usage window)
#   7d          — same count over the last 7 days
#   Cost        — estimated API cost for the current session (input + output tokens)
#   Duration    — time elapsed since the first message in this session
#   Workspace   — basename of the working directory when this session was started
#
# SETUP
#   1. Set your Anthropic API key in your shell environment:
#        export ANTHROPIC_API_KEY="sk-ant-..."
#
#   2. Add the statusLine block to your Claude Code settings.json:
#        "statusLine": {
#          "type": "command",
#          "command": "sh /path/to/statusline.sh"
#        }
#
#   3. Restart Claude Code — the status bar appears after the first response.
# =============================================================================

# ---------------------------------------------------------------------------
# Locate jq — tries PATH first, then common install locations
# ---------------------------------------------------------------------------
_find_jq() {
  command -v jq >/dev/null 2>&1 && echo "jq" && return

  # Linux / macOS
  for p in /usr/bin/jq /usr/local/bin/jq /opt/homebrew/bin/jq; do
    [ -x "$p" ] && echo "$p" && return
  done

  # Windows — WinGet (Git Bash)
  if [ -n "$USERNAME" ]; then
    winget_base="/c/Users/$USERNAME/AppData/Local/Microsoft/WinGet/Packages"
    jq_win=$(find "$winget_base" -name "jq.exe" 2>/dev/null | head -1)
    [ -n "$jq_win" ] && echo "$jq_win" && return
  fi

  # Windows — Scoop (Git Bash)
  if [ -n "$USERPROFILE" ]; then
    scoop_jq=$(cygpath -u "$USERPROFILE" 2>/dev/null)/scoop/apps/jq/current/jq.exe
    [ -f "$scoop_jq" ] && echo "$scoop_jq" && return
  fi

  echo ""
}

JQ=$(_find_jq)
if [ -z "$JQ" ]; then
  printf "statusline.sh: jq not found — install jq and make sure it is on PATH\n"
  exit 1
fi

# ---------------------------------------------------------------------------
# Read the JSON payload that Claude Code sends on stdin
# ---------------------------------------------------------------------------
input=$(cat)

# ---------------------------------------------------------------------------
# Model name
# ---------------------------------------------------------------------------
model=$(echo "$input" | "$JQ" -r '.model.display_name // "Claude"')

# ---------------------------------------------------------------------------
# Context window
# ---------------------------------------------------------------------------
used_pct=$(echo "$input" | "$JQ" -r '.context_window.used_percentage     // empty')
ctx_size=$(echo "$input" | "$JQ" -r '.context_window.context_window_size  // empty')
in_tok=$(echo "$input"   | "$JQ" -r '.context_window.total_input_tokens   // empty')
out_tok=$(echo "$input"  | "$JQ" -r '.context_window.total_output_tokens  // empty')

# Format context window size as K  (200000 → "200k")
ctx_label=""
if [ -n "$ctx_size" ]; then
  ctx_label=$(echo "$ctx_size" | awk '{ printf "%dk", $1/1000 }')
fi

# Block-character progress bar (24 chars wide)
BAR_WIDTH=24
if [ -n "$used_pct" ]; then
  bar=$(echo "$used_pct $BAR_WIDTH" | awk '{
    filled = int(($1/100)*$2 + 0.5)
    empty  = $2 - filled
    bar    = ""
    for (i = 0; i < filled; i++) bar = bar "\xe2\x96\x88"
    for (i = 0; i < empty;  i++) bar = bar "\xe2\x96\x91"
    printf "%s", bar
  }')
  ctx_str=$(printf "[%s] %.0f%%" "$bar" "$used_pct")
  [ -n "$ctx_label" ] && ctx_str="$ctx_str/${ctx_label}"
else
  bar=$(awk -v w="$BAR_WIDTH" 'BEGIN { for (i=0;i<w;i++) printf "\xe2\x96\x91"; print "" }')
  ctx_str="[$bar]"
  [ -n "$ctx_label" ] && ctx_str="$ctx_str/${ctx_label}"
fi

# ---------------------------------------------------------------------------
# Transcript path — shared by duration, window counts, and workspace
# ---------------------------------------------------------------------------
transcript=$(echo "$input" | "$JQ" -r '.transcript_path // empty')

# ---------------------------------------------------------------------------
# Estimated session cost (USD)
# Default pricing: Claude Sonnet 4 family — $3.00/M input, $15.00/M output.
# See https://www.anthropic.com/pricing and adjust the two variables below.
# ---------------------------------------------------------------------------
PRICE_IN=3.0    # USD per million input tokens
PRICE_OUT=15.0  # USD per million output tokens

cost_str=""
if [ -n "$in_tok" ] && [ -n "$out_tok" ]; then
  cost_str=$(echo "$in_tok $out_tok $PRICE_IN $PRICE_OUT" | awk '{
    cost = ($1 * $3 + $2 * $4) / 1000000
    if (cost < 0.01) printf "~$0.00"
    else             printf "~$%.2f", cost
  }')
fi

# ---------------------------------------------------------------------------
# Session duration
# Reads the ISO 8601 timestamp from the first line of the session's JSONL
# transcript file — this is the true session start regardless of how many
# other transcript files exist in the project directory.
# ---------------------------------------------------------------------------
duration_str=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  first_line=$(head -1 "$transcript" 2>/dev/null)
  start_iso=$(echo "$first_line" | "$JQ" -r '.timestamp // empty' 2>/dev/null)
  now=$(date +%s 2>/dev/null)
  if [ -n "$start_iso" ] && [ -n "$now" ]; then
    # date -d supports ISO 8601 on Linux and Git Bash on Windows.
    # macOS users: install GNU coreutils (brew install coreutils) and replace
    # date with gdate throughout this script.
    start_epoch=$(date -d "$start_iso" +%s 2>/dev/null)
    if [ -n "$start_epoch" ]; then
      elapsed=$(( now - start_epoch ))
      [ "$elapsed" -lt 0 ] && elapsed=0
      h=$(( elapsed / 3600 ))
      m=$(( (elapsed % 3600) / 60 ))
      s=$(( elapsed % 60 ))
      if [ "$h" -gt 0 ]; then
        duration_str=$(printf "%dh%02dm" "$h" "$m")
      else
        duration_str=$(printf "%dm%02ds" "$m" "$s")
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5-hour and 7-day usage windows
#
# Counts the number of prompts you personally sent (type=user, parentUuid=null)
# across ALL your Claude Code projects in the last 5 hours and 7 days.
# Subagent transcripts are excluded so only your direct messages are counted.
#
# This mirrors Claude Pro's rolling 5-hour usage window and gives a 7-day
# view of your overall activity — all read from local transcript files.
# ---------------------------------------------------------------------------
window_5h=""
window_7d=""
if [ -n "$transcript" ]; then
  # Navigate up two levels: session.jsonl → project-dir → projects-root
  projects_root=$(dirname "$(dirname "$transcript")")
  now_epoch=$(date +%s 2>/dev/null)

  if [ -n "$now_epoch" ] && [ -d "$projects_root" ]; then
    # Compute ISO 8601 cutoff timestamps (UTC) for string comparison
    five_h_cutoff=$(date -d "@$(( now_epoch - 18000 ))"  -u "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)
    seven_d_cutoff=$(date -d "@$(( now_epoch - 604800 ))" -u "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)

    if [ -n "$five_h_cutoff" ] && [ -n "$seven_d_cutoff" ]; then
      # Scan all non-subagent JSONL files modified in the last 7 days.
      # Each matching line is a direct user prompt (parentUuid:null = root turn,
      # not a tool-result relay). Timestamps are ISO 8601 UTC and sort
      # lexicographically, so >= string comparison gives the correct cutoff.
      raw_counts=$(find "$projects_root" -name "*.jsonl" \
        -not -path "*/subagents/*" -mtime -7 \
        -exec awk \
          -v h5="$five_h_cutoff" \
          -v d7="$seven_d_cutoff" \
          'BEGIN { c5=0; c7=0 }
           /\"type\":\"user\"/ && /\"parentUuid\":null/ {
             if (match($0, /"timestamp":"[^"]*/)) {
               ts = substr($0, RSTART + 13, 19)
               if (ts >= h5) c5++
               if (ts >= d7) c7++
             }
           }
           END { print c5, c7 }' \
        {} + 2>/dev/null | \
        awk 'BEGIN{c5=0;c7=0} {c5+=$1; c7+=$2} END{print c5, c7}')

      window_5h=$(echo "${raw_counts:-0 0}" | awk '{print $1}')
      window_7d=$(echo "${raw_counts:-0 0}" | awk '{print $2}')
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Current workspace
# Extracted from the cwd field of the first user message in the transcript.
# Displays only the last path component (e.g. "F:\GitHub\Nimbus" → "Nimbus").
# ---------------------------------------------------------------------------
workspace=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  cwd_raw=$(grep -m1 '"type":"user"' "$transcript" 2>/dev/null | \
    "$JQ" -r '.cwd // empty' 2>/dev/null)
  if [ -n "$cwd_raw" ]; then
    # Split on / or \ and take the last non-empty component
    workspace=$(printf '%s' "$cwd_raw" | awk -F'[/\\\\]' '{
      for (i=NF; i>=1; i--) {
        if ($i != "") { print $i; exit }
      }
    }')
  fi
fi

# ---------------------------------------------------------------------------
# Assemble and print the final status line
# Format:  Model  [████░░░░] 33%/200k  5h:12  7d:45  ~$0.04  12m30s  Workspace
# ---------------------------------------------------------------------------
line="$model  $ctx_str"
[ -n "$window_5h"    ] && line="$line  5h:${window_5h}"
[ -n "$window_7d"    ] && line="$line  7d:${window_7d}"
[ -n "$cost_str"     ] && line="$line  $cost_str"
[ -n "$duration_str" ] && line="$line  $duration_str"
[ -n "$workspace"    ] && line="$line  $workspace"

printf "%s\n" "$line"
