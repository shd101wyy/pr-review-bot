#!/usr/bin/env bash
# status.sh — show what the PR review bot is doing right now:
# config, timer, running/finished sessions, and PRs still waiting for review.
set -uo pipefail

BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_LOCK=1
# shellcheck disable=SC1091
. "$BOT_DIR/poll.sh"   # loads config, defines helpers; main() is NOT run

secs_ago() { local n d; n=$(date +%s); d=$((n - $1)); if [ "$d" -lt 60 ]; then echo "${d}s ago"; elif [ "$d" -lt 3600 ]; then echo "$((d/60))m ago"; else echo "$((d/3600))h $(((d%3600)/60))m ago"; fi; }

echo "=== PR review bot status ==="
echo "Config  : $CONFIG_FILE"
echo "Repos   :"
jq -r '.repos[] | "    \(.repo)  (reviewer: \(.reviewer) | model: \(.model.provider)/\(.model.model)\(.model.reasoningEffort // "" | if . != "" then " (" + . + ")" else "" end))"' "$EFFECTIVE_FILE" 2>/dev/null | sed -n '1,20p'
echo "Model (global default): $MODEL_PROVIDER / $MODEL_NAME${MODEL_EFFORT:+ / effort=$MODEL_EFFORT}"

echo
echo "--- scheduler ---"
echo "Timer   : $(systemctl --user is-active pr-review-bot.timer 2>/dev/null || echo 'n/a (not installed)')"
if [ -f "$LAST_POLL_FILE" ]; then
  lp=$(cat "$LAST_POLL_FILE"); now=$(date +%s)
  due=$((POLL_INTERVAL_MINUTES * 60 - (now - lp))); [ "$due" -lt 0 ] && due=0
  echo "Polling : last run $(secs_ago "$lp"), interval ${POLL_INTERVAL_MINUTES}m, next due in ~${due}s"
else
  echo "Polling : never ran yet"
fi

echo
echo "--- sessions (per handled PR) ---"
count=0
while IFS=$'\t' read -r key reason ts slog; do
  count=$((count+1))
  repo="${key%%#*}"; pr="${key##*#}"
  pidfile="$STATE_DIR/session-pr-$(echo "$repo" | tr '/' '-')-$pr.pid"
  state="?"
  if [ -n "$slog" ] && [ -f "$slog" ]; then
    if [ -f "$pidfile" ] && pid=$(cat "$pidfile" 2>/dev/null) && kill -0 "$pid" 2>/dev/null; then
      state="RUNNING"
      tail1="$(tail -1 "$slog" 2>/dev/null | head -c 90)"
    else
      if grep -qE 'Error:|at file://|FATAL|MISSING_CREDENTIAL' "$slog" 2>/dev/null; then
        state="FAILED"
      else
        state="finished"
      fi
      tail1="$(tail -2 "$slog" 2>/dev/null | head -1 | head -c 90)"
    fi
  elif [ "$reason" = "already_reviewed" ]; then
    state="skipped(already reviewed)"; tail1=""
  else
    state="queued"; tail1=""
  fi
  printf '  %-42s %-22s %s  %s\n' "#$key  [$reason]" "$state" "$(date -d "$ts" +'%m-%d %H:%M' 2>/dev/null || echo "$ts")" "${slog##*/}"
  [ -n "${tail1:-}" ] && printf '      last: %s\n' "$tail1"
done < <(jq -r '.handled_prs | to_entries[] | [.key, .value.reason, .value.triggered_at, .value.session_log] | @tsv' "$STATE_FILE" 2>/dev/null)
[ "$count" -eq 0 ] && echo "  (no sessions yet)"

echo
echo "--- currently requested on GitHub, not yet reviewed ---"
declare -A PENDING=()
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  reviewer="$(eff_repo "$repo" | jq -r '.reviewer')"
  while read -r p; do
    [ -n "$p" ] || continue
    PENDING["$repo#$p"]=""
    rv=$("$GH" api "repos/$repo/pulls/$p/reviews" --paginate \
      -q '.[] | select(.user.login == "'"$reviewer"'") | select(.state != "DISMISSED")' 2>/dev/null | head -c1)
    [ -n "$rv" ] && PENDING["$repo#$p"]="reviewed"
  done < <("$GH" api graphql \
    -f query="query { search(query: \"repo:$repo is:pr is:open review-requested:$reviewer\", type: ISSUE, first: 100) { edges { node { ... on PullRequest { number } } } } }" \
    -q '.data.search.edges[].node.number' 2>/dev/null)
done < <(jq -r '.repos[].repo' "$EFFECTIVE_FILE")
if [ "${#PENDING[@]}" -eq 0 ]; then echo "  (none)"; fi
for k in $(printf '%s\n' "${!PENDING[@]}" | sort); do
  h=""; handled_pr "${k%%#*}" "${k##*#}" && h=" [handled]"
  echo "  #$k — ${PENDING[$k]:-NEEDS REVIEW}$h"
done
echo
echo "View a session: tail -f $(echo "$LOG_DIR" | sed 's|'"$BOT_DIR"'/||')/session-pr-<n>-<ts>.log"
echo "Note: headless sessions run as separate processes and are NOT listed in the DSH web GUI"
echo "      (the GUI only shows sessions created inside dsh web). The log stays empty while a"
echo "      session is working and is written when it finishes."
echo "Logs: $LOG_DIR"