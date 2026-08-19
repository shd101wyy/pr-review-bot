#!/usr/bin/env bash
# review-session.sh — run ONE review session, then post the review ourselves.
#
# The agent's only job is to write a findings JSON file. The review event
# (APPROVE / REQUEST_CHANGES / COMMENT) is computed here from each finding's
# `blocking` flag, so "approve when nothing blocks" is a property of this code
# rather than of the model's judgement — a DSH run once wrote "No blockers" in
# the body and still submitted COMMENTED, which is exactly what this prevents.
# Posting, status-comment removal and worktree cleanup all happen here too, so
# they no longer depend on the agent remembering to do them.
#
# Everything arrives via the environment (poll.sh exports it):
#   REPO PR HARNESS HEAD_SHA STATUS_CID
#   AGENT_CMD FINDINGS_FILE AGENT_LOG WT MIRROR GH
# Expected findings schema (the prompt documents it to the agent):
#   { "summary": "markdown",
#     "unsure": false,
#     "findings": [ {"path":"f.rs","line":12,"body":"…","blocking":false}, … ] }
set -uo pipefail

log() { echo "[$(date -Is)] $*"; }
die() { log "SESSION-RESULT: failed reason=$1"; exit 1; }

for v in REPO PR HEAD_SHA AGENT_CMD FINDINGS_FILE AGENT_LOG GH; do
  [ -n "${!v:-}" ] || { log "FATAL: $v is unset"; die "bad-invocation"; }
done

rm -f "$FINDINGS_FILE"

log "running the ${HARNESS:-agent} agent (findings -> ${FINDINGS_FILE##*/})"
bash "$AGENT_CMD" > "$AGENT_LOG" 2>&1
agent_rc=$?
log "agent exited rc=$agent_rc, output: ${AGENT_LOG##*/} ($(stat -c%s "$AGENT_LOG" 2>/dev/null || echo 0) bytes)"

# --- the findings file is the contract; without it there is nothing to post ----
[ -s "$FINDINGS_FILE" ] || die "no-findings-file(agent rc=$agent_rc)"
jq -e 'type == "object"' "$FINDINGS_FILE" >/dev/null 2>&1 || die "findings-not-json-object"

# --- decide the event HERE, from the data ------------------------------------
TRUTHY='def truthy: if type == "string" then (ascii_downcase | . == "true" or . == "yes" or . == "1")
                    elif type == "number" then . != 0
                    else . == true end;'
blocking="$(jq "$TRUTHY"' [.findings[]? | select((.blocking // false) | truthy)] | length' "$FINDINGS_FILE" 2>/dev/null || echo 0)"
unsure="$(jq -r "$TRUTHY"' (.unsure // false) | truthy' "$FINDINGS_FILE" 2>/dev/null || echo false)"
# An unreadable count must never become an approval.
case "$blocking" in ''|*[!0-9]*) log "WARNING: could not count blocking findings — treating as blocking"; blocking=1;; esac
total="$(jq '[.findings[]?] | length' "$FINDINGS_FILE" 2>/dev/null || echo 0)"

if [ "$blocking" -gt 0 ]; then
  event="REQUEST_CHANGES"
elif [ "$unsure" = "true" ]; then
  event="COMMENT"
else
  event="APPROVE"
fi
log "findings=$total blocking=$blocking unsure=$unsure -> event=$event"

# --- build the review payload -------------------------------------------------
# GitHub rejects REQUEST_CHANGES / COMMENT with an empty body, so a missing
# summary must not be able to sink the whole review.
NOBODY='_Automated review: the agent produced findings but no summary._'
PAYLOAD="${FINDINGS_FILE%.json}-payload.json"
jq --arg event "$event" --arg sha "$HEAD_SHA" --arg nobody "$NOBODY" '
  def inline: ((.path // "") != "") and (((.line // 0) | tonumber? // 0) > 0);
  def nonblank: if (. | gsub("\\s"; "")) == "" then $nobody else . end;
  {
    event: $event,
    commit_id: $sha,
    comments: [ .findings[]? | select(inline)
                | {path: .path, line: (.line | tonumber), body: (.body // "")} ],
    body: ( ( (.summary // "")
              + ( [ .findings[]? | select(inline | not) | "- " + (.body // "") ]
                  | if length > 0 then "\n\n### Additional notes\n" + join("\n") else "" end ) )
            | nonblank )
  }' "$FINDINGS_FILE" > "$PAYLOAD" || die "cannot-build-payload"

POST_ERR="${FINDINGS_FILE%.json}-post-err.txt"
# stdout carries the id and NOTHING else: gh can emit warnings on stderr while
# succeeding, and treating those as a rejection posted a duplicate review.
post() {
  : > "$POST_ERR"
  "$GH" api "repos/$REPO/pulls/$PR/reviews" --input "$1" -q .id 2>"$POST_ERR" | tr -d '[:space:]'
}
post_err() { [ -s "$POST_ERR" ] && head -c 300 "$POST_ERR" || echo "(no stderr)"; }

review_id="$(post "$PAYLOAD")"
if ! [[ "$review_id" =~ ^[0-9]+$ ]]; then
  # Most often an inline comment points at a line outside the diff hunk, which
  # makes GitHub reject the whole review. Fold every finding into the body and
  # retry, so a bad line number costs formatting rather than the whole review.
  log "WARNING: review rejected (id='$review_id' err=$(post_err)) — retrying with all findings folded into the body"
  FALLBACK="${FINDINGS_FILE%.json}-payload-fallback.json"
  jq --arg event "$event" --arg sha "$HEAD_SHA" --arg nobody "$NOBODY" '
    def nonblank: if (. | gsub("\\s"; "")) == "" then $nobody else . end;
    {
      event: $event,
      commit_id: $sha,
      body: ( ( (.summary // "")
                + ( [ .findings[]? | "- " + (if (.path // "") != "" then "`" + .path + (if (.line // 0) > 0 then ":" + (.line|tostring) else "" end) + "` — " else "" end) + (.body // "") ]
                    | if length > 0 then "\n\n### Findings\n" + join("\n") else "" end ) )
              | nonblank )
    }' "$FINDINGS_FILE" > "$FALLBACK"
  review_id="$(post "$FALLBACK")"
  [[ "$review_id" =~ ^[0-9]+$ ]] || die "post-rejected(err=$(post_err))"
fi
log "posted review id=$review_id event=$event on $REPO#$PR @ ${HEAD_SHA:0:7}"

# --- cleanup: ours to do, not the agent's ------------------------------------
if [ -n "${STATUS_CID:-}" ]; then
  "$GH" api --method DELETE "repos/$REPO/issues/comments/$STATUS_CID" >/dev/null 2>&1 \
    && log "deleted 'reviewing in progress' comment $STATUS_CID" \
    || log "could not delete status comment $STATUS_CID (already gone?)"
fi
# Derived files are noise once the review is posted; findings.json stays for
# debugging (it is the agent's actual output and worktrees/ is gitignored).
rm -f "$PAYLOAD" "${FINDINGS_FILE%.json}-payload-fallback.json" "$POST_ERR"
if [ -n "${WT:-}" ] && [ -n "${MIRROR:-}" ]; then
  git --git-dir="$MIRROR" worktree remove --force "$WT" >/dev/null 2>&1
  git --git-dir="$MIRROR" worktree prune >/dev/null 2>&1
  log "removed worktree ${WT##*/}"
fi

log "SESSION-RESULT: ok event=$event review_id=$review_id findings=$total blocking=$blocking"
