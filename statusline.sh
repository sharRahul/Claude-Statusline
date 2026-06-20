#!/bin/bash

# Claude Code Status Line
# Format:
#   Model [Effort] | $cost | [bar] ctx% usedK/200K | 5h:X% ↺Xh Xm | 7d:X% ↺Xh Xm | duration | folder (branch↑↓) [⚠]
#
# Reads the JSON Claude Code passes on stdin for context usage.
# Reads ~/.claude/usage_cache.json for Claude.ai 5h/7d usage limits.
# Polls status.claude.com for Claude infrastructure health (10-min cache).
# File-locks background refreshes so multiple open terminals don't pile up.
# Respects NO_COLOR env var.
# Requires: jq, curl, git.

CACHE_FILE="$HOME/.claude/usage_cache.json"
REFRESH_SCRIPT="$HOME/.claude/refresh_usage.sh"
STATUS_CACHE="$HOME/.claude/claude_status_cache.json"
CACHE_LOCK="/tmp/claude_usage_refresh.lock"
STATUS_LOCK="/tmp/claude_status_refresh.lock"

# ---- read stdin JSON ---------------------------------------------------------
input="$(cat 2>/dev/null)"
[[ -z "$input" ]] && input="{}"

jqr() { echo "$input" | jq -r "$1" 2>/dev/null; }

now_ts=$(date +%s)

# ---- model name --------------------------------------------------------------
_model_type="$(echo "$input" | jq -r '.model | type' 2>/dev/null)"
if [[ "$_model_type" == "object" ]]; then
    model_name="$(jqr '.model.display_name // .model.name // .model.id // "Claude"')"
else
    model_name="$(jqr '.model // "Claude"')"
fi

case "$model_name" in
    claude-opus-4-8*|claude-opus-4.8*) model_name="Claude Opus 4.8" ;;
    claude-opus-4*)                     model_name="Claude Opus 4" ;;
    claude-opus*)                       model_name="Claude Opus" ;;
    claude-sonnet-4-6*|claude-sonnet-4.6*) model_name="Claude Sonnet 4.6" ;;
    claude-sonnet-4*)                   model_name="Claude Sonnet 4" ;;
    claude-sonnet*)                     model_name="Claude Sonnet" ;;
    claude-haiku-4-5*|claude-haiku-4.5*) model_name="Claude Haiku 4.5" ;;
    claude-haiku-4*)                    model_name="Claude Haiku 4" ;;
    claude-haiku*)                      model_name="Claude Haiku" ;;
    claude-fable-5*)                    model_name="Claude Fable 5" ;;
    opus)   model_name="Claude Opus" ;;
    sonnet) model_name="Claude Sonnet" ;;
    haiku)  model_name="Claude Haiku" ;;
esac

transcript_path="$(jqr '.transcript_path // empty')"
current_dir="$(jqr '.cwd // .workspace.current_dir // empty')"
exceeds_200k="$(jqr '.exceeds_200k_tokens // false')"
[[ -z "$current_dir" ]] && current_dir="$(pwd)"

# ---- effort ------------------------------------------------------------------
effort="$(jqr '.effort.level // .effort // empty')"
if [[ -z "$effort" ]]; then
    settings_file="$HOME/.claude/settings.json"
    [[ -f "$settings_file" ]] && effort="$(jq -r '.effortLevel // empty' "$settings_file" 2>/dev/null)"
fi
[[ -n "$effort" ]] && effort="$(echo "${effort:0:1}" | tr '[:lower:]' '[:upper:]')${effort:1}"

model_display="${model_name#Claude }"

# ---- context window ----------------------------------------------------------
if [[ "$exceeds_200k" == "true" ]]; then
    context_limit=1000000
else
    context_limit=200000
fi

fmt_tokens() {
    local n="$1"
    if (( n >= 1000000 )); then
        if (( n % 1000000 == 0 )); then echo "$((n / 1000000))M"
        else printf "%.1fM" "$(echo "$n" | awk '{print $1/1000000}')"; fi
    else
        echo "$((n / 1000))K"
    fi
}

window_label="$(fmt_tokens "$context_limit")"

# ---- used tokens from transcript --------------------------------------------
used_tokens=0
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    used_tokens="$(jq -s '
        map(select(.message.usage != null) | .message.usage
            | (.input_tokens // 0)
              + (.cache_read_input_tokens // 0)
              + (.cache_creation_input_tokens // 0))
        | last // 0' "$transcript_path" 2>/dev/null)"
    [[ -z "$used_tokens" || "$used_tokens" == "null" ]] && used_tokens=0
fi
(( used_tokens > context_limit )) && used_tokens=$context_limit
ctx_pct=$(( used_tokens * 100 / context_limit ))
used_label="$(fmt_tokens "$used_tokens")"

# ---- session cost from transcript ($/MTok pricing per model) ----------------
session_cost_label=""
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    case "$model_name" in
        *Opus*)  ip=15;   op=75;  crp=1.50; cwp=18.75 ;;
        *Haiku*) ip=0.80; op=4;   crp=0.08; cwp=1.00  ;;
        *)       ip=3;    op=15;  crp=0.30; cwp=3.75  ;;
    esac
    session_cost="$(jq -s \
        --argjson ip "$ip" --argjson op "$op" \
        --argjson crp "$crp" --argjson cwp "$cwp" \
        '[.[] | select(.message.usage != null) | .message.usage |
          ((.input_tokens // 0) * $ip +
           (.output_tokens // 0) * $op +
           (.cache_read_input_tokens // 0) * $crp +
           (.cache_creation_input_tokens // 0) * $cwp)
        ] | add // 0 | . / 1000000' \
        "$transcript_path" 2>/dev/null)"
    if [[ -n "$session_cost" && "$session_cost" != "null" ]]; then
        _fmt="$(printf '$%.3f' "$session_cost" 2>/dev/null)"
        [[ "$_fmt" != '$0.000' ]] && session_cost_label="$_fmt"
    fi
fi

# ---- session duration from transcript timestamps ----------------------------
# Reads the first .timestamp field written by Claude Code into the transcript
# JSONL file. Claude Code creates and populates this file automatically after
# the first API call, so duration shows "-" on the very first turn and updates
# from the second message onwards. Falls back to "-" if the transcript is
# missing or contains no timestamps.
session_duration="-"
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    first_ts="$(jq -r '[.[] | select(.timestamp != null) | .timestamp] | first // empty' "$transcript_path" 2>/dev/null)"
    if [[ -n "$first_ts" ]]; then
        start_epoch=$(date -d "$first_ts" +%s 2>/dev/null)
        if [[ -n "$start_epoch" && "$start_epoch" -gt 0 ]]; then
            elapsed=$(( now_ts - start_epoch ))
            h=$(( elapsed / 3600 ))
            m=$(( (elapsed % 3600) / 60 ))
            if (( h > 0 )); then session_duration="${h}h ${m}m"
            else                 session_duration="${m}m"; fi
        fi
    fi
fi

# ---- git branch + dirty + ahead/behind --------------------------------------
git_branch=""
git_ahead=0
git_behind=0
if [[ -n "$current_dir" ]]; then
    git_branch="$(git -C "$current_dir" symbolic-ref --short HEAD 2>/dev/null)"
    if [[ -n "$git_branch" ]]; then
        git_dirty="$(git -C "$current_dir" status --porcelain 2>/dev/null)"
        [[ -n "$git_dirty" ]] && git_branch="${git_branch}*"
        _ahead="$(git -C "$current_dir" rev-list --count "@{u}..HEAD" 2>/dev/null)"
        _behind="$(git -C "$current_dir" rev-list --count "HEAD..@{u}" 2>/dev/null)"
        [[ "$_ahead"  =~ ^[0-9]+$ ]] && git_ahead=$_ahead
        [[ "$_behind" =~ ^[0-9]+$ ]] && git_behind=$_behind
    fi
fi

# ---- Claude infrastructure status (10-min cache, file-locked) ---------------
status_age=999999
if [[ -f "$STATUS_CACHE" ]]; then
    _smtime=$(stat -c %Y "$STATUS_CACHE" 2>/dev/null || echo 0)
    status_age=$(( now_ts - _smtime ))
fi
if (( status_age > 600 )); then
    if mkdir "$STATUS_LOCK" 2>/dev/null; then
        ( curl -sf --max-time 3 "https://status.claude.com/api/v2/status.json" \
            > "$STATUS_CACHE" 2>/dev/null; rmdir "$STATUS_LOCK" 2>/dev/null ) &
    fi
fi

claude_status_seg=""
if [[ -f "$STATUS_CACHE" ]]; then
    _indicator="$(jq -r '.status.indicator // "none"' "$STATUS_CACHE" 2>/dev/null)"
    case "$_indicator" in
        minor)            claude_status_seg="\033[33m⚠\033[0m" ;;
        major|critical)   claude_status_seg="\033[31m✗\033[0m" ;;
    esac
fi

# ---- Claude.ai usage cache (background refresh if stale, file-locked) -------
# Built-in OAuth fallback used when refresh_usage.sh is absent.
_oauth_refresh_usage() {
    local creds="$HOME/.claude/.credentials.json"
    [[ ! -f "$creds" ]] && return 1
    local token
    token="$(jq -r '
        .claudeAiOauth.accessToken //
        .claudeAiOauthTokens.accessToken //
        .accessToken //
        empty' "$creds" 2>/dev/null)"
    [[ -z "$token" ]] && return 1

    local resp
    resp="$(curl -sf --max-time 10 \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)"
    [[ -z "$resp" ]] && return 1

    # Normalize to our cache format; handle multiple possible response shapes.
    local parsed
    parsed="$(printf '%s' "$resp" | jq '
        def util:
            .utilization // .percentage_used // .percent_used //
            (if (.used_dollars != null and .limit_dollars != null and .limit_dollars > 0)
             then (.used_dollars / .limit_dollars * 100) else null end) //
            (if (.count != null and .limit != null and .limit > 0)
             then (.count / .limit * 100) else null end) // null;
        def rst:
            .resets_at // .reset_at // .reset_time // .resetsAt // null;
        def extract(node): node | { utilization: util, resets_at: rst };
        {
            five_hour: extract(
                .five_hour // .fiveHour // .rate_limits.five_hour // {}
            ),
            seven_day: extract(
                .seven_day // .sevenDay //
                .rate_limits.seven_day // .rate_limits.week // {}
            )
        }' 2>/dev/null)"

    # Only persist if we received a meaningful reset time for at least one window.
    printf '%s' "$parsed" | jq -e '
        (.five_hour.resets_at  != null and .five_hour.resets_at  != "") or
        (.seven_day.resets_at != null and .seven_day.resets_at != "")
    ' >/dev/null 2>&1 || return 1

    printf '%s\n' "$parsed" > "$CACHE_FILE"
}

cache_age=999999
if [[ -f "$CACHE_FILE" ]]; then
    _cmtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
    cache_age=$(( now_ts - _cmtime ))
fi
if (( cache_age > 300 )); then
    if mkdir "$CACHE_LOCK" 2>/dev/null; then
        if [[ -f "$REFRESH_SCRIPT" ]]; then
            ( bash "$REFRESH_SCRIPT" >/dev/null 2>&1; rmdir "$CACHE_LOCK" 2>/dev/null ) &
        else
            ( _oauth_refresh_usage; rmdir "$CACHE_LOCK" 2>/dev/null ) &
        fi
    fi
fi

# ---- parse usage cache -------------------------------------------------------
session_pct="-"
weekly_pct="-"
session_reset_label=""
weekly_reset_label=""

pct_color() {
    local p="${1%.*}"
    if   (( p >= 80 )); then echo "31"   # red
    elif (( p >= 60 )); then echo "33"   # yellow
    elif (( p >= 40 )); then echo "93"   # bright yellow
    else                     echo "32"   # green
    fi
}

countdown() {
    local ts
    ts=$(date -d "$1" +%s 2>/dev/null) || return
    local secs=$(( ts - now_ts ))
    (( secs <= 0 )) && echo "now" && return
    local d=$(( secs / 86400 ))
    local h=$(( (secs % 86400) / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    if   (( d > 0 )); then echo "${d}d ${h}h"
    elif (( h > 0 )); then echo "${h}h ${m}m"
    else echo "${m}m"; fi
}

if [[ -f "$CACHE_FILE" ]]; then
    raw_session_pct="$(jq -r '.five_hour.utilization // empty' "$CACHE_FILE" 2>/dev/null)"
    raw_weekly_pct="$(jq -r '.seven_day.utilization // empty' "$CACHE_FILE" 2>/dev/null)"
    session_resets_at="$(jq -r '.five_hour.resets_at // empty' "$CACHE_FILE" 2>/dev/null)"
    weekly_resets_at="$(jq -r '.seven_day.resets_at // empty' "$CACHE_FILE" 2>/dev/null)"

    [[ -n "$raw_session_pct" ]] && session_pct="${raw_session_pct%.*}%"
    [[ -n "$raw_weekly_pct"  ]] && weekly_pct="${raw_weekly_pct%.*}%"
    [[ -n "$session_resets_at" ]] && session_reset_label="$(countdown "$session_resets_at")"
    [[ -n "$weekly_resets_at"  ]] && weekly_reset_label="$(countdown "$weekly_resets_at")"

    session_color="$(pct_color "${raw_session_pct:-0}")"
    weekly_color="$(pct_color "${raw_weekly_pct:-0}")"
else
    session_color="32"
    weekly_color="32"
fi

# ---- progress bar ------------------------------------------------------------
bar_width=10
filled=$(( (ctx_pct * bar_width + 50) / 100 ))
(( filled > bar_width )) && filled=$bar_width
(( filled < 0 ))          && filled=0
empty=$(( bar_width - filled ))

if   (( ctx_pct >= 80 )); then bar_color="31"
elif (( ctx_pct >= 60 )); then bar_color="33"
elif (( ctx_pct >= 40 )); then bar_color="93"
else                           bar_color="32"
fi

bar=""
for (( i = 0; i < filled; i++ )); do bar="${bar}█"; done
for (( i = 0; i < empty;  i++ )); do bar="${bar}░"; done

# ---- model color -------------------------------------------------------------
case "$model_name" in
    *[Oo]pus*)   model_color="35" ;;
    *[Ss]onnet*) model_color="34" ;;
    *[Hh]aiku*)  model_color="32" ;;
    *)           model_color="36" ;;
esac

model_segment="$model_display"
[[ -n "$effort" ]] && model_segment="$model_display [$effort]"

# ---- render segments ---------------------------------------------------------
SEP="\033[90m|\033[0m"

ctx_seg="\033[${bar_color}m${bar}\033[0m \033[${bar_color}m${ctx_pct}%\033[0m \033[90m${used_label}/${window_label}\033[0m"

if [[ "$session_pct" != "-" ]]; then
    fiveh_seg="\033[90m5h:\033[0m\033[${session_color}m${session_pct}\033[0m"
    [[ -n "$session_reset_label" ]] && fiveh_seg="${fiveh_seg} \033[90m↺\033[0m \033[33m${session_reset_label}\033[0m"
else
    fiveh_seg="\033[90m5h:-\033[0m"
fi

if [[ "$weekly_pct" != "-" ]]; then
    weekly_seg="\033[90m7d:\033[0m\033[${weekly_color}m${weekly_pct}\033[0m"
    [[ -n "$weekly_reset_label" ]] && weekly_seg="${weekly_seg} \033[90m↺\033[0m \033[33m${weekly_reset_label}\033[0m"
else
    weekly_seg="\033[90m7d:-\033[0m"
fi

# Folder + git branch + dirty + ahead/behind
folder="$(basename "$current_dir")"
folder_seg="\033[34m${folder}\033[0m"
if [[ -n "$git_branch" ]]; then
    branch_clean="${git_branch%\*}"
    if [[ "$git_branch" == *\* ]]; then
        branch_col="\033[93m${branch_clean}*\033[0m"
    else
        branch_col="\033[36m${git_branch}\033[0m"
    fi
    sync=""
    (( git_ahead  > 0 )) && sync="${sync}\033[32m↑${git_ahead}\033[0m"
    (( git_behind > 0 )) && sync="${sync}\033[31m↓${git_behind}\033[0m"
    if [[ -n "$sync" ]]; then
        folder_seg="${folder_seg} \033[90m(\033[0m${branch_col} ${sync}\033[90m)\033[0m"
    else
        folder_seg="${folder_seg} \033[90m(\033[0m${branch_col}\033[90m)\033[0m"
    fi
fi

# ---- assemble line -----------------------------------------------------------
line="\033[1;${model_color}m${model_segment}\033[0m"
[[ -n "$session_cost_label" ]] && line="${line} $SEP \033[90m${session_cost_label}\033[0m"
line="${line} $SEP ${ctx_seg}"
line="${line} $SEP ${fiveh_seg}"
line="${line} $SEP ${weekly_seg}"
line="${line} $SEP \033[90m${session_duration}\033[0m"
line="${line} $SEP ${folder_seg}"
[[ -n "$claude_status_seg" ]] && line="${line} $SEP ${claude_status_seg}"

# ---- output (strip ANSI if NO_COLOR is set) ----------------------------------
if [[ -n "${NO_COLOR:-}" ]]; then
    ESC=$'\033'
    printf '%b' "$line" | sed "s/${ESC}\[[0-9;]*m//g"
    printf '\n'
else
    printf '%b\n' "$line"
fi
