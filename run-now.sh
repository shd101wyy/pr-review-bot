#!/usr/bin/env bash
# run-now.sh — manual control for the PR review bot.
#   ./run-now.sh                 -> run a discovery poll immediately (FORCE=1, bypasses interval)
#   ./run-now.sh status          -> show what's being reviewed / waiting / finished
#   ./run-now.sh poll            -> same as no args (forced poll)
#   ./run-now.sh 261             -> immediately review PR 261 in the FIRST repo of config.json
#   ./run-now.sh SkardiLabs/skardi 42 -> immediately review PR 42 in a specific repo
#   DRY_RUN=1 ./run-now.sh       -> discovery only, launch nothing
set -uo pipefail

BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  status) exec "$BOT_DIR/status.sh";;
  poll)   FORCE=1 exec "$BOT_DIR/poll.sh";;
esac

export PATH="/home/deck/.nix-profile/bin:/usr/bin:/bin"
export HOME="/home/deck"

# shellcheck disable=SC1091
. "$BOT_DIR/poll.sh"   # loads config + helpers; sourcing acquires the lock (fine)

if [ $# -eq 0 ]; then
  FORCE=1 main
  exit 0
fi

repo="${REPOS[0]}"; pr=""
case "$1" in
  */*) repo="$1"; pr="${2:-}";;
  *)   pr="$1";;
esac
[ -z "$pr" ] && { echo "usage: $0 [owner/repo] <PR number>"; exit 2; }
echo "$repo" | grep -q '/' || repo="${REPOS[0]}"

echo ">> Manually reviewing PR #$pr in $repo"
launch_review "$repo" "$pr" "manual"